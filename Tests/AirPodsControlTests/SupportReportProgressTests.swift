import Darwin
import Dispatch

func testSupportReportProgressPlanAndEventOrder() {
  let device = FakeCompatibleAudioDevice()
  let plan = SupportReportWriteTestPlan.make(device: device)
  let operations = SupportReportWriteTestProgressPlan(plan).operations
  check(
    operations == [
      .listeningMode(.off),
      .listeningMode(.adaptive),
      .listeningMode(.noiseCancellation),
      .listeningModeRestoration,
      .conversationAwareness,
      .conversationAwarenessRestoration,
    ],
    "progress uses the fixed consented operation order"
  )

  var events: [SupportReportWriteTestProgressEvent] = []
  _ = SupportReportWriteTester.run(
    plan: plan,
    device: device,
    progress: { events.append($0) }
  )
  check(
    events == [
      .preparing,
      .operationStarted(.listeningMode(.off), step: 1, total: 6),
      .operationStarted(.listeningMode(.adaptive), step: 2, total: 6),
      .operationStarted(.listeningMode(.noiseCancellation), step: 3, total: 6),
      .operationStarted(.listeningModeRestoration, step: 4, total: 6),
      .operationStarted(.conversationAwareness, step: 5, total: 6),
      .operationStarted(.conversationAwarenessRestoration, step: 6, total: 6),
      .finished,
    ],
    "a complete run reports every planned operation and restoration"
  )
}

func testSupportReportProgressKeepsFixedOrdinalsThroughSkips() {
  let device = FakeCompatibleAudioDevice(
    conversationAwarenessSupported: false
  )
  device.listeningModeSetterAccepted = { mode in mode != .off }
  let plan = SupportReportWriteTestPlan.make(device: device)
  var events: [SupportReportWriteTestProgressEvent] = []

  _ = SupportReportWriteTester.run(
    plan: plan,
    device: device,
    progress: { events.append($0) }
  )

  check(
    events == [
      .preparing,
      .operationStarted(.listeningMode(.off), step: 1, total: 4),
      .operationSkipped(.listeningMode(.adaptive), step: 2, total: 4),
      .operationSkipped(.listeningMode(.noiseCancellation), step: 3, total: 4),
      .operationSkipped(.listeningModeRestoration, step: 4, total: 4),
      .finished,
    ],
    "skipped operations advance through the original fixed denominator"
  )
}

func testSupportReportProgressReportsRestorationFailureBeforeFinish() {
  let device = FakeCompatibleAudioDevice(
    conversationAwarenessSupported: false
  )
  device.listeningModeSetterAccepted = { mode in mode != .transparency }
  let plan = SupportReportWriteTestPlan.make(device: device)
  var events: [SupportReportWriteTestProgressEvent] = []

  let results = SupportReportWriteTester.run(
    plan: plan,
    device: device,
    progress: { events.append($0) }
  )

  check(!results.fullyRestored, "the fixture produces a restoration failure")
  check(
    Array(events.suffix(2)) == [.restorationFailed, .finished],
    "restoration failure is announced before progress finishes"
  )
}

func testSupportReportProgressLineRendering() {
  let event = SupportReportWriteTestProgressEvent.operationStarted(
    .listeningMode(.noiseCancellation),
    step: 3,
    total: 6
  )
  let first = SupportReportProgressLineRenderer.render(
    event,
    frameIndex: 0,
    terminalWidth: 80,
    colorEnabled: false
  )
  let second = SupportReportProgressLineRenderer.render(
    event,
    frameIndex: 1,
    terminalWidth: 80,
    colorEnabled: false
  )
  let colored = SupportReportProgressLineRenderer.render(
    event,
    frameIndex: 0,
    terminalWidth: 80,
    colorEnabled: true
  )
  let narrow = SupportReportProgressLineRenderer.render(
    event,
    frameIndex: 0,
    terminalWidth: 42,
    colorEnabled: false
  )

  check(
    first == "⠋ Write tests  [3/6] Testing listening mode: Noise cancellation…",
    "progress names the current listening-mode target"
  )
  check(second?.hasPrefix("⠙ Write tests") == true, "the next frame advances the spinner")
  check(
    colored?.hasPrefix("\u{001B}[1;36m⠋\u{001B}[0m Write tests") == true,
    "color styles only the spinner glyph"
  )
  check(
    narrow?.count == 41 && narrow?.contains("[3/6]") == true && narrow?.hasSuffix("…") == true,
    "narrow output preserves the counter and truncates the label before wrapping"
  )
  check(
    SupportReportProgressLineRenderer.render(
      event,
      frameIndex: 0,
      terminalWidth: 20,
      colorEnabled: false
    ) == nil,
    "progress is suppressed when the spinner and counter cannot fit"
  )
  check(
    SupportReportProgressDisplay.frameIntervalMilliseconds == 80,
    "the spinner uses the agreed animation cadence"
  )

  let awareness = SupportReportProgressLineRenderer.render(
    .operationStarted(.conversationAwareness, step: 5, total: 6),
    frameIndex: 0,
    terminalWidth: 80,
    colorEnabled: false
  ) ?? ""
  check(
    !awareness.contains("true") && !awareness.contains("false"),
    "progress does not disclose the Conversation Awareness state"
  )
}

