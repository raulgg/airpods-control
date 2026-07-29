import Darwin
import Foundation

func testSupportReportWriteTestConsent() {
  let device = FakeCompatibleAudioDevice(name: "")
  var errors = [String]()

  let declined = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: device),
    inputIsInteractive: true,
    readResponse: { "n" },
    writeError: { errors.append($0) }
  )
  check(!declined, "answering n declines the write tests")
  let prompt = errors.joined()
  check(prompt.contains("Run the write tests? [y/N]"), "consent is an explicit question")
  check(prompt.contains("may be disruptive"), "consent warns about disruption")
  check(
    prompt.contains("After you confirm, the command will run only the checks listed above."),
    "consent makes the fixed scope clear"
  )
  check(
    prompt.contains("tries to restore"),
    "consent accurately describes restoration as best effort"
  )
  check(
    prompt.contains(
      "switch through advertised listening modes recognized by this CLI: "
        + "off, adaptive, noise-cancellation"
    ),
    "consent lists the exact exploratory modes from the captured plan"
  )
  check(
    prompt.contains(
      "restore the captured initial listening mode (transparency) if needed"
    ),
    "consent identifies the separate restoration target"
  )
  check(
    prompt.contains(
      "toggle Conversation Awareness away from the captured initial state and back"
    ),
    "consent lists the Conversation Awareness toggle"
  )
  check(prompt.contains("read-only"), "declining explains the fallback report")

  let accepted = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: device),
    inputIsInteractive: true,
    readResponse: { "YES" },
    writeError: { _ in }
  )
  check(accepted, "an explicit yes consents")

  errors = []
  let noninteractive = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: device),
    inputIsInteractive: false,
    readResponse: {
      check(false, "noninteractive consent never reads input")
      return "y"
    },
    writeError: { errors.append($0) }
  )
  check(!noninteractive, "noninteractive input cannot consent")
  check(
    errors.joined().contains("--with-write-tests"),
    "noninteractive use points at the consent flag"
  )

  let nothingToTest = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    conversationAwarenessSupported: false
  )
  errors = []
  let skipped = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: nothingToTest),
    inputIsInteractive: true,
    readResponse: {
      check(false, "no consent question without testable capabilities")
      return "y"
    },
    writeError: { errors.append($0) }
  )
  check(!skipped, "nothing to test means no consent")
  check(errors.isEmpty, "nothing to test asks nothing")

  let unreadableCA = FakeCompatibleAudioDevice(
    name: "",
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: nil
  )
  errors = []
  _ = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: unreadableCA),
    inputIsInteractive: true,
    readResponse: { "n" },
    writeError: { errors.append($0) }
  )
  let unreadableCAPrompt = errors.joined()
  check(
    unreadableCAPrompt.contains(
      "switch through advertised listening modes recognized by this CLI"
    ),
    "readable modes are still promised"
  )
  check(
    !unreadableCAPrompt.contains(
      "toggle Conversation Awareness away from the captured initial state and back"
    ),
    "a Conversation Awareness test that would be skipped is not promised"
  )
}

