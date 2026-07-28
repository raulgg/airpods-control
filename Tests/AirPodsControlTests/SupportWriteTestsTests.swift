import Darwin
import Foundation

private func supportWriteTestSignalHandler(_: Int32) {}

func testWriteTesterVerifiesAndRestores() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  let results = SupportReportWriteTester.run(device: device)

  check(
    results.modeResults.map(\.mode)
      == [.off, .transparency, .adaptive],
    "noninitial modes are tested in canonical order"
  )
  check(
    results.modeResults.allSatisfy(\.verified),
    "an applying device verifies every advertised mode"
  )
  check(
    results.listeningModeRestorationResult?.mode == .noiseCancellation
      && results.listeningModeRestorationResult?.verified == true,
    "the initial mode is verified separately during restoration"
  )
  check(results.listeningModeRestored == true, "the last test restores the mode")
  check(
    device.currentListeningMode() == .noiseCancellation,
    "the device ends in its initial listening mode"
  )
  check(
    results.conversationAwarenessToggleVerified == true,
    "the Conversation Awareness round trip verifies"
  )
  check(
    results.conversationAwarenessRestored == true,
    "Conversation Awareness ends in its initial state"
  )
  check(
    device.conversationAwarenessState() == false,
    "the device ends with its initial Conversation Awareness value"
  )
  check(results.fullyRestored, "a fully applying device reports full restoration")
  check(device.listeningModeSetCount == 4, "each advertised mode is written once")
  check(
    device.listeningModeEffectWaitCount == 4,
    "each accepted mode is held before the next write"
  )
  check(
    device.conversationAwarenessSetCount == 2,
    "Conversation Awareness is written exactly twice"
  )
}

func testWriteTesterContinuesAfterNoOp() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    appliesConversationAwarenessWrite: false
  )
  device.listeningModeWriteOverride = {
    $0 == .off ? .transparency : $0
  }
  let results = SupportReportWriteTester.run(device: device)

  check(results.modeResults.count == 2, "a no-op does not skip later mode tests")
  let offResult = results.modeResults.first { $0.mode == .off }
  check(offResult?.verified == false, "an unapplied off write is not verified")
  check(
    offResult?.observed == .transparency,
    "the Off no-op records the observed Transparency fallback"
  )
  check(
    results.modeResults.allSatisfy(\.setterAccepted),
    "accepted no-op writes do not stop the test sequence"
  )
  check(
    results.listeningModeRestored == true,
    "later tests restore the initial listening mode"
  )
  check(
    results.listeningModeRestorationResult?.mode == .noiseCancellation,
    "restoration is recorded separately from exploratory tests"
  )
  check(
    device.listeningModeEffectWaitCount == 3,
    "an accepted no-op is still held before testing the next mode"
  )
  check(
    results.conversationAwarenessToggleVerified == false,
    "an unapplied Conversation Awareness toggle is not verified"
  )
  check(
    device.conversationAwarenessSetCount == 1,
    "an unchanged Conversation Awareness state needs no restore write"
  )
  check(
    results.conversationAwarenessRestored == true,
    "an unchanged Conversation Awareness state counts as restored"
  )
  let report = SupportReport.make(device: device, writeTests: results)
  check(
    report?.issueDraft.body.contains("- `listening-mode set off`: no-op") == true,
    "the issue body includes the detailed no-op result"
  )
  check(
    report?.issueDraft.body.contains(
      "- `listening-mode set noise-cancellation`: verified"
    ) == true,
    "the issue body includes the final mode-write result without a restoration label"
  )
}

func testWriteTesterVerifiesSettledTransitionsBeforeReturning() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    appliesListeningModeWrite: false,
    conversationAwarenessSupported: false
  )
  device.listeningModeEffect = {
    device.listeningMode = device.lastListeningModeTarget
  }

  let results = SupportReportWriteTester.run(device: device)

  check(
    results.modeResults.first?.mode == .adaptive
      && results.modeResults.first?.verified == true,
    "a mode is verified from its post-hold state"
  )
  check(
    results.listeningModeRestorationResult?.mode == .transparency
      && results.listeningModeRestorationResult?.verified == true,
    "the initial mode is verified only after its restoration hold"
  )
  check(
    device.listeningModeEffectWaitCount == 2,
    "the tester waits for both the exploratory transition and final restoration"
  )
  check(
    results.finalListeningMode == .transparency,
    "results return only after the initial mode is restored"
  )
}

