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

// Everything the report says about the device and host, captured as plain
// values in a single pass. Capturing before any consented write is what
// guarantees the rendered report reflects the pre-write state.
struct SupportReportSnapshot {
  static let maximumModelIdentifierLength = 80
  static let maximumUnrecognizedListeningModeLength = 80
  static let maximumUnrecognizedListeningModeCount = 6

  let family: SupportReportDeviceFamily
  let model: String
  let modelIdentifier: String
  let listeningModes: String
  let otherModes: String
  let listeningModeQuery: String
  let listeningModeSetterExposed: Bool
  let conversationAwarenessSupport: String
  let conversationAwarenessQuery: String
  let conversationAwarenessSetterExposed: Bool
  let macOS: String
  let titleSubject: String

  static func capture(
    device: any CompatibleAudioDevice,
    operatingSystemVersion: OperatingSystemVersion =
      ProcessInfo.processInfo.operatingSystemVersion
  ) -> SupportReportSnapshot? {
    let metadata = device.supportReportMetadata()
    guard let family = metadata.family,
          let modelIdentifier = normalizedMetadataValue(
            metadata.modelIdentifier,
            maximumLength: maximumModelIdentifierLength
          )
    else {
      return nil
    }

    let availableModes = Set(device.availableListeningModes())
    let listeningModes = ListeningMode.allCases.filter { availableModes.contains($0) }
    let listeningModesValue = listeningModes.isEmpty
      ? "unavailable/not reported"
      : listeningModes.map(\.rawValue).joined(separator: ", ")

    let listeningModeQuery: String
    if device.currentListeningMode() != nil {
      listeningModeQuery = "answers with a recognized mode"
    } else if metadata.listeningModeQueryAnswered {
      listeningModeQuery = "answers with an unrecognized mode"
    } else {
      listeningModeQuery = "unavailable/not reported"
    }

    let conversationAwarenessSupport: String
    switch device.supportsConversationAwareness() {
    case .some(true): conversationAwarenessSupport = "supported"
    case .some(false): conversationAwarenessSupport = "not supported"
    case .none: conversationAwarenessSupport = "unavailable/not reported"
    }
    let conversationAwarenessQuery = device.conversationAwarenessState() != nil
      ? "answers"
      : "unavailable/not reported"

    let resolvedProduct = AppleAudioProducts.product(for: metadata.modelIdentifier)
    let model = resolvedProduct?.modelName ?? "not recognized by this CLI version"
    let modelIdentifierValue: String
    if let productID = resolvedProduct?.bluetoothProductID {
      modelIdentifierValue =
        "`\(modelIdentifier)` (Bluetooth product ID "
        + "\(AppleAudioProducts.hexProductID(productID)))"
    } else {
      modelIdentifierValue = "`\(modelIdentifier)`"
    }
    let otherModes = unrecognizedListeningModesValue(metadata.unrecognizedListeningModes)

    let macOS = [
      operatingSystemVersion.majorVersion,
      operatingSystemVersion.minorVersion,
      operatingSystemVersion.patchVersion,
    ].map(String.init).joined(separator: ".")

    return SupportReportSnapshot(
      family: family,
      model: model,
      modelIdentifier: modelIdentifierValue,
      listeningModes: listeningModesValue,
      otherModes: otherModes,
      listeningModeQuery: listeningModeQuery,
      listeningModeSetterExposed: device.canSetListeningMode(),
      conversationAwarenessSupport: conversationAwarenessSupport,
      conversationAwarenessQuery: conversationAwarenessQuery,
      conversationAwarenessSetterExposed: device.canSetConversationAwareness(),
      macOS: macOS,
      titleSubject: resolvedProduct?.modelName ?? family.rawValue
    )
  }

  private static func unrecognizedListeningModesValue(_ rawModes: [String]) -> String {
    let normalized = rawModes.compactMap {
      normalizedMetadataValue(
        $0,
        maximumLength: maximumUnrecognizedListeningModeLength
      )
    }
    guard !normalized.isEmpty else { return "none" }
    let listed = normalized.prefix(maximumUnrecognizedListeningModeCount)
    let overflow = normalized.count - listed.count
    let suffix = overflow > 0 ? ", and \(overflow) more" : ""
    return listed.map { "`\($0)`" }.joined(separator: ", ") + suffix
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