func testSupportReportWriteTestsCommandFlow() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture()
  )

  let consented = try! parseInvocation(["support-report", "--with-write-tests"])
  var consentRequests = 0
  let outcome = CommandExecution.execute(
    consented,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
      consentRequests += 1
      return false
    })
  )
  check(consentRequests == 0, "--with-write-tests never asks again")
  check(outcome.exitCode == 0, "a restored write-test run succeeds")
  check(
    outcome.plain.contains("### Write tests (run with consent)"),
    "the consented report carries the write-test section"
  )
  check(
    outcome.plain.contains("- `listening-mode set off`: verified"),
    "each mode write gets a verdict line"
  )
  check(
    outcome.plain.contains("- `conversation-awareness set`: verified round trip"),
    "the Conversation Awareness round trip gets a verdict line"
  )
  check(
    outcome.plain.contains("\n\nInitial state restored: yes"),
    "a clean run reports restoration"
  )
  check(
    !outcome.plain.contains("- Initial state restored:"),
    "restoration status is not part of the write-result list"
  )
  check(
    outcome.plain.contains("Listening-mode setter: exposed (see write tests)"),
    "the setter line points at the write-test section"
  )
  check(
    !outcome.plain.contains("Write tests: not run"),
    "a consented report has no not-run marker"
  )
  let issueReport = outcome.issueDraft?.report ?? ""
  check(
    issueReport.hasPrefix("- Device family: AirPods")
      && issueReport.contains("#### Write tests (run with consent)")
      && issueReport.contains("- `listening-mode set off`: verified"),
    "the form field contains the compatibility details and write results"
  )
  check(
    outcome.issueDraft.map { SupportReport.safeIssueURL(for: $0).prefilled } == true,
    "a four-mode write report fits in the prefilled issue URL"
  )
  check(
    !issueReport.contains("Initial state restored:"),
    "the issue field omits the restoration status"
  )
  check(
    outcome.issueDraft?.report.contains(
      "- `listening-mode set noise-cancellation`: verified"
    ) == true,
    "the issue field includes the final mode-write verdict without a restoration label"
  )
  check(
    outcome.issueDraft?.report.contains("- `listening-mode set off`: verified") == true,
    "the issue field includes each named mode-result row"
  )
  check(
    outcome.plain.contains(
      "- `listening-mode set noise-cancellation`: verified"
    ),
    "the terminal includes the final mode-write verdict without a restoration label"
  )
  check(
    !outcome.plain.contains("(restoration)")
      && outcome.issueDraft?.report.contains("(restoration)") == false,
    "neither report uses a restoration label"
  )
  check(
    outcome.issueDraft?.report.contains("Created locally by") == false,
    "the issue field omits the local-only footer"
  )
  check(
    device.currentListeningMode() == .noiseCancellation,
    "the fake device ends restored"
  )

  let skipped = try! parseInvocation(["support-report", "--no-write-tests"])
  let skippedOutcome = CommandExecution.execute(
    skipped,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
      check(false, "--no-write-tests never asks")
      return true
    })
  )
  check(
    skippedOutcome.plain.contains("- Write tests: not run"),
    "a passive report says the write tests did not run"
  )
  check(
    skippedOutcome.plain.contains("exposed, not tested by this report"),
    "a passive report keeps the untested setter wording"
  )
  check(
    !skippedOutcome.plain.contains("### Write tests"),
    "a passive report has no write-test section"
  )

  let asked = try! parseInvocation(["support-report"])
  var askCount = 0
  let askedOutcome = CommandExecution.execute(
    asked,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
      askCount += 1
      return true
    })
  )
  check(askCount == 1, "the default invocation asks for consent exactly once")
  check(
    askedOutcome.plain.contains("### Write tests (run with consent)"),
    "granted consent runs the write tests"
  )
}

func testSupportReportIssueReportIncludesCompleteModeResults() {
  func issueReport(initialMode: ListeningMode) -> String {
    let device = FakeCompatibleAudioDevice(
      name: "",
      listeningModes: [.off, .transparency, .adaptive],
      listeningMode: initialMode,
      appliesListeningModeWrite: false,
      conversationAwarenessSupported: false,
      reportMetadata: .fixture()
    )
    let snapshot = SupportReportSnapshot.capture(device: device)!
    let results = SupportReportWriteTester.run(device: device)
    return SupportReport.render(snapshot, writeTests: results).issueDraft.report
  }

  let transparencyInitial = issueReport(initialMode: .transparency)
  let adaptiveInitial = issueReport(initialMode: .adaptive)

  check(
    transparencyInitial != adaptiveInitial,
    "the issue field preserves the state-dependent mode results shown locally"
  )
  check(
    transparencyInitial.contains("- `listening-mode set adaptive`: no-op"),
    "the issue field includes the attempted alternate mode"
  )
}