func testWriteTesterStopsOnSetterErrorAndRestores() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )
  device.listeningModeSetterAccepted = { $0 != .adaptive }

  let results = SupportReportWriteTester.run(device: device)

  check(
    results.modeResults.map(\.mode) == [.transparency, .adaptive],
    "a setter error skips remaining exploratory writes"
  )
  check(
    results.modeTestsStoppedAfterSetterError,
    "the exploratory setter error is recorded separately from restoration"
  )
  check(
    device.listeningModeSetCount == 3,
    "a setter error is followed only by one restoration attempt"
  )
  check(
    device.listeningModeEffectWaitCount == 3,
    "the accepted test, rejected test, and restoration are all held"
  )
  check(
    results.listeningModeRestored == true,
    "the best-effort restoration returns to the initial mode"
  )
  check(
    results.listeningModeRestorationResult?.mode == .noiseCancellation,
    "restoration is recorded after the interrupted tests"
  )
  let report = SupportReport.make(device: device, writeTests: results)?.markdown ?? ""
  check(
    report.contains("- `listening-mode set adaptive`: setter error"),
    "the report distinguishes a setter error from a no-op"
  )
  check(
    report.contains("- Remaining listening-mode tests: skipped after setter error"),
    "the report explains why later mode tests are absent"
  )
}

func testWriteTesterReportsConversationAwarenessSetterError() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  device.conversationAwarenessSetterAccepted = { _ in false }

  let results = SupportReportWriteTester.run(device: device)
  let report = SupportReport.make(device: device, writeTests: results)?.markdown ?? ""

  check(
    device.conversationAwarenessSetCount == 1,
    "an unchanged state needs no restoration attempt after a setter error"
  )
  check(
    report.contains("- `conversation-awareness set`: setter error"),
    "the report distinguishes a Conversation Awareness setter error from a no-op"
  )
}

func testWriteTesterReportsConversationAwarenessRestorationSetterError() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  device.conversationAwarenessSetterAccepted = { target in target }

  let results = SupportReportWriteTester.run(device: device)
  let report = SupportReport.make(device: device, writeTests: results)?.markdown ?? ""

  check(
    results.conversationAwarenessRestored == false,
    "a rejected Conversation Awareness restoration is not treated as restored"
  )
  check(
    report.contains(
      "- `conversation-awareness set`: restoration setter error"
    ),
    "the report distinguishes a restoration setter error from a no-op"
  )
}

func testWriteTesterSkipsUnreadableAndUnexposedCapabilities() {
  let unreadable = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency],
    listeningMode: nil,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: nil
  )
  let unreadableResults = SupportReportWriteTester.run(device: unreadable)
  check(
    unreadableResults.modeTestsSkippedReason == "initial state unreadable, nothing written",
    "an unreadable initial mode skips the mode tests"
  )
  check(
    unreadableResults.conversationAwarenessSkippedReason
      == "initial state unreadable, nothing written",
    "an unreadable Conversation Awareness state skips its test"
  )
  check(unreadable.listeningModeSetCount == 0, "no mode write happens blind")
  check(
    unreadable.conversationAwarenessSetCount == 0,
    "no Conversation Awareness write happens blind"
  )
  check(
    unreadableResults.fullyRestored,
    "skipped capabilities never fail restoration"
  )

  let unexposed = FakeCompatibleAudioDevice(
    name: "",
    conversationAwarenessSupported: false
  )
  unexposed.exposesListeningModeSetter = false
  let unexposedResults = SupportReportWriteTester.run(device: unexposed)
  check(
    unexposedResults.modeTestsSkippedReason == "setter not exposed",
    "a missing mode setter skips the mode tests"
  )
  check(
    unexposedResults.conversationAwarenessSkippedReason == "not supported",
    "unsupported Conversation Awareness skips its test"
  )
  check(unexposed.listeningModeSetCount == 0, "no write reaches a missing setter")
}

