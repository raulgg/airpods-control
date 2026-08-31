import Foundation

enum SupportReportDeviceFamily: String {
  case airPods = "AirPods"
  case beats = "Beats (exploratory)"
  case unknownApple = "Apple or Beats (unidentified, exploratory)"
}

struct SupportReportDeviceMetadata {
  let family: SupportReportDeviceFamily?
  let modelIdentifier: String?
  let unrecognizedListeningModes: [String]
  let listeningModeQueryAnswered: Bool
}

enum SupportReportListeningModeQuery {
  case recognized
  case unrecognized
  case unavailable
}

enum SupportReportCapabilitySupport {
  case supported
  case notSupported
  case unavailable
}

enum SupportReportQueryAvailability {
  case available
  case unavailable
}

struct SupportReportOtherListeningModes {
  let values: [String]
  let omittedCount: Int

  var isEmpty: Bool {
    values.isEmpty && omittedCount == 0
  }

  // Lists the retained names and accounts for the ones dropped by the cap.
  // Each renderer supplies its own quoting; the accounting is shared.
  func rendered(quoting quote: (String) -> String = { $0 }) -> String {
    var rendered = values.map(quote).joined(separator: ", ")
    if omittedCount > 0 {
      let suffix = "\(omittedCount) more"
      rendered += rendered.isEmpty ? suffix : ", and \(suffix)"
    }
    return rendered
  }
}

// Everything the report says about the device and host, captured as plain
// values in a single pass. Capturing before any consented write is what
// guarantees the rendered report reflects the pre-write state.
struct SupportReportSnapshot {
  static let maximumModelIdentifierLength = 80
  static let maximumUnrecognizedListeningModeLength = 80
  static let maximumUnrecognizedListeningModeCount = 6

  let family: SupportReportDeviceFamily?
  // nil when no catalog entry matches. Each renderer words the gap itself
  // rather than inheriting a phrase chosen here.
  let modelName: String?
  let modelIdentifier: String?
  let bluetoothProductID: String?
  let listeningModes: [ListeningMode]
  let otherListeningModes: SupportReportOtherListeningModes
  let listeningModeQuery: SupportReportListeningModeQuery
  let listeningModeSetterExposed: Bool
  let conversationAwarenessSupport: SupportReportCapabilitySupport
  let conversationAwarenessQuery: SupportReportQueryAvailability
  let conversationAwarenessSetterExposed: Bool
  let macOS: String

  static func capture(
    device: any CompatibleAudioDevice,
    operatingSystemVersion: OperatingSystemVersion =
      ProcessInfo.processInfo.operatingSystemVersion
  ) -> SupportReportSnapshot {
    let metadata = device.supportReportMetadata()
    let family = metadata.family
    let modelIdentifier = normalizedMetadataValue(
      metadata.modelIdentifier,
      maximumLength: maximumModelIdentifierLength
    )

    let availableModes = Set(device.availableListeningModes())
    let listeningModes = ListeningMode.allCases.filter { availableModes.contains($0) }

    let listeningModeQuery: SupportReportListeningModeQuery
    if device.currentListeningMode() != nil {
      listeningModeQuery = .recognized
    } else if metadata.listeningModeQueryAnswered {
      listeningModeQuery = .unrecognized
    } else {
      listeningModeQuery = .unavailable
    }

    let conversationAwarenessSupport: SupportReportCapabilitySupport
    switch device.supportsConversationAwareness() {
    case .some(true): conversationAwarenessSupport = .supported
    case .some(false): conversationAwarenessSupport = .notSupported
    case .none: conversationAwarenessSupport = .unavailable
    }
    let conversationAwarenessQuery = device.conversationAwarenessState() != nil
      ? SupportReportQueryAvailability.available
      : SupportReportQueryAvailability.unavailable

    let resolvedProduct = modelIdentifier.flatMap(AppleAudioProducts.product)
    let bluetoothProductID = resolvedProduct?.bluetoothProductID.map {
      AppleAudioProducts.hexProductID($0)
    }
    let otherListeningModes = normalizedUnrecognizedListeningModes(
      metadata.unrecognizedListeningModes
    )

    let macOS = [
      operatingSystemVersion.majorVersion,
      operatingSystemVersion.minorVersion,
      operatingSystemVersion.patchVersion,
    ].map(String.init).joined(separator: ".")

    return SupportReportSnapshot(
      family: family,
      modelName: resolvedProduct?.modelName,
      modelIdentifier: modelIdentifier,
      bluetoothProductID: bluetoothProductID,
      listeningModes: listeningModes,
      otherListeningModes: otherListeningModes,
      listeningModeQuery: listeningModeQuery,
      listeningModeSetterExposed: device.canSetListeningMode(),
      conversationAwarenessSupport: conversationAwarenessSupport,
      conversationAwarenessQuery: conversationAwarenessQuery,
      conversationAwarenessSetterExposed: device.canSetConversationAwareness(),
      macOS: macOS
    )
  }

  private static func normalizedUnrecognizedListeningModes(
    _ rawModes: [String]
  ) -> SupportReportOtherListeningModes {
    let normalized = rawModes.compactMap {
      normalizedMetadataValue(
        $0,
        maximumLength: maximumUnrecognizedListeningModeLength
      )
    }
    let listed = Array(normalized.prefix(maximumUnrecognizedListeningModeCount))
    return SupportReportOtherListeningModes(
      values: listed,
      omittedCount: normalized.count - listed.count
    )
  }

  static func normalizedMetadataValue(_ value: String?, maximumLength: Int) -> String? {
    guard let value else { return nil }
    let normalized = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let allowedCharacters = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,_()+-/"
    )
    guard !normalized.isEmpty,
          normalized.unicodeScalars.count <= maximumLength,
          normalized.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) })
    else {
      return nil
    }
    return normalized
  }
}