func testSupportReportProgressEligibility() {
  let plan = SupportReportWriteTestPlan.make(device: FakeCompatibleAudioDevice())
  let terminal = ["TERM": "xterm-256color"]
  check(
    SupportReportProgressDisplay.shouldDisplay(
      plan: plan,
      debugEnabled: false,
      errorIsInteractive: true,
      environment: terminal
    ),
    "a normal stderr terminal enables progress"
  )
  check(
    !SupportReportProgressDisplay.shouldDisplay(
      plan: plan,
      debugEnabled: false,
      errorIsInteractive: false,
      environment: terminal
    ),
    "redirected stderr disables progress"
  )
  check(
    !SupportReportProgressDisplay.shouldDisplay(
      plan: plan,
      debugEnabled: true,
      errorIsInteractive: true,
      environment: terminal
    ),
    "debug diagnostics disable progress"
  )
  check(
    !SupportReportProgressDisplay.shouldDisplay(
      plan: plan,
      debugEnabled: false,
      errorIsInteractive: true,
      environment: ["TERM": "dumb"]
    ),
    "a dumb terminal disables progress"
  )
  check(
    SupportReportProgressDisplay.shouldDisplay(
      plan: plan,
      debugEnabled: false,
      errorIsInteractive: true,
      environment: ["TERM": "xterm", "NO_COLOR": "1"]
    ),
    "NO_COLOR keeps monochrome progress enabled"
  )

  let emptyPlan = SupportReportWriteTestPlan.make(
    device: FakeCompatibleAudioDevice(
      listeningModes: [],
      conversationAwarenessSupported: false
    )
  )
  check(
    !SupportReportProgressDisplay.shouldDisplay(
      plan: emptyPlan,
      debugEnabled: false,
      errorIsInteractive: true,
      environment: terminal
    ),
    "a plan with no operations does not start progress"
  )
}

func testSupportReportProgressClearsForInterruptAndRestoration() {
  let device = FakeCompatibleAudioDevice()
  let plan = SupportReportWriteTestPlan.make(device: device)
  var caughtSignal: Int32?
  device.settleEffect = {
    if caughtSignal == nil { caughtSignal = SIGINT }
  }
  var writes: [String] = []
  let display = SupportReportProgressDisplay(
    plan: plan,
    debugEnabled: false,
    errorIsInteractive: true,
    environment: ["TERM": "xterm"],
    terminalWidth: { 80 },
    animationInterval: .seconds(60),
    writeError: { writes.append($0) }
  )!

  let results = SupportReportWriteTester.run(
    plan: plan,
    device: device,
    interruptionSignal: { caughtSignal },
    writeError: { writes.append($0) },
    progress: { display.receive($0) }
  )

  let noticeIndex = writes.firstIndex(of: SupportReportWriteTester.interruptionNotice)
  let restorationIndex = writes.firstIndex(where: {
    $0.contains("[4/6] Restoring listening mode…")
  })
  check(results.interruptedBySignal == SIGINT, "the progress fixture is interrupted")
  check(
    noticeIndex != nil && restorationIndex != nil && noticeIndex! < restorationIndex!,
    "the permanent interrupt notice precedes resumed restoration progress"
  )
  check(
    noticeIndex.map { $0 > 0 && writes[$0 - 1] == "\r\u{001B}[2K" } == true,
    "the transient line is cleared before the interrupt notice"
  )
  check(
    !writes.joined().contains("\u{001B}[?25"),
    "progress never hides or shows the terminal cursor"
  )
}

func testSupportReportProgressLeavesRestorationWarningVisible() {
  let plan = SupportReportWriteTestPlan.make(device: FakeCompatibleAudioDevice())
  var writes: [String] = []
  let display = SupportReportProgressDisplay(
    plan: plan,
    debugEnabled: false,
    errorIsInteractive: true,
    environment: ["TERM": "xterm"],
    terminalWidth: { 80 },
    animationInterval: .seconds(60),
    writeError: { writes.append($0) }
  )!

  display.receive(.preparing)
  display.receive(.restorationFailed)
  display.receive(.finished)
  check(
    writes.last == SupportReportProgressDisplay.restorationWarning,
    "finish does not erase the permanent restoration warning"
  )
}

func runSupportReportProgressTests() {
  testSupportReportProgressPlanAndEventOrder()
  testSupportReportProgressKeepsFixedOrdinalsThroughSkips()
  testSupportReportProgressReportsRestorationFailureBeforeFinish()
  testSupportReportProgressLineRendering()
  testSupportReportProgressEligibility()
  testSupportReportProgressClearsForInterruptAndRestoration()
  testSupportReportProgressLeavesRestorationWarningVisible()
}
