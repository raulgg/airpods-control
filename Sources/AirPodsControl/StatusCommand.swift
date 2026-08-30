import Foundation

private enum StatusFieldKey: String {
  case listeningMode
  case conversationAwareness
  case isSelectedAudioOutput
  case isSelectedAudioInput
  case leftEarPlacement
  case rightEarPlacement

  var plainLabel: String {
    switch self {
    case .listeningMode: return "Listening mode"
    case .conversationAwareness: return "Conversation Awareness"
    case .isSelectedAudioOutput: return "Audio output selection"
    case .isSelectedAudioInput: return "Audio input selection"
    case .leftEarPlacement: return "Left ear placement"
    case .rightEarPlacement: return "Right ear placement"
    }
  }
}

private struct DeviceStatusSnapshot {
  let deviceName: String
  let listeningMode: DeviceStatusField<ListeningMode>
  let conversationAwareness: DeviceStatusField<Bool>
  let audioOutputSelection: AudioDeviceSelectionObservation
  let audioInputSelection: AudioDeviceSelectionObservation
  let inEarPlacement: DeviceStatusField<BluetoothEarPlacement>

  static func capture(_ device: any CompatibleAudioDevice) -> DeviceStatusSnapshot? {
    guard let deviceName = device.name else { return nil }
    return DeviceStatusSnapshot(
      deviceName: deviceName,
      listeningMode: device.readListeningModeStatus(),
      conversationAwareness: device.readConversationAwarenessStatus(),
      audioOutputSelection: device.readAudioOutputSelectionStatus(),
      audioInputSelection: device.readAudioInputSelectionStatus(),
      inEarPlacement: device.readInEarPlacementStatus()
    )
  }

  var hasNonErrorResult: Bool {
    !listeningMode.isReadError
      || !conversationAwareness.isReadError
      || !audioOutputSelection.isReadError
      || !audioInputSelection.isReadError
      || !inEarPlacement.isReadError
  }

  var readErrorFields: [StatusFieldKey] {
    var fields: [StatusFieldKey] = []
    if listeningMode.isReadError { fields.append(.listeningMode) }
    if conversationAwareness.isReadError { fields.append(.conversationAwareness) }
    if audioOutputSelection.isReadError { fields.append(.isSelectedAudioOutput) }
    if audioInputSelection.isReadError { fields.append(.isSelectedAudioInput) }
    if inEarPlacement.isReadError {
      fields.append(.leftEarPlacement)
      fields.append(.rightEarPlacement)
    }
    return fields
  }

  var plain: String {
    var lines = ["\(SafeTerminalText.escaped(deviceName)):"]

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
      lines.append("  Conversation Awareness: unknown")
    }

    lines.append(
      "  Selected as audio output: \(audioOutputSelection.plainValue)"
    )
    lines.append(
      "  Selected as audio input: \(audioInputSelection.plainValue)"
    )

    switch inEarPlacement {
    case let .value(placement):
      lines.append("  Left ear placement: \(placement.left.statusToken)")
      lines.append("  Right ear placement: \(placement.right.statusToken)")
    case .unsupported:
      break
    case .unresolved, .readError:
      lines.append("  Left ear placement: unknown")
      lines.append("  Right ear placement: unknown")
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

    payload[StatusFieldKey.isSelectedAudioOutput.rawValue] = audioOutputSelection.jsonValue
    payload[StatusFieldKey.isSelectedAudioInput.rawValue] = audioInputSelection.jsonValue

    switch inEarPlacement {
    case let .value(placement):
      payload[StatusFieldKey.leftEarPlacement.rawValue] = placement.left.statusToken
      payload[StatusFieldKey.rightEarPlacement.rawValue] = placement.right.statusToken
    case .unsupported:
      break
    case .unresolved, .readError:
      payload[StatusFieldKey.leftEarPlacement.rawValue] = NSNull()
      payload[StatusFieldKey.rightEarPlacement.rawValue] = NSNull()
    }

    let errors = readErrorFields
    if !errors.isEmpty {
      payload["errors"] = Dictionary(
        uniqueKeysWithValues: errors.map { ($0.rawValue, "read-error") }
      )
    }
    return payload
  }
}

private extension DeviceStatusField {
  var isReadError: Bool {
    if case .readError = self { return true }
    return false
  }
}

private extension AudioDeviceSelectionObservation {
  var isReadError: Bool {
    if case .readError = self { return true }
    return false
  }

  var plainValue: String {
    switch self {
    case .selected: return "yes"
    case .notSelected: return "no"
    case .unresolved, .readError: return "unknown"
    }
  }

  var jsonValue: Any {
    switch self {
    case .selected: return true
    case .notSelected: return false
    case .unresolved, .readError: return NSNull()
    }
  }
}

private extension BluetoothEarPlacementState {
  var statusToken: String {
    switch self {
    case .inEar: return "in-ear"
    case .outOfEar: return "out-of-ear"
    case .inCase: return "in-case"
    }
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
