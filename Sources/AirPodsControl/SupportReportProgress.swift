import Darwin
import Dispatch
import Foundation

enum SupportReportWriteTestProgressOperation: Equatable {
  case listeningMode(ListeningMode)
  case listeningModeRestoration
  case conversationAwareness
  case conversationAwarenessRestoration

  var activeLabel: String {
    switch self {
    case let .listeningMode(mode):
      return "Testing listening mode: \(mode.displayName)…"
    case .listeningModeRestoration:
      return "Restoring listening mode…"
    case .conversationAwareness:
      return "Testing Conversation Awareness…"
    case .conversationAwarenessRestoration:
      return "Restoring Conversation Awareness…"
    }
  }

  var skippedLabel: String {
    switch self {
    case let .listeningMode(mode):
      return "Skipping listening mode: \(mode.displayName)…"
    case .listeningModeRestoration:
      return "Skipping listening mode restoration…"
    case .conversationAwareness:
      return "Skipping Conversation Awareness…"
    case .conversationAwarenessRestoration:
      return "Skipping Conversation Awareness restoration…"
    }
  }
}

struct SupportReportWriteTestProgressPlan {
  let operations: [SupportReportWriteTestProgressOperation]

  init(_ plan: SupportReportWriteTestPlan) {
    var operations: [SupportReportWriteTestProgressOperation] = []
    if plan.willTestListeningModes {
      operations.append(contentsOf: plan.listeningModeTargets.map {
        .listeningMode($0)
      })
      operations.append(.listeningModeRestoration)
    }
    if plan.willTestConversationAwareness {
      operations.append(contentsOf: [
        .conversationAwareness,
        .conversationAwarenessRestoration,
      ])
    }
    self.operations = operations
  }
}

enum SupportReportWriteTestProgressEvent: Equatable {
  case preparing
  case operationStarted(
    SupportReportWriteTestProgressOperation,
    step: Int,
    total: Int
  )
  case operationSkipped(
    SupportReportWriteTestProgressOperation,
    step: Int,
    total: Int
  )
  case interrupted(signal: Int32)
  case restorationFailed
  case finished
}

struct SupportReportWriteTestProgressReporter {
  private let plan: SupportReportWriteTestProgressPlan
  private let report: (SupportReportWriteTestProgressEvent) -> Void

  init(
    plan: SupportReportWriteTestPlan,
    report: @escaping (SupportReportWriteTestProgressEvent) -> Void
  ) {
    self.plan = SupportReportWriteTestProgressPlan(plan)
    self.report = report
  }

  func preparing() {
    report(.preparing)
  }

  func started(_ operation: SupportReportWriteTestProgressOperation) {
    let position = position(of: operation)
    report(.operationStarted(operation, step: position.step, total: position.total))
  }

  func skipped(_ operation: SupportReportWriteTestProgressOperation) {
    let position = position(of: operation)
    report(.operationSkipped(operation, step: position.step, total: position.total))
  }

  func skipped(_ operations: [SupportReportWriteTestProgressOperation]) {
    operations.forEach(skipped)
  }

  func skippedListeningModes() {
    skipped(plan.operations.filter { operation in
      switch operation {
      case .listeningMode, .listeningModeRestoration: return true
      case .conversationAwareness, .conversationAwarenessRestoration: return false
      }
    })
  }

  func skippedConversationAwareness() {
    skipped(plan.operations.filter { operation in
      switch operation {
      case .listeningMode, .listeningModeRestoration: return false
      case .conversationAwareness, .conversationAwarenessRestoration: return true
      }
    })
  }

  func interrupted(by signal: Int32) {
    report(.interrupted(signal: signal))
  }

  func restorationFailed() {
    report(.restorationFailed)
  }

  func finished() {
    report(.finished)
  }

  private func position(
    of operation: SupportReportWriteTestProgressOperation
  ) -> (step: Int, total: Int) {
    guard let index = plan.operations.firstIndex(of: operation) else {
      preconditionFailure("Progress operation is not part of the write-test plan")
    }
    return (index + 1, plan.operations.count)
  }
}

enum SupportReportProgressLineRenderer {
  static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  static func render(
    _ event: SupportReportWriteTestProgressEvent,
    frameIndex: Int,
    terminalWidth: Int,
    colorEnabled: Bool
  ) -> String? {
    let counter: String
    let label: String
    switch event {
    case .preparing:
      counter = ""
      label = "Preparing…"
    case let .operationStarted(operation, step, total):
      counter = "[\(step)/\(total)] "
      label = operation.activeLabel
    case let .operationSkipped(operation, step, total):
      counter = "[\(step)/\(total)] "
      label = operation.skippedLabel
    case .interrupted, .restorationFailed, .finished:
      return nil
    }

    let frame = frames[frameIndex % frames.count]
    let body = " Write tests  \(counter)"
    let prefix = frame + body
    let maximumWidth = terminalWidth - 1
    guard maximumWidth > prefix.count else { return nil }
    let fittedLabel = truncate(label, to: maximumWidth - prefix.count)
    let styledFrame = colorEnabled
      ? "\u{001B}[1;36m\(frame)\u{001B}[0m"
      : frame
    return styledFrame + body + fittedLabel
  }

