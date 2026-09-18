import Darwin
import Dispatch
import Testing

@testable import AirPodsControlCore

@Suite("Support report progress")
struct SupportReportProgressTests {
  @Test("Reports ordered progress for complete and skipped operations")
  func supportReportProgressTracksCompleteAndSkippedWorkflows() throws {
    let device = FakeCompatibleAudioDevice()
    let plan = SupportReportWriteTestPlan.make(device: device)
    var events: [SupportReportWriteTestProgressEvent] = []
    _ = SupportReportWriteTester.run(
      plan: plan,
      device: device,
      progress: { events.append($0) }
    )
    #expect(
      events == [
        .preparing,
        .operationStarted(.listeningMode(.noiseCancellation), step: 1, total: 7),
        .operationStarted(.listeningMode(.adaptive), step: 2, total: 7),
        .operationStarted(.listeningMode(.transparency), step: 3, total: 7),
        .operationStarted(.listeningMode(.off), step: 4, total: 7),
        .operationStarted(.listeningModeRestoration, step: 5, total: 7),
        .operationStarted(.conversationAwareness, step: 6, total: 7),
        .operationStarted(.conversationAwarenessRestoration, step: 7, total: 7),
        .finished,
      ],
      "a complete run reports every planned operation and restoration"
    )

    let rejectingDevice = FakeCompatibleAudioDevice(
      conversationAwarenessSupported: false
    )
    rejectingDevice.listeningModeSetterAccepted = { mode in mode != .noiseCancellation }
    let rejectingPlan = SupportReportWriteTestPlan.make(device: rejectingDevice)
    events = []
    _ = SupportReportWriteTester.run(
      plan: rejectingPlan,
      device: rejectingDevice,
      progress: { events.append($0) }
    )
    #expect(
      events == [
        .preparing,
        .operationStarted(.listeningMode(.noiseCancellation), step: 1, total: 5),
        .operationSkipped(.listeningMode(.adaptive), step: 2, total: 5),
        .operationSkipped(.listeningMode(.transparency), step: 3, total: 5),
        .operationSkipped(.listeningMode(.off), step: 4, total: 5),
        .operationSkipped(.listeningModeRestoration, step: 5, total: 5),
        .finished,
      ],
      "skipped operations advance through the original fixed denominator"
    )
  }

  @Test("Leaves the restoration warning visible after progress finishes")
  func supportReportProgressKeepsRestorationFailureVisible() throws {
    let device = FakeCompatibleAudioDevice(
      conversationAwarenessSupported: false
    )
    device.listeningModeSetterAccepted = { mode in mode != .transparency }
    let plan = SupportReportWriteTestPlan.make(device: device)
    var events: [SupportReportWriteTestProgressEvent] = []
    var writes: [String] = []
    let display = try #require(SupportReportProgressDisplay(
      plan: plan,
      debugEnabled: false,
      errorIsInteractive: true,
      environment: ["TERM": "xterm"],
      terminalWidth: { 80 },
      animationInterval: .seconds(60),
      writeError: { writes.append($0) }
    ))

    let results = SupportReportWriteTester.run(
      plan: plan,
      device: device,
      progress: {
        events.append($0)
        display.receive($0)
      }
    )

    #expect(!results.fullyRestored, "the fixture produces a restoration failure")
    #expect(
      Array(events.suffix(2)) == [.restorationFailed, .finished],
      "restoration failure is announced before progress finishes"
    )
    #expect(
      writes.last?.hasPrefix("\r") == false,
      "finishing leaves the permanent restoration warning visible"
    )
  }

  @Test("Clears transient progress before interruption and restoration")
  func supportReportProgressClearsForInterruptAndRestoration() throws {
    let device = FakeCompatibleAudioDevice()
    let plan = SupportReportWriteTestPlan.make(device: device)
    var caughtSignal: Int32?
    device.settleEffect = {
      if caughtSignal == nil { caughtSignal = SIGINT }
    }
    var writes: [String] = []
    let display = try #require(SupportReportProgressDisplay(
      plan: plan,
      debugEnabled: false,
      errorIsInteractive: true,
      environment: ["TERM": "xterm"],
      terminalWidth: { 80 },
      animationInterval: .seconds(60),
      writeError: { writes.append($0) }
    ))

    let results = SupportReportWriteTester.run(
      plan: plan,
      device: device,
      interruptionSignal: { caughtSignal },
      writeError: { writes.append($0) },
      progress: { display.receive($0) }
    )

    let noticeIndex = try #require(writes.firstIndex(of: SupportReportWriteTester.interruptionNotice))
    let restorationIndex = try #require(writes.firstIndex(where: {
      $0.contains("Restoring listening mode…")
    }))
    #expect(results.interruptedBySignal == SIGINT, "the progress fixture is interrupted")
    #expect(
      noticeIndex < restorationIndex,
      "the permanent interrupt notice precedes resumed restoration progress"
    )
    #expect(
      noticeIndex > 0 && writes[noticeIndex - 1] == "\r\u{001B}[2K",
      "the transient line is cleared before the interrupt notice"
    )
    #expect(
      !writes.joined().contains("\u{001B}[?25"),
      "progress never hides or shows the terminal cursor"
    )
  }

  @Test("Renders preparing, started, and skipped lines and hides terminals")
  func progressLineRendererRendersActiveLinesAndHidesTerminals() {
    let frame = SupportReportProgressLineRenderer.frames[0]
    #expect(
      SupportReportProgressLineRenderer.render(
        .preparing,
        frameIndex: 0,
        terminalWidth: 80,
        colorEnabled: false
      ) == "\(frame) Write tests  Preparing…",
      "preparing has no step counter"
    )
    #expect(
      SupportReportProgressLineRenderer.render(
        .operationStarted(.listeningMode(.transparency), step: 1, total: 7),
        frameIndex: 0,
        terminalWidth: 80,
        colorEnabled: false
      ) == "\(frame) Write tests  [1/7] Testing listening mode: Transparency…",
      "started uses the active label and original plan denominator"
    )
    #expect(
      SupportReportProgressLineRenderer.render(
        .operationSkipped(.listeningMode(.adaptive), step: 2, total: 5),
        frameIndex: 0,
        terminalWidth: 80,
        colorEnabled: false
      ) == "\(frame) Write tests  [2/5] Skipping listening mode: Adaptive…",
      "skipped uses the skipped label"
    )
    #expect(
      SupportReportProgressLineRenderer.render(
        .interrupted(signal: SIGINT),
        frameIndex: 0,
        terminalWidth: 80,
        colorEnabled: false
      ) == nil,
      "interrupt is not a spinner line"
    )
    #expect(
      SupportReportProgressLineRenderer.render(
        .restorationFailed,
        frameIndex: 0,
        terminalWidth: 80,
        colorEnabled: false
      ) == nil,
      "restoration failure is not a spinner line"
    )
    #expect(
      SupportReportProgressLineRenderer.render(
        .finished,
        frameIndex: 0,
        terminalWidth: 80,
        colorEnabled: false
      ) == nil,
      "finished is not a spinner line"
    )
  }

  @Test("Shows progress only on an interactive, non-dumb TTY with work to do")
  func progressDisplayShouldDisplayMatrix() {
    let testable = SupportReportWriteTestPlan.make(device: FakeCompatibleAudioDevice())
    let empty = SupportReportWriteTestPlan.make(
      device: FakeCompatibleAudioDevice(
        listeningModes: [],
        conversationAwarenessSupported: false
      )
    )

    func shouldDisplay(
      plan: SupportReportWriteTestPlan = testable,
      debugEnabled: Bool = false,
      errorIsInteractive: Bool = true,
      environment: [String: String] = ["TERM": "xterm"]
    ) -> Bool {
      SupportReportProgressDisplay.shouldDisplay(
        plan: plan,
        debugEnabled: debugEnabled,
        errorIsInteractive: errorIsInteractive,
        environment: environment
      )
    }

    #expect(shouldDisplay(), "an interactive TTY with planned writes can display")
    #expect(!shouldDisplay(debugEnabled: true), "debug logs replace the spinner")
    #expect(!shouldDisplay(errorIsInteractive: false), "non-TTY stderr stays quiet")
    #expect(
      !shouldDisplay(environment: ["TERM": "dumb"]),
      "dumb terminals do not animate"
    )
    #expect(!shouldDisplay(plan: empty), "an empty plan has no progress to show")
    #expect(
      shouldDisplay(environment: ["TERM": "xterm", "NO_COLOR": "1"]),
      "NO_COLOR still displays, without color"
    )
  }
}
