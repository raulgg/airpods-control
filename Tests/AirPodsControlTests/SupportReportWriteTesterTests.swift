import Darwin
import Foundation

private func supportWriteTestSignalHandler(_: Int32) {}

func testWriteTestPlanProbesStrongestModesFirst() {
  let startedInTransparency = FakeCompatibleAudioDevice(
    listeningMode: .transparency,
    conversationAwarenessSupported: false
  )
  let transparencyPlan = SupportReportWriteTestPlan.make(
    device: startedInTransparency
  )
  check(
    transparencyPlan.listeningModeTargets
      == [.noiseCancellation, .adaptive, .transparency, .off],
    "Transparency stays in the probe list when it is not first"
  )

  let startedInNoiseCancellation = FakeCompatibleAudioDevice(
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )
  let noiseCancellationPlan = SupportReportWriteTestPlan.make(
    device: startedInNoiseCancellation
  )
  check(
    noiseCancellationPlan.listeningModeTargets
      == [.adaptive, .transparency, .off],
    "the already-current first probe is deferred to restoration"
  )
}

func testWriteTesterVerifiesAndRestores() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  let results = SupportReportWriteTester.run(device: device)
  let modeRun = results.listeningModes.testRun
  let awarenessRun = results.conversationAwareness.testRun

  check(
    modeRun?.tests.map(\.mode)
      == [.adaptive, .transparency, .off],
    "noninitial modes are tested strongest-first, with Off last"
  )
  check(
    modeRun?.tests.allSatisfy(\.write.verified) == true,
    "an applying device verifies every advertised mode"
  )
  check(
    modeRun?.restoration.attempted?.mode == .noiseCancellation
      && modeRun?.restoration.attempted?.write.verified == true,
    "the initial mode is verified separately during restoration"
  )
  check(modeRun?.restored == true, "the last test restores the mode")
  check(
    device.currentListeningMode() == .noiseCancellation,
    "the device ends in its initial listening mode"
  )
  check(
    awarenessRun?.toggle.verified == true
      && awarenessRun?.restoration.attempted?.verified == true,
    "the Conversation Awareness round trip verifies"
  )
  check(
    awarenessRun?.restored == true,
    "Conversation Awareness ends in its initial state"
  )
  check(
    device.conversationAwarenessState() == false,
    "the device ends with its initial Conversation Awareness value"
  )
  check(results.fullyRestored, "a fully applying device reports full restoration")
  check(device.listeningModeSetCount == 4, "each advertised mode is written once")
  check(
    device.conversationAwarenessSetCount == 2,
    "Conversation Awareness is written exactly twice"
  )
}

func testWriteTesterContinuesAfterNoOp() {
  let device = FakeCompatibleAudioDevice(
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
  let modeRun = results.listeningModes.testRun

  check(modeRun?.tests.count == 2, "a no-op does not skip later mode tests")
  let transparencyTest = modeRun?.tests.first { $0.mode == .transparency }
  check(
    transparencyTest?.write.verified == true
      && transparencyTest?.targetAlreadyCurrent == false,
    "Transparency is probed before Off, so the fallback does not hide it"
  )
  let offTest = modeRun?.tests.first { $0.mode == .off }
  check(offTest?.write.verified == false, "an unapplied off write is not verified")
  check(
    offTest?.write.observed == .transparency,
    "the Off no-op records the observed Transparency fallback"
  )
  check(
    modeRun?.tests.allSatisfy(\.write.setterAccepted) == true,
    "accepted no-op writes do not stop the test sequence"
  )
  check(
    modeRun?.restored == true,
    "later tests restore the initial listening mode"
  )
  check(
    modeRun?.restoration.attempted?.mode == .noiseCancellation,
    "restoration is recorded separately from exploratory tests"
  )
  check(
    device.settleIntervals.count == 3,
    "an accepted no-op is still held before testing the next mode"
  )
  check(
    results.conversationAwareness.testRun?.toggle.verified == false,
    "an unapplied Conversation Awareness toggle is not verified"
  )
  check(
    device.conversationAwarenessSetCount == 1,
    "an unchanged Conversation Awareness state needs no restore write"
  )
  check(
    results.conversationAwareness.testRun?.restored == true,
    "an unchanged Conversation Awareness state counts as restored"
  )
}

func testWriteTesterDoesNotBareVerifyATargetAlreadyCurrent() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )
  // Adaptive is probed immediately before Transparency. Landing Adaptive on
  // Transparency still cannot demonstrate the Transparency write.
  device.listeningModeWriteOverride = {
    $0 == .adaptive ? .transparency : $0
  }
  let results = SupportReportWriteTester.run(device: device)
  let modeRun = results.listeningModes.testRun

  let transparencyTest = modeRun?.tests.first { $0.mode == .transparency }
  check(
    transparencyTest?.targetAlreadyCurrent == true,
    "a target reached by an earlier fallback is recorded as already current"
  )
  check(
    transparencyTest?.write.verified == true,
    "the matching readback of an already-current target is still recorded"
  )
  check(
    modeRun?.tests.first { $0.mode == .off }?.targetAlreadyCurrent == false,
    "a genuine transition is not flagged as already current"
  )
  check(
    modeRun?.restoration.attempted?.targetAlreadyCurrent == false,
    "restoration only runs from a different state, so it is never flagged"
  )
}