  private static func truncate(_ value: String, to length: Int) -> String {
    guard value.count > length else { return value }
    guard length > 1 else { return "…" }
    return String(value.prefix(length - 1)) + "…"
  }
}

final class SupportReportProgressDisplay {
  static let frameIntervalMilliseconds = 80
  static let restorationWarning =
    "Warning: initial settings were not fully restored; see the report below.\n"

  private static let clearLine = "\r\u{001B}[2K"

  private let queue = DispatchQueue(label: "airpods-control.support-report-progress")
  private let timer: DispatchSourceTimer
  private let terminalWidth: () -> Int
  private let colorEnabled: Bool
  private let writeError: (String) -> Void
  private var currentEvent: SupportReportWriteTestProgressEvent?
  private var frameIndex = 0
  private var lineVisible = false
  private var interrupted = false

  convenience init?(
    plan: SupportReportWriteTestPlan,
    debugEnabled: Bool
  ) {
    self.init(
      plan: plan,
      debugEnabled: debugEnabled,
      errorIsInteractive: isatty(STDERR_FILENO) == 1,
      environment: ProcessInfo.processInfo.environment,
      terminalWidth: {
        Self.terminalWidth(fileDescriptor: STDERR_FILENO) ?? 80
      },
      animationInterval: .milliseconds(Self.frameIntervalMilliseconds),
      writeError: {
        fputs($0, stderr)
        fflush(stderr)
      }
    )
  }

  init?(
    plan: SupportReportWriteTestPlan,
    debugEnabled: Bool,
    errorIsInteractive: Bool,
    environment: [String: String],
    terminalWidth: @escaping () -> Int,
    animationInterval: DispatchTimeInterval,
    writeError: @escaping (String) -> Void
  ) {
    guard Self.shouldDisplay(
      plan: plan,
      debugEnabled: debugEnabled,
      errorIsInteractive: errorIsInteractive,
      environment: environment
    ) else { return nil }

    self.terminalWidth = terminalWidth
    self.colorEnabled = environment["NO_COLOR"] == nil
    self.writeError = writeError
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + animationInterval,
      repeating: animationInterval,
      leeway: .milliseconds(10)
    )
    timer.setEventHandler { [weak self] in
      self?.renderNextFrame()
    }
    timer.activate()
  }

  deinit {
    timer.cancel()
  }

  static func shouldDisplay(
    plan: SupportReportWriteTestPlan,
    debugEnabled: Bool,
    errorIsInteractive: Bool,
    environment: [String: String]
  ) -> Bool {
    !debugEnabled
      && errorIsInteractive
      && environment["TERM"] != "dumb"
      && !SupportReportWriteTestProgressPlan(plan).operations.isEmpty
  }

  func receive(_ event: SupportReportWriteTestProgressEvent) {
    queue.sync {
      switch event {
      case .preparing, .operationStarted:
        currentEvent = event
        renderNextFrame()
      case .operationSkipped:
        currentEvent = interrupted ? nil : event
        if interrupted {
          clearProgressLine()
        } else {
          renderNextFrame()
        }
      case .interrupted:
        interrupted = true
        currentEvent = nil
        clearProgressLine()
      case .restorationFailed:
        currentEvent = nil
        clearProgressLine()
        writeError(Self.restorationWarning)
      case .finished:
        currentEvent = nil
        clearProgressLine()
        timer.cancel()
      }
    }
  }

  private func renderNextFrame() {
    guard let currentEvent else { return }
    guard let line = SupportReportProgressLineRenderer.render(
      currentEvent,
      frameIndex: frameIndex,
      terminalWidth: terminalWidth(),
      colorEnabled: colorEnabled
    ) else {
      clearProgressLine()
      return
    }
    writeError(Self.clearLine + line)
    lineVisible = true
    frameIndex = (frameIndex + 1) % SupportReportProgressLineRenderer.frames.count
  }

  private func clearProgressLine() {
    guard lineVisible else { return }
    writeError(Self.clearLine)
    lineVisible = false
  }

  private static func terminalWidth(fileDescriptor: Int32) -> Int? {
    var size = winsize()
    guard ioctl(fileDescriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
      return nil
    }
    return Int(size.ws_col)
  }
}
