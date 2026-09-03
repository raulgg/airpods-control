import Darwin
import Dispatch

func testSupportReportProgressTracksCompleteAndSkippedWorkflows() {
  let device = FakeCompatibleAudioDevice()
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
  check(
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

func testSupportReportProgressKeepsRestorationFailureVisible() {
  let device = FakeCompatibleAudioDevice(
    conversationAwarenessSupported: false
  )
  device.listeningModeSetterAccepted = { mode in mode != .transparency }
  let plan = SupportReportWriteTestPlan.make(device: device)
  var events: [SupportReportWriteTestProgressEvent] = []
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
    progress: {
      events.append($0)
      display.receive($0)
    }
  )

  check(!results.fullyRestored, "the fixture produces a restoration failure")
  check(
    Array(events.suffix(2)) == [.restorationFailed, .finished],
    "restoration failure is announced before progress finishes"
  )
  check(
    writes.last?.hasPrefix("\r") == false,
    "finishing leaves the permanent restoration warning visible"
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
    $0.contains("Restoring listening mode…")
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

func runSupportReportProgressTests() {
  testSupportReportProgressTracksCompleteAndSkippedWorkflows()
  testSupportReportProgressKeepsRestorationFailureVisible()
  testSupportReportProgressClearsForInterruptAndRestoration()
}