func testWriteTesterVerifiesTransparencyWhenOffFallsBack() {
  let startedInTransparency = FakeCompatibleAudioDevice(
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .transparency,
    conversationAwarenessSupported: false
  )
  startedInTransparency.listeningModeWriteOverride = {
    $0 == .off ? .transparency : $0
  }
  let snapshot = SupportReportSnapshot.capture(device: startedInTransparency)
  let fromTransparency = SupportReportWriteTester.run(device: startedInTransparency)
  let fromTransparencyRun = fromTransparency.listeningModes.testRun

  check(
    fromTransparencyRun?.tests.map(\.mode)
      == [.noiseCancellation, .adaptive, .transparency, .off],
    "the initial mode stays in the probe list when it is not first"
  )
  let transparencyFromStart = fromTransparencyRun?.tests.first {
    $0.mode == .transparency
  }
  check(
    transparencyFromStart?.targetAlreadyCurrent == false
      && transparencyFromStart?.write.verified == true,
    "Transparency is probed from Adaptive before Off can bounce back to it"
  )
  check(
    fromTransparencyRun?.tests.first { $0.mode == .off }?.write.verified == false,
    "the disabled Off write remains a no-op"
  )
  check(
    fromTransparencyRun?.restoration.stateNeverChanged == true
      && fromTransparencyRun?.restored == true,
    "Off fallback returns to the captured initial mode without a restore write"
  )

  let document = SupportReportDocument.make(
    snapshot: snapshot,
    writeTests: fromTransparency
  )
  check(
    document.summary.inconclusive == 0 && document.summary.verified == 3,
    "Off fallback from Transparency does not yield an inconclusive verdict"
  )
  check(
    !document.terminalOutput.contains("INCONCLUSIVE"),
    "the terminal report does not present Transparency as inconclusive"
  )
  check(
    !document.githubIssueDraft.report.contains("captured initial mode"),
    "a demonstrated initial mode is not an unnamed skipped restoration row"
  )

  let startedInNoiseCancellation = FakeCompatibleAudioDevice(
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )
  startedInNoiseCancellation.listeningModeWriteOverride = {
    $0 == .off ? .transparency : $0
  }
  let fromNoiseCancellation = SupportReportWriteTester.run(
    device: startedInNoiseCancellation
  )
  let fromNoiseCancellationRun = fromNoiseCancellation.listeningModes.testRun
  let transparencyAfterOff = fromNoiseCancellationRun?.tests.first {
    $0.mode == .transparency
  }
  check(
    fromNoiseCancellationRun?.tests.map(\.mode)
      == [.adaptive, .transparency, .off],
    "the already-current first probe is deferred to restoration"
  )
  check(
    transparencyAfterOff?.targetAlreadyCurrent == false
      && transparencyAfterOff?.write.verified == true,
    "Transparency is still a real transition when Off is last"
  )
  check(
    fromNoiseCancellationRun?.restoration.attempted?.mode == .noiseCancellation
      && fromNoiseCancellationRun?.restoration.attempted?.write.verified == true,
    "restoration still demonstrates the captured initial mode"
  )
}

