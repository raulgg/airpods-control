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
  check(prompt.contains("Run write tests? [y/N]"), "consent is an explicit question")
  check(prompt.contains("Changes are audible"), "consent warns about disruption")
  check(
    prompt.contains("Plan"),
    "consent makes the fixed scope clear"
  )
  check(
    prompt.contains("restored when possible; failures are reported"),
    "consent accurately describes restoration as best effort"
  )
  check(
    prompt.contains(
      "off, adaptive, noise-cancellation (about 2s each)"
    ),
    "consent lists the exact exploratory modes from the captured plan"
  )
  check(
    prompt.contains("Restore mode             transparency"),
    "consent identifies the separate restoration target"
  )
  check(
    prompt.contains("Conversation Awareness   toggle and restore"),
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
    unreadableCAPrompt.contains("Listening modes"),
    "readable modes are still promised"
  )
  check(
    !unreadableCAPrompt.contains("Conversation Awareness   toggle and restore"),
    "a Conversation Awareness test that would be skipped is not promised"
  )
}

func testSupportReportConsentRendererIsPureAndTTYOptional() {
  let plan = SupportReportWriteTestPlan.make(
    device: FakeCompatibleAudioDevice(name: "")
  )
  let first = SupportReportConsentRenderer.render(plan, colorEnabled: false)
  let second = SupportReportConsentRenderer.render(plan, colorEnabled: false)
  let colored = SupportReportConsentRenderer.render(plan, colorEnabled: true)

  check(first == second, "the consent renderer is deterministic for the same plan")
  check(
    first?.contains("\u{001B}[") == false
      && colored?.contains("\u{001B}[") == true,
    "consent color is controlled only by an explicit rendering option"
  )
  check(
    first?.contains("Plan") == true
      && first?.contains("Caution") == true
      && first?.contains("Restore") == true,
    "the compact consent output keeps plan, disruption, and restoration distinct"
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
    outcome.supportReportOutput.contains("Write tests"),
    "the consented CLI report carries the write-test section"
  )
  check(
    outcome.supportReportOutput.contains("Off")
      && outcome.supportReportOutput.contains("VERIFIED"),
    "each mode write gets a readable verdict row"
  )
  check(
    outcome.supportReportOutput.contains("VERIFIED · round trip"),
    "the Conversation Awareness round trip gets a terminal verdict"
  )
  check(
    outcome.supportReportOutput.contains("RESTORED"),
    "a clean run makes restoration prominent"
  )
  check(
    outcome.supportReportOutput.contains("4 verified"),
    "the CLI report summarizes the write-test outcomes"
  )
  check(
    outcome.supportReportOutput.contains("Available · tested below"),
    "the setter row points at the write-test section"
  )
  check(
    !outcome.supportReportOutput.contains("NOT RUN"),
    "a consented report has no not-run marker"
  )
  let issueReport = outcome.supportReportIssueDraft?.report ?? ""
  check(
    issueReport.contains("#### Write tests\n\n_Run with consent._")
      && issueReport.contains("- `listening-mode set off`: verified"),
    "the GitHub adapter independently renders the same write evidence"
  )
  check(
    outcome.supportReportIssueDraft.map {
      SupportReportIssue.safeURL(for: $0).prefilled
    } == true,
    "a four-mode write report fits in the prefilled issue URL"
  )
  check(
    outcome.supportReportIssueDraft?.report.contains("Initial state restored:") == false,
    "the issue field omits the restoration status"
  )
  check(
    outcome.supportReportIssueDraft?.report.contains(
      "- `listening-mode set noise-cancellation`: verified"
    ) == true,
    "the issue field includes the final mode-write verdict without a restoration label"
  )
  check(
    outcome.supportReportIssueDraft?.report.contains("- `listening-mode set off`: verified") == true,
    "the issue field includes each named mode-result row"
  )
  check(
    outcome.supportReportOutput.contains("Noise cancellation"),
    "the CLI includes the final mode-write verdict without a restoration label"
  )
  check(
    !outcome.supportReportOutput.contains("(restoration)")
      && outcome.supportReportIssueDraft?.report.contains("(restoration)") == false,
    "neither report uses a restoration label"
  )
  check(
    !outcome.supportReportOutput.contains("###")
      && !outcome.supportReportOutput.contains("`"),
    "the CLI adapter emits terminal-native output"
  )
  check(
    outcome.supportReportIssueDraft?.report.contains("Review complete") == false,
    "the issue field omits the CLI-only footer"
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
    skippedOutcome.supportReportOutput.contains("Status                   NOT RUN"),
    "a passive report says the write tests did not run"
  )
  check(
    skippedOutcome.supportReportOutput.contains("Available · not tested"),
    "a passive report keeps the untested setter wording"
  )
  check(
    !skippedOutcome.supportReportOutput.contains("VERIFIED"),
    "a passive report has no write-test verdicts"
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
    askedOutcome.supportReportOutput.contains("VERIFIED"),
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
    return SupportReportDocument.make(snapshot: snapshot, writeTests: results).githubIssueDraft.report
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
  let issueReport = SupportReportDocument.make(snapshot: snapshot, writeTests: results).githubIssueDraft.report

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
  let report = SupportReportDocument.make(snapshot: snapshot, writeTests: results)

  check(
    report.terminalOutput.contains("initial mode is not advertised"),
    "the local report keeps the actionable mode skip reason"
  )
  check(
    report.githubIssueDraft.report.contains("initial mode is not advertised"),
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
    !outcome.supportReportIssueDraft!.report.contains("listening-mode set noise-cancellation"),
    "the report contains no undisclosed mode write"
  )
  check(
    outcome.supportReportOutput.contains("SKIPPED · capability unavailable"),
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
    outcome.supportReportOutput.contains(
      "SKIPPED · planned listening modes are no longer advertised,"
    )
      && outcome.supportReportOutput.contains("nothing written"),
    "the local report explains the stale mode capability"
  )
  check(
    outcome.supportReportOutput.contains(
      "SKIPPED · capability or setter no longer exposed,"
    )
      && outcome.supportReportOutput.contains("nothing written"),
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
    modeOutcome.supportReportOutput.contains("SKIPPED · setter no longer exposed, nothing written"),
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
    awarenessOutcome.supportReportOutput.contains(
      "capability or setter no longer exposed"
    )
      && awarenessOutcome.supportReportOutput.contains("nothing")
      && awarenessOutcome.supportReportOutput.contains("written"),
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
    outcome.supportReportOutput.contains(
      "initial state changed after planning"
    )
      && outcome.supportReportOutput.contains("nothing")
      && outcome.supportReportOutput.contains("written"),
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
    outcome.supportReportOutput.contains(
      "initial state changed after planning"
    )
      && outcome.supportReportOutput.contains("nothing")
      && outcome.supportReportOutput.contains("written"),
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
    outcome.supportReportOutput.contains("Model                    AirPods Pro 3"),
    "the report retains the compatibility snapshot captured before writes"
  )
  check(
    outcome.supportReportOutput.contains("Restoration              RESTORED"),
    "the report still states the final restoration result"
  )
  check(
    outcome.supportReportIssueDraft != nil,
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
    outcome.supportReportOutput.contains("NOT RESTORED")
      && outcome.supportReportOutput.contains("listening mode is now")
      && outcome.supportReportOutput.contains("Transparency")
      && outcome.supportReportOutput.contains("manually in System Settings."),
    "a failed restoration names the final state and the manual fix"
  )
  check(
    outcome.supportReportIssueDraft?.report.contains("Initial state restored:") == false,
    "a failed restoration and manual fix remain terminal-only"
  )
  check(outcome.supportReportIssueDraft != nil, "a failed restoration still offers the issue draft")
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
  check(outcome.supportReportIssueDraft == nil, "an interrupted run never opens an issue prompt")
  check(
    outcome.supportReportOutput.contains(
      "INTERRUPTED · SIGTERM; remaining tests skipped"
    ),
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
    outcome.supportReportOutput.contains(
      "INTERRUPTED · SIGHUP; remaining tests skipped"
    ),
    "the interrupted local report names SIGHUP"
  )
  check(
    device.currentListeningMode() == .noiseCancellation,
    "the command restores the initial mode before returning the hangup exit"
  )
}

func runSupportReportWriteFlowTests() {
  testSupportReportWriteTestConsent()
  testSupportReportConsentRendererIsPureAndTTYOptional()
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
