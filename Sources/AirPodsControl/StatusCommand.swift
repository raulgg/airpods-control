import Foundation

private enum StatusFieldKey: String {
  case listeningMode
  case conversationAwareness

  var plainLabel: String {
    switch self {
    case .listeningMode: return "Listening mode"
    case .conversationAwareness: return "Conversation Awareness"
    }
  }
}

private struct DeviceStatusSnapshot {
  let deviceName: String
  let listeningMode: DeviceStatusField<ListeningMode>
  let conversationAwareness: DeviceStatusField<Bool>

  static func capture(_ device: any CompatibleAudioDevice) -> DeviceStatusSnapshot? {
    guard let deviceName = device.name else { return nil }
    return DeviceStatusSnapshot(
      deviceName: deviceName,
      listeningMode: device.readListeningModeStatus(),
      conversationAwareness: device.readConversationAwarenessStatus()
    )
  }

  var hasNonErrorResult: Bool {
    !listeningMode.isReadError || !conversationAwareness.isReadError
  }

  var readErrorFields: [StatusFieldKey] {
    var fields: [StatusFieldKey] = []
    if listeningMode.isReadError { fields.append(.listeningMode) }
    if conversationAwareness.isReadError { fields.append(.conversationAwareness) }
    return fields
  }

  var plain: String {
    var lines = ["\(Self.escapedHeading(deviceName)):"]

    switch listeningMode {
    case let .value(mode):
      lines.append("  Listening mode: \(mode.rawValue)")
    case .unsupported:
      break
    case .unresolved, .readError:
      lines.append("  Listening mode: unknown")
    }

    switch conversationAwareness {
    case let .value(enabled):
      lines.append("  Conversation Awareness: \(enabled ? "on" : "off")")
    case .unsupported:
      break
    case .unresolved, .readError:
      lines.append("  Conversation Awareness: unsupported")
    }

    let errors = readErrorFields
    if !errors.isEmpty {
      lines.append("  Read errors: \(errors.map(\.plainLabel).joined(separator: ", "))")
    }
    return lines.joined(separator: "\n")
  }

  var payload: [String: Any] {
    var payload: [String: Any] = ["device": deviceName]

    switch listeningMode {
    case let .value(mode):
      payload[StatusFieldKey.listeningMode.rawValue] = mode.rawValue
    case .unsupported:
      break
    case .unresolved, .readError:
      payload[StatusFieldKey.listeningMode.rawValue] = NSNull()
    }

    switch conversationAwareness {
    case let .value(enabled):
      payload[StatusFieldKey.conversationAwareness.rawValue] = enabled ? "on" : "off"
    case .unsupported:
      break
    case .unresolved, .readError:
      payload[StatusFieldKey.conversationAwareness.rawValue] = NSNull()
    }

    let errors = readErrorFields
    if !errors.isEmpty {
      payload["errors"] = Dictionary(
        uniqueKeysWithValues: errors.map { ($0.rawValue, "read-error") }
      )
    }
    return payload
  }

  private static func escapedHeading(_ value: String) -> String {
    value.unicodeScalars.map { scalar in
      switch scalar.value {
      case 0x5C: return "\\\\"
      case 0x0A: return "\\n"
      case 0x0D: return "\\r"
      case 0x09: return "\\t"
      // These Unicode separators also create visual record boundaries even
      // though they are not in the Control general category.
      case 0x2028, 0x2029: return unicodeEscape(scalar.value)
      default:
        if scalar.properties.generalCategory == .control {
          return unicodeEscape(scalar.value)
        }
        return String(scalar)
      }
    }.joined()
  }

  private static func unicodeEscape(_ value: UInt32) -> String {
    let raw = String(value, radix: 16, uppercase: true)
    let padded = String(repeating: "0", count: max(0, 4 - raw.count)) + raw
    return "\\u{\(padded)}"
  }
}

private extension DeviceStatusField {
  var isReadError: Bool {
    if case .readError = self { return true }
    return false
  }
}

enum StatusCommand {
  static let noDevicePlain = "No compatible AirPods or Beats device is connected."

  static func outcome(devices: [any CompatibleAudioDevice]) -> CommandOutcome {
    let snapshots = devices.compactMap(DeviceStatusSnapshot.capture)
    guard !snapshots.isEmpty, snapshots.count == devices.count else {
      return noDeviceOutcome()
    }

    let hasNonErrorResult = snapshots.contains(where: \.hasNonErrorResult)
    var payload: [String: Any] = [
      "devices": snapshots.map(\.payload),
      "result": hasNonErrorResult ? "ok" : "error",
    ]
    if !hasNonErrorResult {
      payload["error"] = "read-error"
    }

    return CommandOutcome(
      plain: snapshots.map(\.plain).joined(separator: "\n\n"),
      exitCode: hasNonErrorResult ? 0 : 5,
      payload: payload
    )
  }

  static func noDeviceOutcome() -> CommandOutcome {
    CommandOutcome(
      plain: noDevicePlain,
      exitCode: 1,
      payload: [
        "devices": [[String: Any]](),
        "error": "no-device",
        "result": "error",
      ]
    )
  }
}