func testWriteTesterVerifiesSettledTransitionsBeforeReturning() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    appliesListeningModeWrite: false,
    conversationAwarenessSupported: false
  )
  device.settleEffect = {
    device.listeningMode = device.lastListeningModeTarget
  }

  let results = SupportReportWriteTester.run(device: device)
  let modeRun = results.listeningModes.testRun

  check(
    modeRun?.tests.map(\.mode) == [.adaptive, .transparency]
      && modeRun?.tests.allSatisfy(\.write.verified) == true,
    "each mode is verified from its post-hold state"
  )
  check(
    modeRun?.restoration.stateNeverChanged == true,
    "the initial mode is already restored by its exploratory probe"
  )
  check(
    device.settleIntervals.count == 2,
    "the tester waits for both advertised-mode holds"
  )
  check(
    modeRun?.finalMode == .transparency,
    "results return only after the initial mode is restored"
  )
}

func testWriteTesterStopsOnSetterErrorAndRestores() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )
  device.listeningModeSetterAccepted = { $0 != .transparency }

  let results = SupportReportWriteTester.run(device: device)
  let modeRun = results.listeningModes.testRun

  check(
    modeRun?.tests.map(\.mode) == [.adaptive, .transparency],
    "a setter error skips remaining exploratory writes"
  )
  check(
    modeRun?.stoppedAfterSetterError == true,
    "the exploratory setter error is recorded separately from restoration"
  )
  check(
    device.listeningModeSetCount == 3,
    "a setter error is followed only by one restoration attempt"
  )
  check(
    device.settleIntervals.count == 3,
    "the accepted test, rejected test, and restoration are all held"
  )
  check(
    modeRun?.restored == true,
    "the best-effort restoration returns to the initial mode"
  )
  check(
    modeRun?.restoration.attempted?.mode == .noiseCancellation,
    "restoration is recorded after the interrupted tests"
  )
}

func testWriteTesterReportsConversationAwarenessRestorationSetterError() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [],
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  device.conversationAwarenessSetterAccepted = { target in target }

  let results = SupportReportWriteTester.run(device: device)

  check(
    results.conversationAwareness.testRun?.restored == false,
    "a rejected Conversation Awareness restoration is not treated as restored"
  )
  check(
    results.conversationAwareness.testRun?.toggle.verified == true,
    "a failed restoration does not erase the toggle that did verify"
  )
  check(
    results.conversationAwareness.testRun?.finalState == true
      && !results.fullyRestored,
    "the failed restoration retains the final state and fails the run"
  )
}

func testWriteTesterSkipsUnreadableAndUnexposedCapabilities() {
  let unreadable = FakeCompatibleAudioDevice(
    listeningModes: [.off, .transparency],
    listeningMode: nil,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: nil
  )
  let unreadableResults = SupportReportWriteTester.run(device: unreadable)
  check(
    unreadableResults.listeningModes.skipReason != nil,
    "an unreadable initial mode skips the mode tests"
  )
  check(
    unreadableResults.conversationAwareness.skipReason != nil,
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
    conversationAwarenessSupported: false
  )
  unexposed.exposesListeningModeSetter = false
  let unexposedResults = SupportReportWriteTester.run(device: unexposed)
  check(
    unexposedResults.listeningModes.skipReason != nil,
    "a missing mode setter skips the mode tests"
  )
  check(
    unexposedResults.conversationAwareness.skipReason != nil,
    "unsupported Conversation Awareness skips its test"
  )
  check(unexposed.listeningModeSetCount == 0, "no write reaches a missing setter")

  let unadvertised = FakeCompatibleAudioDevice(
    listeningModes: [.adaptive, .noiseCancellation],
    listeningMode: .transparency,
    conversationAwarenessSupported: false
  )
  let unadvertisedResults = SupportReportWriteTester.run(device: unadvertised)
  check(
    unadvertisedResults.listeningModes.skipReason != nil,
    "an unadvertised initial mode makes the write-test plan unsafe"
  )
  check(
    unadvertised.listeningModeSetCount == 0,
    "no mode is written when the initial mode cannot be restored safely"
  )
}

