import Darwin
import Foundation

func testSupportReportWriteTestConsent() {
  let device = FakeCompatibleAudioDevice()
  var errors = [String]()

  let declined = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: device),
    inputIsInteractive: true,
    readResponse: { "n" },
    writeError: { errors.append($0) }
  )
  check(!declined, "answering n declines the write tests")
  check(!errors.isEmpty, "interactive decline presents the write plan")

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
  check(!errors.isEmpty, "noninteractive use explains that consent was not granted")

  let nothingToTest = FakeCompatibleAudioDevice(
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
}

func testSupportReportWriteTestsCommandFlow() {
  let device = FakeCompatibleAudioDevice(
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
  check(
    outcome.supportReport?.summary.verified == 5,
    "the consented journey records every verified write and restoration"
  )
  check(outcome.supportReportIssueDraft != nil, "the completed journey creates a reviewable draft")
  check(
    device.currentListeningMode() == .noiseCancellation,
    "the fake device ends restored"
  )
  check(
    device.conversationAwarenessEnabled == false,
    "Conversation Awareness also ends restored"
  )

  let modeWritesAfterConsentedRun = device.listeningModeSetCount
  let awarenessWritesAfterConsentedRun = device.conversationAwarenessSetCount
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
    skippedOutcome.supportReport != nil
      && device.listeningModeSetCount == modeWritesAfterConsentedRun
      && device.conversationAwarenessSetCount == awarenessWritesAfterConsentedRun,
    "the declined journey produces a report without writing"
  )

  let asked = try! parseInvocation(["support-report"])
  var askCount = 0
  _ = CommandExecution.execute(
    asked,
    resolveDevice: { _, _ in device },
    supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
      askCount += 1
      return true
    })
  )
  check(askCount == 1, "the default invocation asks for consent exactly once")
  check(
    device.listeningModeSetCount > modeWritesAfterConsentedRun,
    "granted consent runs and restores the planned writes"
  )
}

func testSupportReportIssueReportDoesNotNameTheUntestedInitialMode() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.off, .transparency, .adaptive],
    listeningMode: .adaptive,
    appliesListeningModeWrite: false,
    conversationAwarenessSupported: false,
    reportMetadata: .fixture()
  )
  let snapshot = SupportReportSnapshot.capture(device: device)
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

func testSupportReportRunsOnlyTheConsentedWritePlan() {
  let device = FakeCompatibleAudioDevice(
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
    "execution writes only the modes disclosed before consent"
  )
  check(
    device.conversationAwarenessSetCount == 0,
    "a capability appearing after consent is not written"
  )
  check(outcome.supportReportIssueDraft != nil, "the consented-plan result remains reviewable")
}

func testSupportReportSkipsCapabilitiesRemovedDuringConsent() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture()
  )
  let invocation = try! parseInvocation(["support-report"])

  _ = CommandExecution.execute(
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
}

func testSupportReportSkipsAPlanWhoseInitialModeChangedDuringConsent() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: false,
    reportMetadata: .fixture()
  )
  let invocation = try! parseInvocation(["support-report"])

  _ = CommandExecution.execute(
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
}

func testSupportReportSkipsAPlanWhoseAwarenessChangedDuringConsent() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [],
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture(listeningModeQueryAnswered: false)
  )
  let invocation = try! parseInvocation(["support-report"])

  _ = CommandExecution.execute(
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
}

func testSupportReportPreservesThePreflightSnapshotDuringWrites() {
  let device = FakeCompatibleAudioDevice(
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
    outcome.supportReport?.device.modelName == "AirPods Pro 3",
    "the report retains the compatibility snapshot captured before writes"
  )
  check(
    outcome.supportReportIssueDraft != nil,
    "a transient post-write metadata loss does not discard the reviewed issue draft"
  )
}

func testSupportReportWriteTestsRestoreFailure() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture()
  )
  device.listeningModeWriteOverride = { _ in .transparency }

  let invocation = try! parseInvocation(["support-report", "--with-write-tests"])
  let outcome = CommandExecution.execute(invocation) { _, _ in device }
  check(outcome.exitCode == 7, "a failed restoration exits state-uncertain")
  check(device.currentListeningMode() == .transparency, "the final observed mode is retained")
  check(outcome.supportReportIssueDraft != nil, "a failed restoration still offers the issue draft")
}

func testSupportReportSignalsInterruptAndRestore() {
  for signal in [SIGHUP, SIGTERM] {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.transparency, .adaptive, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false,
      reportMetadata: .fixture()
    )
    var caughtSignal: Int32?
    device.settleEffect = {
      if device.listeningModeSetCount == 1 {
        caughtSignal = signal
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

    check(
      outcome.exitCode == 128 + signal,
      "signal \(signal) produces the conventional shell exit status"
    )
    check(
      outcome.payload["result"] as? String == "interrupted"
        && outcome.payload["signal"] as? Int32 == signal,
      "the outcome records signal \(signal) as an interruption"
    )
    check(outcome.supportReportIssueDraft == nil, "an interrupted run offers no issue prompt")
    check(
      device.currentListeningMode() == .noiseCancellation,
      "signal \(signal) restores the initial mode before returning"
    )
    check(
      device.conversationAwarenessSetCount == 0,
      "signal \(signal) starts no later capability test"
    )
  }
}

func runSupportReportWriteFlowTests() {
  testSupportReportWriteTestConsent()
  testSupportReportWriteTestsCommandFlow()
  testSupportReportIssueReportDoesNotNameTheUntestedInitialMode()
  testSupportReportRunsOnlyTheConsentedWritePlan()
  testSupportReportSkipsCapabilitiesRemovedDuringConsent()
  testSupportReportSkipsAPlanWhoseInitialModeChangedDuringConsent()
  testSupportReportSkipsAPlanWhoseAwarenessChangedDuringConsent()
  testSupportReportPreservesThePreflightSnapshotDuringWrites()
  testSupportReportWriteTestsRestoreFailure()
  testSupportReportSignalsInterruptAndRestore()
}