func testSupportReportIssueReportDoesNotNameTheUntestedInitialMode() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .adaptive],
    listeningMode: .adaptive,
    appliesListeningModeWrite: false,
    conversationAwarenessSupported: false,
    reportMetadata: .fixture()
  )
  let snapshot = SupportReportSnapshot.capture(device: device)!
  let results = SupportReportWriteTester.run(device: device)
  let issueReport = SupportReport.render(snapshot, writeTests: results).issueDraft.report

  check(
    results.listeningModes.testRun?.restoration.stateNeverChanged == true,
    "a state that never changes leaves the initial mode untested"
  )
  check(
    issueReport.contains(
      "- `listening-mode set` (captured initial mode): "
        + "skipped (state never changed from initial)"
    ),
    "the issue field keeps an unnamed row for the untested initial mode"
  )
  check(
    !issueReport.contains("`listening-mode set adaptive`"),
    "the issue field never names the initial mode in a write-test row"
  )
}

func testSupportReportIssueReportIncludesStateDependentModeSkipReasons() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .adaptive],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )
  let snapshot = SupportReportSnapshot.capture(device: device)!
  let results = SupportReportWriteTester.run(device: device)
  let report = SupportReport.render(snapshot, writeTests: results)

  check(
    report.markdown.contains("initial mode is not advertised"),
    "the local report keeps the actionable mode skip reason"
  )
  check(
    report.issueDraft.report.contains("initial mode is not advertised"),
    "the issue draft includes the actionable mode skip reason"
  )
}

func testSupportReportRunsOnlyTheConsentedWritePlan() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: nil,
    conversationAwarenessEnabled: nil,
    reportMetadata: .fixture()
  )
  let invocation = try! parseInvocation(["support-report"])

  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
      device.listeningModes.append(.noiseCancellation)
      device.conversationAwarenessSupported = true
      device.conversationAwarenessEnabled = false
      return true
    })
  )

  check(
    device.listeningModeSetCount == 2,
    "execution writes only the mode target and restoration disclosed before consent"
  )
  check(
    device.conversationAwarenessSetCount == 0,
    "a capability appearing after consent is not written"
  )
  check(
    !outcome.plain.contains("listening-mode set noise-cancellation"),
    "the report contains no undisclosed mode write"
  )
  check(
    outcome.plain.contains(
      "`conversation-awareness set`: skipped (capability unavailable)"
    ),
    "the report preserves the consented capability snapshot"
  )
}

func testSupportReportSkipsCapabilitiesRemovedDuringConsent() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture()
  )
  let invocation = try! parseInvocation(["support-report"])

  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
      device.listeningModes = [.transparency]
      device.exposesConversationAwarenessSetter = false
      return true
    })
  )

  check(
    device.listeningModeSetCount == 0,
    "a planned mode that is no longer advertised is not written"
  )
  check(
    device.conversationAwarenessSetCount == 0,
    "a setter that disappears during consent is not invoked"
  )
  check(
    outcome.plain.contains(
      "`listening-mode set`: skipped "
        + "(planned listening modes are no longer advertised, nothing written)"
    ),
    "the local report explains the stale mode capability"
  )
  check(
    outcome.plain.contains(
      "`conversation-awareness set`: skipped "
        + "(capability or setter no longer exposed, nothing written)"
    ),
    "the local report explains the stale Conversation Awareness capability"
  )
}

