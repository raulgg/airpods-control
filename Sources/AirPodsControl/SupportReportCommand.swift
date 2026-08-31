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
    // Capture before consenting to or running any write. Identity is useful
    // report data, but it is not a prerequisite for a safe partial report.
    let snapshot = SupportReportSnapshot.capture(device: device)
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
        supportReport: report
      )
    case .restorationFailed:
      return CommandOutcome(
        plain: "",
        terminalReason: .stateUncertain,
        supportReport: report
      )
    case let .interrupted(signal):
      return CommandOutcome(
        plain: "",
        terminalReason: .caughtSignal(signal),
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
    resolutionFailureOutcome(.noDevice)
  }

  static func resolutionFailureOutcome(_ reason: TerminalReason) -> CommandOutcome {
    let availability: String
    switch reason {
    case .noDevice:
      availability = "No compatible AirPods or Beats report device is available."
    case .ambiguousDevice:
      availability = "Multiple compatible AirPods or Beats report devices are available."
    case .unavailable:
      availability = "AirPods or Beats report-device discovery is unavailable."
    case .readError:
      availability = "AirPods or Beats report-device discovery failed."
    default:
      preconditionFailure("support-report resolution cannot end as \(reason.token)")
    }
    return CommandOutcome(
      plain: """
      \(availability)
      Connect exactly one compatible AirPods or Beats device as a macOS output device,
      then run `airpods-control support-report` again.
      Nothing was sent to GitHub.
      """,
      terminalReason: reason
    )
  }

}
