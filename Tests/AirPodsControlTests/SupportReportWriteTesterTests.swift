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
  let modeRun = results.listeningModes.testRun
  let awarenessRun = results.conversationAwareness.testRun

  check(
    modeRun?.tests.map(\.mode)
      == [.off, .transparency, .adaptive],
    "noninitial modes are tested in canonical order"
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
    device.settleIntervals.count == 4,
    "each accepted mode is held before the next write"
  )
  check(
    device.settleIntervals.allSatisfy { $0 == 2 },
    "each mode is held for the documented two seconds"
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
  let snapshot = SupportReportSnapshot.capture(device: device)!
  let results = SupportReportWriteTester.run(device: device)
  let modeRun = results.listeningModes.testRun

  check(modeRun?.tests.count == 2, "a no-op does not skip later mode tests")
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
  let report = SupportReportDocument.make(snapshot: snapshot, writeTests: results)
  check(
    report.githubIssueDraft.report.contains("- `listening-mode set off`: no-op"),
    "the issue field includes the detailed no-op result"
  )
  check(
    report.githubIssueDraft.report.contains(
      "- `listening-mode set noise-cancellation`: verified"
    ),
    "the issue field includes the final mode-write result without a restoration label"
  )
}

func testWriteTesterDoesNotBareVerifyATargetAlreadyCurrent() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )
  // The Off write falls back to Transparency, so the next canonical target
  // is already the current state when its own write begins.
  device.listeningModeWriteOverride = {
    $0 == .off ? .transparency : $0
  }
  let snapshot = SupportReportSnapshot.capture(device: device)!
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
    modeRun?.tests.first { $0.mode == .adaptive }?.targetAlreadyCurrent == false,
    "a genuine transition is not flagged as already current"
  )
  check(
    modeRun?.restoration.attempted?.targetAlreadyCurrent == false,
    "restoration only runs from a different state, so it is never flagged"
  )

  let document = SupportReportDocument.make(
    snapshot: snapshot,
    writeTests: results
  )
  let issueReport = document.githubIssueDraft.report
  let terminalReport = document.terminalOutput
  check(
    issueReport.contains(
      "- `listening-mode set transparency`: "
        + "inconclusive (already in this state; no transition demonstrated)"
    ),
    "an undemonstrated transition gets the shared inconclusive verdict"
  )
  check(
    terminalReport.contains("Transparency")
      && terminalReport.contains(
        "INCONCLUSIVE · already in this state; no transition"
      ),
    "the terminal adapter renders the same inconclusive verdict"
  )
  check(
    !issueReport.contains("- `listening-mode set transparency`: verified\n"),
    "an undemonstrated transition never renders as a bare verified verdict"
  )
  check(
    issueReport.contains("- `listening-mode set adaptive`: verified\n"),
    "a demonstrated transition keeps the bare verified verdict"
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
  device.settleEffect = {
    device.listeningMode = device.lastListeningModeTarget
  }

  let results = SupportReportWriteTester.run(device: device)
  let modeRun = results.listeningModes.testRun

  check(
    modeRun?.tests.first?.mode == .adaptive
      && modeRun?.tests.first?.write.verified == true,
    "a mode is verified from its post-hold state"
  )
  check(
    modeRun?.restoration.attempted?.mode == .transparency
      && modeRun?.restoration.attempted?.write.verified == true,
    "the initial mode is verified only after its restoration hold"
  )
  check(
    device.settleIntervals.count == 2,
    "the tester waits for both the exploratory transition and final restoration"
  )
  check(
    modeRun?.finalMode == .transparency,
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

  let snapshot = SupportReportSnapshot.capture(device: device)!
  let results = SupportReportWriteTester.run(device: device)
  let modeRun = results.listeningModes.testRun

  check(
    modeRun?.tests.map(\.mode) == [.transparency, .adaptive],
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
  let report = SupportReportDocument.make(snapshot: snapshot, writeTests: results).terminalOutput
  check(
    report.contains("Adaptive") && report.contains("SETTER ERROR"),
    "the report distinguishes a setter error from a no-op"
  )
  check(
    report.contains("Remaining mode tests     SKIPPED · after setter error"),
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

  let snapshot = SupportReportSnapshot.capture(device: device)!
  let results = SupportReportWriteTester.run(device: device)
  let report = SupportReportDocument.make(snapshot: snapshot, writeTests: results).terminalOutput

  check(
    device.conversationAwarenessSetCount == 1,
    "an unchanged state needs no restoration attempt after a setter error"
  )
  check(
    report.contains("Conversation Awareness   SETTER ERROR"),
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

  let snapshot = SupportReportSnapshot.capture(device: device)!
  let results = SupportReportWriteTester.run(device: device)
  let report = SupportReportDocument.make(snapshot: snapshot, writeTests: results).terminalOutput

  check(
    results.conversationAwareness.testRun?.restored == false,
    "a rejected Conversation Awareness restoration is not treated as restored"
  )
  check(
    report.contains("Conversation Awareness   RESTORATION ERROR · setter rejected"),
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
    unreadableResults.listeningModes.skipReason
      == "initial state unreadable, nothing written",
    "an unreadable initial mode skips the mode tests"
  )
  check(
    unreadableResults.conversationAwareness.skipReason
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
    unexposedResults.listeningModes.skipReason == "setter not exposed",
    "a missing mode setter skips the mode tests"
  )
  check(
    unexposedResults.conversationAwareness.skipReason == "not supported",
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
    results.listeningModes.skipReason
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

func testWriteTesterStopsExplorationAndRestoresAfterInterruption() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  var caughtSignal: Int32?
  device.settleEffect = {
    if device.listeningModeSetCount == 1 {
      caughtSignal = SIGINT
    }
  }

  let snapshot = SupportReportSnapshot.capture(device: device)!
  let plan = SupportReportWriteTestPlan.make(device: device)
  let results = SupportReportWriteTester.run(
    plan: plan,
    device: device,
    interruptionSignal: { caughtSignal },
    writeError: { _ in }
  )
  let report = SupportReportDocument.make(snapshot: snapshot, writeTests: results).terminalOutput

  check(
    results.interruptedBySignal == SIGINT,
    "the first observed termination signal is retained"
  )
  check(
    results.listeningModes.testRun?.tests.map(\.mode) == [.off],
    "an interruption stops later exploratory mode writes"
  )
  check(
    results.listeningModes.testRun?.restoration.attempted?.mode == .noiseCancellation,
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
    results.conversationAwareness.skipReason == "interrupted before test",
    "the skipped capability is explained"
  )
  check(results.fullyRestored, "interrupted write tests still finish restoration")
  check(
    report.contains("INTERRUPTED · SIGINT; remaining tests skipped"),
    "the local report records the interruption"
  )
  check(
    report.contains("Restoration              RESTORED"),
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
  check(
    notices == [SupportReportWriteTester.interruptionNotice],
    "the real-signal path announces the interruption exactly once"
  )
  check(
    results.listeningModes.testRun?.tests.map(\.mode) == [.off],
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
    results.conversationAwareness.skipReason == "interrupted before test",
    "the interrupted CA test is reported as skipped"
  )
}

func testWriteTesterAnnouncesInterruptionOnceBeforeRestoration() {
  let device = FakeCompatibleAudioDevice(
    name: "",
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
    notices == ["Interrupt caught; restoring initial settings...\n"],
    "the interrupt notice is written exactly once with the documented wording"
  )
  check(
    noticesBeforeRestorationWrite == 1,
    "the interrupt notice is already written when the restoration write begins"
  )
  check(
    results.conversationAwareness.skipReason == "interrupted before test",
    "later checkpoints observe the same interruption without repeating the notice"
  )
}

func testWriteTesterInterruptionNoticeDefaultsToStandardError() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )
  var caughtSignal: Int32?
  device.settleEffect = { caughtSignal = SIGINT }

  guard let capture = tmpfile() else {
    check(false, "a temporary stderr capture file can be created")
    return
  }
  fflush(stderr)
  let originalStderr = dup(STDERR_FILENO)
  dup2(fileno(capture), STDERR_FILENO)

  let results = SupportReportWriteTester.run(
    plan: SupportReportWriteTestPlan.make(device: device),
    device: device,
    interruptionSignal: { caughtSignal }
  )

  fflush(stderr)
  dup2(originalStderr, STDERR_FILENO)
  close(originalStderr)

  rewind(capture)
  var captured = [UInt8]()
  var buffer = [UInt8](repeating: 0, count: 1024)
  while true {
    let readCount = fread(&buffer, 1, buffer.count, capture)
    guard readCount > 0 else { break }
    captured.append(contentsOf: buffer[0..<readCount])
  }
  fclose(capture)

  check(originalStderr >= 0, "the original stderr can be duplicated")
  check(
    results.interruptedBySignal == SIGINT,
    "the default-writer run still retains the interruption"
  )
  check(
    String(decoding: captured, as: UTF8.self)
      == SupportReportWriteTester.interruptionNotice,
    "the default interrupt notice goes to standard error, once"
  )
}

func testTerminationMonitorCapturesSIGHUP() {
  guard let monitor = SupportReportTerminationMonitor() else {
    check(false, "the production signal monitor installs for SIGHUP")
    return
  }
  check(kill(getpid(), SIGHUP) == 0, "the test process can deliver SIGHUP to itself")

  for _ in 0..<100 where monitor.caughtSignal == nil {
    usleep(10_000)
  }
  check(
    monitor.disarm() == SIGHUP,
    "the production signal monitor latches a caught SIGHUP"
  )
}

func runSupportReportWriteTesterTests() {
  testWriteTesterVerifiesAndRestores()
  testWriteTesterContinuesAfterNoOp()
  testWriteTesterDoesNotBareVerifyATargetAlreadyCurrent()
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
  testWriteTesterAnnouncesInterruptionOnceBeforeRestoration()
  testWriteTesterInterruptionNoticeDefaultsToStandardError()
  testTerminationMonitorCapturesSIGHUP()
}
