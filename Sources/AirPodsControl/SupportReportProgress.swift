import Darwin
import Dispatch
import Foundation

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

  private enum RenderAction {
    case frame
    case clear
    case restorationWarning
  }

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
      render(apply(event))
    }
  }

  private func apply(_ event: SupportReportWriteTestProgressEvent) -> RenderAction {
    switch event {
    case .preparing, .operationStarted:
      currentEvent = event
      return .frame
    case .operationSkipped:
      if interrupted {
        currentEvent = nil
        return .clear
      }
      currentEvent = event
      return .frame
    case .interrupted:
      interrupted = true
      currentEvent = nil
      return .clear
    case .restorationFailed:
      currentEvent = nil
      return .restorationWarning
    case .finished:
      currentEvent = nil
      timer.cancel()
      return .clear
    }
  }

  private func render(_ action: RenderAction) {
    switch action {
    case .frame:
      renderNextFrame()
    case .clear:
      clearProgressLine()
    case .restorationWarning:
      clearProgressLine()
      writeError(Self.restorationWarning)
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