func testWriteTesterSkipsAnUnadvertisedInitialMode() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.adaptive, .noiseCancellation],
    listeningMode: .transparency,
    conversationAwarenessSupported: false
  )

  let results = SupportReportWriteTester.run(device: device)

  check(
    results.modeTestsSkippedReason
      == "initial mode is not advertised, nothing written",
    "an unadvertised initial mode makes the write-test plan unsafe"
  )
  check(
    device.listeningModeSetCount == 0,
    "no mode is written when the initial mode cannot be restored safely"
  )
}

func testWriteTesterReportsFailedRestore() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  // Every write lands on transparency, so the final restore write misses.
  device.listeningModeWriteOverride = { _ in .transparency }
  let results = SupportReportWriteTester.run(device: device)

  check(
    results.listeningModeRestored == false,
    "a restore write that lands elsewhere reports a failed restoration"
  )
  check(
    results.finalListeningMode == .transparency,
    "the final listening mode is recorded for the report"
  )
  check(!results.fullyRestored, "a failed mode restore fails full restoration")
  check(
    results.conversationAwarenessRestored == true,
    "the Conversation Awareness restore is judged independently"
  )
}

func testWriteTesterStopsExplorationAndRestoresAfterInterruption() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  var caughtSignal: Int32?
  device.listeningModeEffect = {
    if device.listeningModeSetCount == 1 {
      caughtSignal = SIGINT
    }
  }

  let plan = SupportReportWriteTestPlan.make(device: device)
  let results = SupportReportWriteTester.run(
    plan: plan,
    device: device,
    interruptionSignal: { caughtSignal }
  )
  let report = SupportReport.make(device: device, writeTests: results)?.markdown ?? ""

  check(
    results.interruptedBySignal == SIGINT,
    "the first observed termination signal is retained"
  )
  check(
    results.modeResults.map(\.mode) == [.off],
    "an interruption stops later exploratory mode writes"
  )
  check(
    results.listeningModeRestorationResult?.mode == .noiseCancellation,
    "the initial listening mode is still restored after interruption"
  )
  check(
    device.listeningModeSetCount == 2,
    "only the interrupted mode write and its restoration are performed"
  )
  check(
    device.conversationAwarenessSetCount == 0,
    "an interruption prevents a later Conversation Awareness test"
  )
  check(
    results.conversationAwarenessSkippedReason == "interrupted before test",
    "the skipped capability is explained"
  )
  check(results.fullyRestored, "interrupted write tests still finish restoration")
  check(
    report.contains("Write tests interrupted by SIGINT"),
    "the local report records the interruption"
  )
  check(
    report.contains("Initial state restored: yes"),
    "the local report confirms cleanup after interruption"
  )
}

func testRunInterruptiblyRestoresAfterARealSignalDuringModeHold() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  device.listeningModeEffect = {
    if device.listeningModeSetCount == 1 {
      check(
        kill(getpid(), SIGINT) == 0,
        "the real signal can be delivered during the mode hold"
      )
    }
  }

  let results = SupportReportWriteTester.runInterruptibly(
    plan: SupportReportWriteTestPlan.make(device: device),
    device: device
  )

  check(
    results.interruptedBySignal == SIGINT,
    "the production monitor propagates a real signal into the runner"
  )
  check(
    results.modeResults.map(\.mode) == [.off],
    "a real signal stops later exploratory mode writes"
  )
  check(
    results.listeningModeRestorationResult?.mode == .noiseCancellation,
    "the real-signal path restores the captured listening mode"
  )
  check(
    device.listeningMode == .noiseCancellation,
    "the fake device is restored before the real-signal path returns"
  )
  check(
    device.conversationAwarenessSetCount == 0,
    "the real-signal path does not begin the later awareness test"
  )
}

func testTerminationMonitorCapturesSIGINT() {
  guard let monitor = SupportReportTerminationMonitor() else {
    check(false, "the production signal monitor installs")
    return
  }
  check(kill(getpid(), SIGINT) == 0, "the test process can deliver SIGINT to itself")

  for _ in 0..<100 where monitor.caughtSignal == nil {
    usleep(10_000)
  }
  check(kill(getpid(), SIGTERM) == 0, "the test process can deliver a second signal")

  let caughtSignal = monitor.disarm()
  check(
    caughtSignal == SIGINT,
    "the production signal monitor retains the first signal without terminating early"
  )
  check(
    monitor.disarm() == caughtSignal,
    "repeated Swift teardown returns the cached signal result"
  )
}