func testSupportReportSkipsASetterOrSupportRemovedDuringConsent() {
  let invocation = try! parseInvocation(["support-report"])
  let modeDevice = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: false
  )
  let modeOutcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in modeDevice },
    supportReport: SupportReportCommand(
      requestWriteTestConsent: { _ in
        modeDevice.exposesListeningModeSetter = false
        return true
      },
      runWriteTests: { plan, device in
        SupportReportWriteTester.run(plan: plan, device: device)
      }
    )
  )

  check(
    modeDevice.listeningModeSetCount == 0,
    "a listening-mode setter removed during consent is not invoked"
  )
  check(
    modeOutcome.plain.contains(
      "`listening-mode set`: skipped "
        + "(setter no longer exposed, nothing written)"
    ),
    "the local report explains the stale listening-mode setter"
  )

  let awarenessDevice = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    listeningMode: nil,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  let awarenessOutcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in awarenessDevice },
    supportReport: SupportReportCommand(
      requestWriteTestConsent: { _ in
        awarenessDevice.conversationAwarenessSupported = false
        return true
      },
      runWriteTests: { plan, device in
        SupportReportWriteTester.run(plan: plan, device: device)
      }
    )
  )

  check(
    awarenessDevice.conversationAwarenessSetCount == 0,
    "Conversation Awareness support removed during consent prevents a write"
  )
  check(
    awarenessOutcome.plain.contains(
      "`conversation-awareness set`: skipped "
        + "(capability or setter no longer exposed, nothing written)"
    ),
    "the local report explains stale Conversation Awareness support"
  )
}

func testSupportReportSkipsAPlanWhoseInitialModeChangedDuringConsent() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: false,
    reportMetadata: .fixture()
  )
  let invocation = try! parseInvocation(["support-report"])

  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
      device.listeningMode = .adaptive
      return true
    })
  )

  check(
    device.listeningModeSetCount == 0,
    "a mode changed while consent is pending is not overwritten"
  )
  check(
    device.currentListeningMode() == .adaptive,
    "the user's newer listening mode remains active"
  )
  check(
    outcome.plain.contains(
      "`listening-mode set`: skipped "
        + "(initial state changed after planning, nothing written)"
    ),
    "the report explains why the stale mode plan was skipped"
  )
}

func testSupportReportSkipsAPlanWhoseAwarenessChangedDuringConsent() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture(listeningModeQueryAnswered: false)
  )
  let invocation = try! parseInvocation(["support-report"])

  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
      device.conversationAwarenessEnabled = true
      return true
    })
  )

  check(
    device.conversationAwarenessSetCount == 0,
    "Conversation Awareness changed while consent is pending is not overwritten"
  )
  check(
    device.conversationAwarenessState() == true,
    "the user's newer Conversation Awareness state remains active"
  )
  check(
    outcome.plain.contains(
      "`conversation-awareness set`: skipped "
        + "(initial state changed after planning, nothing written)"
    ),
    "the report explains why the stale Conversation Awareness plan was skipped"
  )
}

func testSupportReportPreservesThePreflightSnapshotDuringWrites() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: false,
    reportMetadata: .fixture()
  )
  device.settleEffect = {
    device.reportMetadata = .fixture(
      family: nil,
      modelIdentifier: nil,
      listeningModeQueryAnswered: false
    )
  }

  let invocation = try! parseInvocation(["support-report", "--with-write-tests"])
  let outcome = CommandExecution.execute(invocation) { _, _ in device }

  check(
    outcome.exitCode == 0,
    "losing model metadata after a restored run does not replace the report outcome"
  )
  check(
    outcome.plain.contains("Model: AirPods Pro 3"),
    "the report retains the compatibility snapshot captured before writes"
  )
  check(
    outcome.plain.contains("Initial state restored: yes"),
    "the report still states the final restoration result"
  )
  check(
    outcome.issueDraft != nil,
    "a transient post-write metadata loss does not discard the reviewed issue draft"
  )
}

