import Darwin
import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Support report write flows")
struct SupportReportWriteFlowTests {
  @Test("Requires interactive consent and a testable write plan")
  func supportReportWriteTestConsent() throws {
    let device = FakeCompatibleAudioDevice()
    var errors = [String]()

    let declined = SupportReportInteraction.requestWriteTestConsent(
      plan: SupportReportWriteTestPlan.make(device: device),
      inputIsInteractive: true,
      readResponse: { "n" },
      writeError: { errors.append($0) }
    )
    #expect(!declined, "answering n declines the write tests")
    #expect(!errors.isEmpty, "interactive decline presents the write plan")

    let accepted = SupportReportInteraction.requestWriteTestConsent(
      plan: SupportReportWriteTestPlan.make(device: device),
      inputIsInteractive: true,
      readResponse: { "YES" },
      writeError: { _ in }
    )
    #expect(accepted, "an explicit yes consents")

    errors = []
    let noninteractive = SupportReportInteraction.requestWriteTestConsent(
      plan: SupportReportWriteTestPlan.make(device: device),
      inputIsInteractive: false,
      readResponse: {
        Issue.record("noninteractive consent never reads input")
        return "y"
      },
      writeError: { errors.append($0) }
    )
    #expect(!noninteractive, "noninteractive input cannot consent")
    #expect(!errors.isEmpty, "noninteractive use explains that consent was not granted")

    let nothingToTest = FakeCompatibleAudioDevice(
      listeningModes: [],
      conversationAwarenessSupported: false
    )
    errors = []
    let skipped = SupportReportInteraction.requestWriteTestConsent(
      plan: SupportReportWriteTestPlan.make(device: nothingToTest),
      inputIsInteractive: true,
      readResponse: {
        Issue.record("no consent question without testable capabilities")
        return "y"
      },
      writeError: { errors.append($0) }
    )
    #expect(!skipped, "nothing to test means no consent")
    #expect(errors.isEmpty, "nothing to test asks nothing")
  }

  @Test("Honors write-test flags and restores both fake settings")
  func supportReportWriteTestsCommandFlow() throws {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.off, .transparency, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false,
      reportMetadata: .fixture()
    )