func testTerminationMonitorRestoresCompleteSignalAction() {
  var customAction = sigaction()
  customAction.__sigaction_u.__sa_handler = supportWriteTestSignalHandler
  sigemptyset(&customAction.sa_mask)
  sigaddset(&customAction.sa_mask, SIGUSR1)
  customAction.sa_flags = SA_NODEFER

  var originalAction = sigaction()
  check(
    sigaction(SIGTERM, &customAction, &originalAction) == 0,
    "the test can install a custom SIGTERM action"
  )
  defer {
    var action = originalAction
    _ = sigaction(SIGTERM, &action, nil)
  }

  guard let monitor = SupportReportTerminationMonitor() else {
    check(false, "the production signal monitor installs over a custom action")
    return
  }
  _ = monitor.disarm()

  var restoredAction = sigaction()
  check(
    sigaction(SIGTERM, nil, &restoredAction) == 0,
    "the restored SIGTERM action can be inspected"
  )
  check(
    restoredAction.sa_flags == customAction.sa_flags,
    "the monitor restores the prior sigaction flags"
  )
  check(
    sigismember(&restoredAction.sa_mask, SIGUSR1) == 1,
    "the monitor restores the prior sigaction mask"
  )
}

func testWriteTesterRestoresConversationAwarenessAfterInterruption() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  var caughtSignal: Int32?
  device.conversationAwarenessSetterAccepted = { target in
    if target {
      caughtSignal = SIGTERM
    }
    return true
  }

  let results = SupportReportWriteTester.run(
    plan: SupportReportWriteTestPlan.make(device: device),
    device: device,
    interruptionSignal: { caughtSignal }
  )

  check(
    results.interruptedBySignal == SIGTERM,
    "an interruption during the Conversation Awareness toggle is retained"
  )
  check(
    device.conversationAwarenessSetCount == 2,
    "Conversation Awareness restoration still runs after interruption"
  )
  check(
    device.conversationAwarenessState() == false,
    "Conversation Awareness returns to its captured initial state"
  )
  check(
    results.conversationAwarenessRestored == true,
    "the interrupted round trip reports successful restoration"
  )
}

func testWriteTesterDoesNotStartAwarenessAfterBoundaryInterruption() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  let plan = SupportReportWriteTestPlan.make(device: device)
  var caughtSignal: Int32?
  device.conversationAwarenessStateEffect = {
    caughtSignal = SIGINT
  }

  let results = SupportReportWriteTester.run(
    plan: plan,
    device: device,
    interruptionSignal: { caughtSignal }
  )

  check(
    device.conversationAwarenessSetCount == 0,
    "an interruption observed at the CA boundary prevents a new toggle"
  )
  check(
    results.interruptedBySignal == SIGINT,
    "the CA-boundary interruption is retained"
  )
  check(
    results.conversationAwarenessSkippedReason == "interrupted before test",
    "the interrupted CA test is reported as skipped"
  )
}

func runSupportWriteTestsTests() {
  testWriteTesterVerifiesAndRestores()
  testWriteTesterContinuesAfterNoOp()
  testWriteTesterVerifiesSettledTransitionsBeforeReturning()
  testWriteTesterStopsOnSetterErrorAndRestores()
  testWriteTesterReportsConversationAwarenessSetterError()
  testWriteTesterReportsConversationAwarenessRestorationSetterError()
  testWriteTesterSkipsUnreadableAndUnexposedCapabilities()
  testWriteTesterSkipsAnUnadvertisedInitialMode()
  testWriteTesterReportsFailedRestore()
  testWriteTesterStopsExplorationAndRestoresAfterInterruption()
  testRunInterruptiblyRestoresAfterARealSignalDuringModeHold()
  testTerminationMonitorCapturesSIGINT()
  testTerminationMonitorRestoresCompleteSignalAction()
  testWriteTesterRestoresConversationAwarenessAfterInterruption()
  testWriteTesterDoesNotStartAwarenessAfterBoundaryInterruption()
}
