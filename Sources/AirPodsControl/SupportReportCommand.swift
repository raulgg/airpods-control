import Foundation

// The support-report workflow. Like every command it only returns an
// outcome; prompting, printing, and process exit stay outside execution.
struct SupportReportCommand {
  let requestWriteTestConsent: (SupportReportWriteTestPlan) -> Bool
  let runWriteTests: (
    _ plan: SupportReportWriteTestPlan,
    _ device: any CompatibleAudioDevice
  ) -> SupportReportWriteTestResults

  // Consent defaults to declined so a caller that skips the wiring can only
  // produce a read-only report; main injects the interactive prompt.
  init(
    requestWriteTestConsent: @escaping (SupportReportWriteTestPlan) -> Bool = { _ in
      false
    },
    runWriteTests: @escaping (
      _ plan: SupportReportWriteTestPlan,
      _ device: any CompatibleAudioDevice
    ) -> SupportReportWriteTestResults = { plan, device in
      SupportReportWriteTester.runInterruptibly(plan: plan, device: device)
    }
  ) {
    self.requestWriteTestConsent = requestWriteTestConsent
    self.runWriteTests = runWriteTests
  }

  private enum Disposition {
    case completed
    case restorationFailed
    case interrupted(signal: Int32)
  }

  func outcome(
    writeTests preference: WriteTestsPreference,
    device: any CompatibleAudioDevice
  ) -> CommandOutcome {
    // Identify the device before consenting to or running any write. The
    // snapshot taken here is the one rendered after the writes.
    guard let snapshot = SupportReportSnapshot.capture(device: device) else {
      return Self.unidentifiedDeviceOutcome()
    }
    let plan = SupportReportWriteTestPlan.make(device: device)
    let consented: Bool
    switch preference {
    case .always: consented = true
    case .never: consented = false
    case .ask: consented = requestWriteTestConsent(plan)
    }
    let writeTests = consented ? runWriteTests(plan, device) : nil
    let report = SupportReportDocument.make(snapshot: snapshot, writeTests: writeTests)

    switch Self.disposition(of: writeTests) {
    case .completed:
      return CommandOutcome(
        plain: "",
        payload: ["result": "ok"],
        supportReport: report
      )
    case .restorationFailed:
      return CommandOutcome(
        plain: "",
        exitCode: 3,
        payload: ["result": "no-op"],
        supportReport: report
      )
    case let .interrupted(signal):
      return CommandOutcome(
        plain: "",
        exitCode: 128 + signal,
        payload: ["result": "interrupted", "signal": signal],
        supportReport: report
      )
    }
  }

  private static func disposition(
    of writeTests: SupportReportWriteTestResults?
  ) -> Disposition {
    guard let writeTests else { return .completed }
    if let signal = writeTests.interruptedBySignal {
      return .interrupted(signal: signal)
    }
    return writeTests.fullyRestored ? .completed : .restorationFailed
  }

  static func noDeviceOutcome() -> CommandOutcome {
    CommandOutcome(
      plain: """
      No unique AirPods or Beats report device is available.
      Connect exactly one compatible AirPods or Beats device as a macOS output device,
      then run `airpods-control support-report` again.
      Nothing was sent to GitHub.
      """,
      exitCode: 1,
      payload: ["error": "no-device", "result": "error"]
    )
  }

  private static func unidentifiedDeviceOutcome() -> CommandOutcome {
    CommandOutcome(
      plain: """
      A compatible audio device is connected, but it could not be identified
      as AirPods or Beats from its model metadata.
      No report was generated. Nothing was sent to GitHub.
      You can open a compatibility issue manually:
      \(SupportReportIssue.formURL.absoluteString)
      """,
      exitCode: 1,
      payload: ["error": "unidentified-device", "result": "error"]
    )
  }
}
