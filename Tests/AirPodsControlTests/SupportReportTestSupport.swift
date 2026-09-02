import Foundation

@testable import AirPodsControlCore

extension SupportReportDeviceMetadata {
  // Defaults to AirPods Pro 3 (`BTHeadphones76,8231`, Bluetooth product ID
  // 0x2027), the verified baseline device. Tests pass only the fields they
  // actually vary.
  static func fixture(
    family: SupportReportDeviceFamily? = .airPods,
    modelIdentifier: String? = "BTHeadphones76,8231",
    unrecognizedListeningModes: [String] = [],
    listeningModeQueryAnswered: Bool = true
  ) -> SupportReportDeviceMetadata {
    SupportReportDeviceMetadata(
      family: family,
      modelIdentifier: modelIdentifier,
      unrecognizedListeningModes: unrecognizedListeningModes,
      listeningModeQueryAnswered: listeningModeQueryAnswered
    )
  }
}

// Builds a read-only document for tests. Tests with writes should capture the
// snapshot first, run the writes, and then build the document.
func passiveSupportReport(
  device: any CompatibleAudioDevice,
  operatingSystemVersion: OperatingSystemVersion =
    ProcessInfo.processInfo.operatingSystemVersion
) -> SupportReportDocument? {
  .some(
    SupportReportDocument.make(
      snapshot: SupportReportSnapshot.capture(
        device: device,
        operatingSystemVersion: operatingSystemVersion
      )
    )
  )
}

extension SupportReportDocument {
  var terminalOutput: String {
    SupportReportTerminalRenderer.render(self)
  }

  var githubIssueDraft: SupportReportIssueDraft {
    SupportReportGitHubRenderer.render(self)
  }
}

extension CommandOutcome {
  var supportReportOutput: String {
    supportReport?.terminalOutput ?? plain
  }

  var supportReportIssueDraft: SupportReportIssueDraft? {
    guard let supportReport, supportReport.interruptedBySignal == nil else {
      return nil
    }
    return supportReport.githubIssueDraft
  }
}

extension CapabilityWriteTestOutcome {
  var testRun: Run? {
    if case let .ran(run) = self { return run }
    return nil
  }

  var skipReason: String? {
    if case let .skipped(reason) = self { return reason }
    return nil
  }
}

extension RestorationOutcome {
  var attempted: Attempt? {
    if case let .attempted(attempt) = self { return attempt }
    return nil
  }

  var stateNeverChanged: Bool {
    if case .stateNeverChanged = self { return true }
    return false
  }
}