    let consented = try parseInvocation(["support-report", "--with-write-tests"])
    var consentRequests = 0
    let outcome = CommandExecution.execute(
      consented,
      resolveDevice: { _, _ in device },
      supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
        consentRequests += 1
        return false
      })
    )
    #expect(consentRequests == 0, "--with-write-tests never asks again")
    #expect(
      outcome.supportReport?.summary.verified == 5,
      "the consented journey records every verified write and restoration"
    )
    #expect(outcome.supportReportIssueDraft != nil, "the completed journey creates a reviewable draft")
    #expect(
      device.currentListeningMode() == .noiseCancellation,
      "the fake device ends restored"
    )
    #expect(
      device.conversationAwarenessEnabled == false,
      "Conversation Awareness also ends restored"
    )

    let modeWritesAfterConsentedRun = device.listeningModeSetCount
    let awarenessWritesAfterConsentedRun = device.conversationAwarenessSetCount
    let skipped = try parseInvocation(["support-report", "--no-write-tests"])
    let skippedOutcome = CommandExecution.execute(
      skipped,
      resolveDevice: { _, _ in device },
      supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
        Issue.record("--no-write-tests never asks")
        return true
      })
    )
    #expect(
      skippedOutcome.supportReport != nil
        && device.listeningModeSetCount == modeWritesAfterConsentedRun
        && device.conversationAwarenessSetCount == awarenessWritesAfterConsentedRun,
      "the declined journey produces a report without writing"
    )

    let asked = try parseInvocation(["support-report"])
    var askCount = 0
    _ = CommandExecution.execute(
      asked,
      resolveDevice: { _, _ in device },
      supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
        askCount += 1
        return true
      })
    )
    #expect(askCount == 1, "the default invocation asks for consent exactly once")
    #expect(
      device.listeningModeSetCount > modeWritesAfterConsentedRun,
      "granted consent runs and restores the planned writes"
    )
  }

  @Test("Keeps the untested initial mode private in the issue report")
  func supportReportIssueReportDoesNotNameTheUntestedInitialMode() throws {
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

    #expect(
      results.listeningModes.testRun?.restoration.stateNeverChanged == true,
      "a state that never changes leaves the initial mode untested"
    )
    #expect(
      issueReport.contains(
        "- `listening-mode set` (captured initial mode): "
          + "skipped (already at initial mode; not demonstrated)"
      ),
      "the issue field keeps an unnamed row for the untested initial mode"
    )
    #expect(
      !issueReport.contains("`listening-mode set adaptive`"),
      "the issue field never names the initial mode in a write-test row"
    )
  }

  @Test("Writes only capabilities disclosed before consent")
  func supportReportRunsOnlyTheConsentedWritePlan() throws {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.transparency, .adaptive],
      listeningMode: .transparency,
      conversationAwarenessSupported: nil,
      conversationAwarenessEnabled: nil,
      reportMetadata: .fixture()
    )
    let invocation = try parseInvocation(["support-report"])

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

    #expect(
      device.listeningModeSetCount == 2,
      "execution writes only the modes disclosed before consent"
    )
    #expect(
      device.conversationAwarenessSetCount == 0,
      "a capability appearing after consent is not written"
    )
    #expect(outcome.supportReportIssueDraft != nil, "the consented-plan result remains reviewable")
  }

  @Test("Skips capabilities removed while consent is pending")
  func supportReportSkipsCapabilitiesRemovedDuringConsent() throws {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.transparency, .adaptive],
      listeningMode: .transparency,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false,
      reportMetadata: .fixture()
    )
    let invocation = try parseInvocation(["support-report"])

    _ = CommandExecution.execute(
      invocation,
      resolveDevice: { _, _ in device },
      supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
        device.listeningModes = [.transparency]
        device.exposesConversationAwarenessSetter = false
        return true
      })
    )

    #expect(
      device.listeningModeSetCount == 0,
      "a planned mode that is no longer advertised is not written"
    )
    #expect(
      device.conversationAwarenessSetCount == 0,
      "a setter that disappears during consent is not invoked"
    )
  }

  @Test("Preserves a listening mode changed while consent is pending")
  func supportReportSkipsAPlanWhoseInitialModeChangedDuringConsent() throws {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.transparency, .adaptive],
      listeningMode: .transparency,
      conversationAwarenessSupported: false,
      reportMetadata: .fixture()
    )
    let invocation = try parseInvocation(["support-report"])

    _ = CommandExecution.execute(
      invocation,
      resolveDevice: { _, _ in device },
      supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
        device.listeningMode = .adaptive
        return true
      })
    )

    #expect(
      device.listeningModeSetCount == 0,
      "a mode changed while consent is pending is not overwritten"
    )
    #expect(
      device.currentListeningMode() == .adaptive,
      "the user's newer listening mode remains active"
    )
  }

  @Test("Preserves Conversation Awareness changed while consent is pending")
  func supportReportSkipsAPlanWhoseAwarenessChangedDuringConsent() throws {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [],
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false,
      reportMetadata: .fixture(listeningModeQueryAnswered: false)
    )
    let invocation = try parseInvocation(["support-report"])

    _ = CommandExecution.execute(
      invocation,
      resolveDevice: { _, _ in device },
      supportReport: SupportReportCommand(requestWriteTestConsent: { _ in
        device.conversationAwarenessEnabled = true
        return true
      })
    )

    #expect(
      device.conversationAwarenessSetCount == 0,
      "Conversation Awareness changed while consent is pending is not overwritten"
    )
    #expect(
      device.conversationAwarenessState() == true,
      "the user's newer Conversation Awareness state remains active"
    )
  }

  @Test("Retains the preflight snapshot through fake writes")
  func supportReportPreservesThePreflightSnapshotDuringWrites() throws {
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

    let invocation = try parseInvocation(["support-report", "--with-write-tests"])
    let outcome = CommandExecution.execute(invocation) { _, _ in device }

    #expect(
      outcome.supportReport?.device.modelName == "AirPods Pro 3",
      "the report retains the compatibility snapshot captured before writes"
    )
    #expect(
      outcome.supportReportIssueDraft != nil,
      "a transient post-write metadata loss does not discard the reviewed issue draft"
    )
  }

  @Test("Reports a failed restoration as state-uncertain")
  func supportReportWriteTestsRestoreFailure() throws {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.transparency, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false,
      reportMetadata: .fixture()
    )
    device.listeningModeWriteOverride = { _ in .transparency }

    let invocation = try parseInvocation(["support-report", "--with-write-tests"])
    let outcome = CommandExecution.execute(invocation) { _, _ in device }
    #expect(outcome.exitCode == 7, "a failed restoration exits state-uncertain")
    #expect(device.currentListeningMode() == .transparency, "the final observed mode is retained")
    #expect(outcome.supportReportIssueDraft != nil, "a failed restoration still offers the issue draft")
  }

  @Test("Restores after a signal and reports interruption", arguments: [SIGHUP, SIGTERM])
  func supportReportSignalsInterruptAndRestore(signal: Int32) throws {
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

    let invocation = try parseInvocation(["support-report", "--with-write-tests"])
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

    #expect(
      outcome.exitCode == 128 + signal,
      "signal \(signal) produces the conventional shell exit status"
    )
    #expect(
      outcome.payload["result"] as? String == "interrupted"
        && outcome.payload["signal"] as? Int32 == signal,
      "the outcome records signal \(signal) as an interruption"
    )
    #expect(outcome.supportReportIssueDraft == nil, "an interrupted run offers no issue prompt")
    #expect(
      device.currentListeningMode() == .noiseCancellation,
      "signal \(signal) restores the initial mode before returning"
    )
    #expect(
      device.conversationAwarenessSetCount == 0,
      "signal \(signal) starts no later capability test"
    )
  }
}
