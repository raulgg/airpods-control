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

struct StatusHALRecord {
  let device: any CompatibleAudioDevice
  let target: BluetoothCorrelationTarget?
}

struct StatusSession {
  let hal: [StatusHALRecord]
  let document: BluetoothSettingsDocument?
  let observations: [BluetoothPeripheralObservation]
  let bluetoothUsable: Bool

  init(
    hal: [StatusHALRecord],
    document: BluetoothSettingsDocument? = nil,
    observations: [BluetoothPeripheralObservation] = [],
    bluetoothUsable: Bool = false
  ) {
    self.hal = hal
    self.document = document
    self.observations = observations
    self.bluetoothUsable = bluetoothUsable
  }

  init(devices: [any CompatibleAudioDevice]) {
    self.init(hal: devices.map { StatusHALRecord(device: $0, target: nil) })
  }
}

enum StatusSessionResolution {
  case session(StatusSession)
  case failed(TerminalReason)
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

  static func bleOnly(
    name: String,
    placement: BluetoothEarPlacement
  ) -> DeviceStatusSnapshot {
    DeviceStatusSnapshot(
      deviceName: name,
      listeningMode: .unresolved,
      conversationAwareness: .unresolved,
      audioOutputSelection: .unresolved,
      audioInputSelection: .unresolved,
      inEarPlacement: .value(placement)
    )
  }

  func overlayingPlacement(
    _ placement: DeviceStatusField<BluetoothEarPlacement>
  ) -> DeviceStatusSnapshot {
    DeviceStatusSnapshot(
      deviceName: deviceName,
      listeningMode: listeningMode,
      conversationAwareness: conversationAwareness,
      audioOutputSelection: audioOutputSelection,
      audioInputSelection: audioInputSelection,
      inEarPlacement: placement
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
    outcome(
      session: StatusSession(devices: devices),
      named: nil,
      logger: DebugLogger(enabled: false)
    )
  }

  static func outcome(
    session: StatusSession,
    named requestedName: String?,
    policy: DeviceSelectionPolicy = .allOrExact,
    logger: DebugLogger
  ) -> CommandOutcome {
    let snapshots = records(from: session)
    guard session.hal.allSatisfy({ $0.device.name != nil }) else {
      return noDeviceOutcome()
    }

    switch DeviceNameSelection.select(
      snapshots,
      named: requestedName,
      name: { $0.deviceName },
      policy: policy,
      logger: logger
    ) {
    case let .selected(selected):
      let hasNonErrorResult = selected.contains(where: \.hasNonErrorResult)
      return CommandOutcome(
        plain: selected.map(\.plain).joined(separator: "\n\n"),
        terminalReason: hasNonErrorResult ? .success : .readError,
        data: ["devices": selected.map(\.payload)]
      )
    case .noDevice:
      return noDeviceOutcome()
    case .ambiguousDevice:
      return resolutionFailureOutcome(.ambiguousDevice)
    }
  }

  private static func records(from session: StatusSession) -> [DeviceStatusSnapshot] {
    var matchedAssociationIDs = Set<UUID>()
    let overlayEnabled = session.bluetoothUsable
      && session.document?.enabled == true
    let document = session.document
    let halSnapshots: [DeviceStatusSnapshot] = session.hal.compactMap { record in
      guard let snapshot = DeviceStatusSnapshot.capture(record.device) else {
        return nil
      }
      guard overlayEnabled, let document else { return snapshot }
      let association = record.target.flatMap { document.association(matching: $0) }
      if let association {
        matchedAssociationIDs.insert(association.associationID)
      }
      return snapshot.overlayingPlacement(
        BluetoothPlacement.resolved(
          hal: snapshot.inEarPlacement,
          ble: observation(for: association, in: session.observations),
          enrolled: association != nil
        )
      )
    }
    guard overlayEnabled, let document else { return halSnapshots }
    let bleOnly = document.associations.compactMap { association -> DeviceStatusSnapshot? in
      guard !matchedAssociationIDs.contains(association.associationID),
            let placement = observation(
              for: association,
              in: session.observations
            )
      else {
        return nil
      }
      return .bleOnly(name: association.displayName, placement: placement)
    }
    return halSnapshots + bleOnly
  }

  private static func observation(
    for association: BluetoothAssociation?,
    in observations: [BluetoothPeripheralObservation]
  ) -> BluetoothEarPlacement? {
    guard let association else { return nil }
    return observations.first {
      $0.peripheralIdentifier == association.peripheralIdentifier
        && $0.productID == association.productID
    }?.placement
  }

  static func noDeviceOutcome() -> CommandOutcome {
    resolutionFailureOutcome(.noDevice)
  }

  static func resolutionFailureOutcome(_ reason: TerminalReason) -> CommandOutcome {
    let plain: String
    switch reason {
    case .noDevice:
      plain = noDevicePlain
    case .ambiguousDevice:
      plain = "Multiple compatible devices match the requested status target."
    case .unavailable:
      plain = "Compatible device discovery is unavailable."
    case .readError:
      plain = "Compatible device discovery failed."
    default:
      preconditionFailure("status device resolution cannot end as \(reason.token)")
    }
    return CommandOutcome(
      plain: plain,
      terminalReason: reason,
      data: [
        "devices": [[String: Any]](),
      ]
    )
  }
}