func testWriteTesterReportsFailedRestore() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  // Every write lands on transparency, so the final restore write misses.
  device.listeningModeWriteOverride = { _ in .transparency }
  let results = SupportReportWriteTester.run(device: device)
  let modeRun = results.listeningModes.testRun

  check(
    modeRun?.restored == false,
    "a restore write that lands elsewhere reports a failed restoration"
  )
  check(
    modeRun?.finalMode == .transparency,
    "the final listening mode is recorded for the report"
  )
  check(!results.fullyRestored, "a failed mode restore fails full restoration")
  check(
    results.conversationAwareness.testRun?.restored == true,
    "the Conversation Awareness restore is judged independently"
  )
}

func testRunInterruptiblyRestoresAfterARealSignalDuringModeHold() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  device.settleEffect = {
    if device.listeningModeSetCount == 1 {
      check(
        kill(getpid(), SIGINT) == 0,
        "the real signal can be delivered during the mode hold"
      )
    }
  }

  var notices: [String] = []
  let results = SupportReportWriteTester.runInterruptibly(
    plan: SupportReportWriteTestPlan.make(device: device),
    device: device,
    writeError: { notices.append($0) }
  )

  check(
    results.interruptedBySignal == SIGINT,
    "the production monitor propagates a real signal into the runner"
  )
  check(notices.count == 1, "the real-signal path announces the interruption exactly once")
  check(
    results.listeningModes.testRun?.tests.map(\.mode) == [.adaptive],
    "a real signal stops later exploratory mode writes"
  )
  check(
    results.listeningModes.testRun?.restoration.attempted?.mode == .noiseCancellation,
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
    interruptionSignal: { caughtSignal },
    writeError: { _ in }
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
    results.conversationAwareness.testRun?.restored == true,
    "the interrupted round trip reports successful restoration"
  )
}

func testWriteTesterDoesNotStartAwarenessAfterBoundaryInterruption() {
  let device = FakeCompatibleAudioDevice(
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
    interruptionSignal: { caughtSignal },
    writeError: { _ in }
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
    results.conversationAwareness.skipReason != nil,
    "the interrupted CA test is reported as skipped"
  )
}

func testWriteTesterAnnouncesInterruptionOnceBeforeRestoration() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  var caughtSignal: Int32?
  var notices: [String] = []
  var noticesBeforeRestorationWrite: Int?
  device.settleEffect = {
    if device.listeningModeSetCount == 1 {
      caughtSignal = SIGINT
    }
  }
  // The initial mode is written only by the restoration attempt, so this
  // hook observes the notice count at the moment restoration begins.
  device.listeningModeSetterAccepted = { target in
    if target == .noiseCancellation {
      noticesBeforeRestorationWrite = notices.count
    }
    return true
  }

  let results = SupportReportWriteTester.run(
    plan: SupportReportWriteTestPlan.make(device: device),
    device: device,
    interruptionSignal: { caughtSignal },
    writeError: { notices.append($0) }
  )

  check(
    results.interruptedBySignal == SIGINT,
    "the announced interruption is also retained in the results"
  )
  check(
    notices.count == 1,
    "the interrupt notice is written exactly once"
  )
  check(
    noticesBeforeRestorationWrite == 1,
    "the interrupt notice is already written when the restoration write begins"
  )
  check(
    results.conversationAwareness.skipReason != nil,
    "later checkpoints observe the same interruption without repeating the notice"
  )
}

func runSupportReportWriteTesterTests() {
  testWriteTestPlanProbesStrongestModesFirst()
  testWriteTesterVerifiesAndRestores()
  testWriteTesterContinuesAfterNoOp()
  testWriteTesterDoesNotBareVerifyATargetAlreadyCurrent()
  testWriteTesterVerifiesTransparencyWhenOffFallsBack()
  testWriteTesterVerifiesSettledTransitionsBeforeReturning()
  testWriteTesterStopsOnSetterErrorAndRestores()
  testWriteTesterReportsConversationAwarenessRestorationSetterError()
  testWriteTesterSkipsUnreadableAndUnexposedCapabilities()
  testWriteTesterReportsFailedRestore()
  testRunInterruptiblyRestoresAfterARealSignalDuringModeHold()
  testTerminationMonitorRestoresCompleteSignalAction()
  testWriteTesterRestoresConversationAwarenessAfterInterruption()
  testWriteTesterDoesNotStartAwarenessAfterBoundaryInterruption()
  testWriteTesterAnnouncesInterruptionOnceBeforeRestoration()
}