func testSupportReportWriteTestsRestoreFailure() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture()
  )
  device.listeningModeWriteOverride = { _ in .transparency }

  let invocation = try! parseInvocation(["support-report", "--with-write-tests"])
  let outcome = CommandExecution.execute(invocation) { _, _ in device }
  check(outcome.exitCode == 3, "a failed restoration exits no-op")
  check(
    outcome.plain.contains(
      "Initial state restored: no, listening mode is now transparency. "
        + "Restore manually in System Settings."
    ),
    "a failed restoration names the final state and the manual fix"
  )
  check(
    outcome.issueDraft?.report.contains("Initial state restored:") == false,
    "a failed restoration and manual fix remain terminal-only"
  )
  check(outcome.issueDraft != nil, "a failed restoration still offers the issue draft")
}

func testSupportReportInterruptedWriteTestsUseSignalExit() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture()
  )
  var caughtSignal: Int32?
  device.settleEffect = {
    if device.listeningModeSetCount == 1 {
      caughtSignal = SIGTERM
    }
  }

  let invocation = try! parseInvocation(["support-report", "--with-write-tests"])
  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(runWriteTests: { plan, resolvedDevice in
      SupportReportWriteTester.run(
        plan: plan,
        device: resolvedDevice,
        interruptionSignal: { caughtSignal },
        writeError: { _ in }
      )
    })
  )

  check(outcome.exitCode == 143, "SIGTERM produces the conventional shell exit status")
  check(
    outcome.payload["result"] as? String == "interrupted",
    "the outcome distinguishes interruption from a completed report"
  )
  check(
    outcome.payload["signal"] as? Int32 == SIGTERM,
    "the outcome records the caught signal"
  )
  check(outcome.issueDraft == nil, "an interrupted run never opens an issue prompt")
  check(
    outcome.plain.contains("Write tests interrupted by SIGTERM"),
    "the interrupted local report explains why testing stopped"
  )
  check(
    device.currentListeningMode() == .noiseCancellation,
    "the command restores the initial mode before returning the signal exit"
  )
  check(
    device.conversationAwarenessSetCount == 0,
    "the command starts no later capability test after interruption"
  )
}

func testSupportReportHangupWriteTestsUseSignalExit() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture()
  )
  var caughtSignal: Int32?
  device.settleEffect = {
    if device.listeningModeSetCount == 1 {
      caughtSignal = SIGHUP
    }
  }

  let invocation = try! parseInvocation(["support-report", "--with-write-tests"])
  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(runWriteTests: { plan, resolvedDevice in
      SupportReportWriteTester.run(
        plan: plan,
        device: resolvedDevice,
        interruptionSignal: { caughtSignal },
        writeError: { _ in }
      )
    })
  )

  check(outcome.exitCode == 129, "SIGHUP produces the conventional shell exit status")
  check(
    outcome.payload["signal"] as? Int32 == SIGHUP,
    "the outcome records the caught hangup signal"
  )
  check(
    outcome.plain.contains("Write tests interrupted by SIGHUP"),
    "the interrupted local report names SIGHUP"
  )
  check(
    device.currentListeningMode() == .noiseCancellation,
    "the command restores the initial mode before returning the hangup exit"
  )
}

func runSupportReportWriteFlowTests() {
  testSupportReportWriteTestConsent()
  testSupportReportWriteTestsCommandFlow()
  testSupportReportIssueReportIncludesCompleteModeResults()
  testSupportReportIssueReportDoesNotNameTheUntestedInitialMode()
  testSupportReportIssueReportIncludesStateDependentModeSkipReasons()
  testSupportReportRunsOnlyTheConsentedWritePlan()
  testSupportReportSkipsCapabilitiesRemovedDuringConsent()
  testSupportReportSkipsASetterOrSupportRemovedDuringConsent()
  testSupportReportSkipsAPlanWhoseInitialModeChangedDuringConsent()
  testSupportReportSkipsAPlanWhoseAwarenessChangedDuringConsent()
  testSupportReportPreservesThePreflightSnapshotDuringWrites()
  testSupportReportWriteTestsRestoreFailure()
  testSupportReportInterruptedWriteTestsUseSignalExit()
  testSupportReportHangupWriteTestsUseSignalExit()
}
