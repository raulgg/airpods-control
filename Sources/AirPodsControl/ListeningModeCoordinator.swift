import CoreAudio
import Foundation

enum ListeningModeTransportKind: String {
  case av
  case hal
}

protocol ListeningModeTransport: AnyObject {
  var name: String? { get }
  var listeningModeTransportKind: ListeningModeTransportKind { get }

  func availableListeningModes() -> [ListeningMode]
  func currentListeningMode() -> ListeningMode?
  func canSetListeningMode() -> Bool
  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode>
  func settle(for interval: TimeInterval)
}

extension PrivateAudioDevice: ListeningModeTransport {
  var listeningModeTransportKind: ListeningModeTransportKind { .av }
}

private let halListeningModeByRawValue: [UInt32: ListeningMode] = [
  1: .off,
  2: .noiseCancellation,
  3: .transparency,
  4: .adaptive,
]
private let halWritableRawValueByListeningMode: [ListeningMode: UInt32] = [
  .noiseCancellation: 2,
  .transparency: 3,
  .adaptive: 4,
]
private let halListeningModeSupportMask: UInt32 = 0b111
private let halReadbackAttempts = 16
private let halReadbackInterval: TimeInterval = 0.05

final class HALListeningModeTransport: ListeningModeTransport {
  let name: String?
  let audioDeviceID: AudioDeviceID
  let bluetoothDevice: AnyObject
  var listeningModeTransportKind: ListeningModeTransportKind { .hal }

  private let backend: any AudioRoutingBackend
  private let logger: DebugLogger

  init(
    name: String,
    audioDeviceID: AudioDeviceID,
    bluetoothDevice: AnyObject,
    backend: any AudioRoutingBackend,
    logger: DebugLogger
  ) {
    self.name = name
    self.audioDeviceID = audioDeviceID
    self.bluetoothDevice = bluetoothDevice
    self.backend = backend
    self.logger = logger
  }

  func availableListeningModes() -> [ListeningMode] {
    guard
      case .value(let rawMask) = backend.readBluetoothListeningModeSupport(
        for: audioDeviceID
      )
    else { return [] }

    let recognizedMask = rawMask & halListeningModeSupportMask
    let unknownMask = rawMask & ~halListeningModeSupportMask
    logger.debug("hal.listening_mode_support_mask", recognizedMask)
    if unknownMask != 0 {
      logger.debug("hal.listening_mode_support_unknown_mask", unknownMask)
    }

    var modes: Set<ListeningMode> = []
    if recognizedMask & 0b001 != 0 { modes.insert(.noiseCancellation) }
    if recognizedMask & 0b010 != 0 { modes.insert(.transparency) }
    if recognizedMask & 0b100 != 0 { modes.insert(.adaptive) }
    return ListeningMode.allCases.filter { modes.contains($0) }
  }

  func currentListeningMode() -> ListeningMode? {
    switch backend.readBluetoothListeningMode(for: audioDeviceID) {
    case .value(let rawValue):
      logger.debug("hal.listening_mode_raw", rawValue)
      return halListeningModeByRawValue[rawValue]
    case .unavailable:
      logger.debug("hal.listening_mode", "unavailable")
      return nil
    case .failure(let status):
      logger.debug("hal.listening_mode", "read-error")
      logger.debug("hal.listening_mode_error", status)
      return nil
    }
  }

  func canSetListeningMode() -> Bool {
    switch backend.isBluetoothListeningModeSettable(for: audioDeviceID) {
    case .value(let settable):
      logger.debug("hal.listening_mode_settable", settable)
      return settable
    case .unavailable:
      logger.debug("hal.listening_mode_settable", "unavailable")
      return false
    case .failure(let status):
      logger.debug("hal.listening_mode_settable", "read-error")
      logger.debug("hal.listening_mode_settable_error", status)
      return false
    }
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    guard let rawTarget = halWritableRawValueByListeningMode[target],
      availableListeningModes().contains(target)
    else {
      return DeviceWriteObservation(
        setterAccepted: false,
        observed: currentListeningMode()
      )
    }

    let setterAccepted: Bool
    switch backend.writeBluetoothListeningMode(rawTarget, for: audioDeviceID) {
    case .success:
      setterAccepted = true
      logger.debug("hal.write.listening_mode", "accepted")
    case .unavailable:
      setterAccepted = false
      logger.debug("hal.write.listening_mode", "unavailable")
    case .notSettable:
      setterAccepted = false
      logger.debug("hal.write.listening_mode", "not-settable")
    case .failure(let status):
      setterAccepted = false
      logger.debug("hal.write.listening_mode", "error")
      logger.debug("hal.write.listening_mode_error", status)
    }

    // HAL updates its local lstm cache before dispatch. Always allow one
    // settling interval before the first readback so a prompt system
    // reconciliation can replace that optimistic value.
    settle(for: halReadbackInterval)
    var observed = currentListeningMode()
    logger.debug("hal.verify.listening_mode.attempt", 1)
    if observed != target {
      for attempt in 2...halReadbackAttempts {
        settle(for: halReadbackInterval)
        observed = currentListeningMode()
        logger.debug("hal.verify.listening_mode.attempt", attempt)
        if observed == target { break }
      }
    }
    return DeviceWriteObservation(
      setterAccepted: setterAccepted,
      observed: observed
    )
  }

  func settle(for interval: TimeInterval) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
  }
}

enum ListeningModeCandidateRoute: Equatable {
  case selected
  case notSelected
  case unknown
}

struct ListeningModeCandidate {
  let displayName: String
  let selectableNames: [String]
  let avTransport: (any ListeningModeTransport)?
  let halTransport: (any ListeningModeTransport)?
  let route: ListeningModeCandidateRoute
  let avIdentifiesActiveOutput: Bool

  init(
    displayName: String,
    selectableNames: [String],
    avTransport: (any ListeningModeTransport)?,
    halTransport: (any ListeningModeTransport)?,
    route: ListeningModeCandidateRoute,
    avIdentifiesActiveOutput: Bool = false
  ) {
    self.displayName = displayName
    self.selectableNames = selectableNames
    self.avTransport = avTransport
    self.halTransport = halTransport
    self.route = route
    self.avIdentifiesActiveOutput = avIdentifiesActiveOutput
  }
}

enum ListeningModeAmbiguousChoice {
  case selected(index: Int)
  case cancelled
  case unavailable
}

private struct ListeningModeTransportSnapshot {
  let transport: any ListeningModeTransport
  let availableModes: [ListeningMode]
  let currentMode: ListeningMode?
  let canSet: Bool
}

final class ListeningModeCommandDevice: CompatibleAudioDevice {
  let name: String?
  private let snapshot: ListeningModeTransportSnapshot

  fileprivate init(snapshot: ListeningModeTransportSnapshot) {
    self.snapshot = snapshot
    name = snapshot.transport.name
  }

  func supportReportMetadata() -> SupportReportDeviceMetadata {
    SupportReportDeviceMetadata(
      family: nil,
      modelIdentifier: nil,
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: snapshot.currentMode != nil
    )
  }

  func availableListeningModes() -> [ListeningMode] {
    snapshot.availableModes
  }

  func currentListeningMode() -> ListeningMode? {
    snapshot.currentMode
  }

  func readListeningModeStatus() -> DeviceStatusField<ListeningMode> {
    snapshot.currentMode.map(DeviceStatusField.value) ?? .unresolved
  }

  func canSetListeningMode() -> Bool {
    snapshot.canSet
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    snapshot.transport.setListeningModeAndReadBack(target)
  }

  func supportsConversationAwareness() -> Bool? { nil }
  func conversationAwarenessState() -> Bool? { nil }
  func readConversationAwarenessStatus() -> DeviceStatusField<Bool> { .unresolved }
  func canSetConversationAwareness() -> Bool { false }

  func setConversationAwarenessAndReadBack(
    _ target: Bool
  ) -> DeviceWriteObservation<Bool> {
    DeviceWriteObservation(setterAccepted: false, observed: nil)
  }

  func readAudioOutputSelectionStatus() -> AudioDeviceSelectionObservation {
    .unresolved
  }

  func readAudioInputSelectionStatus() -> AudioDeviceSelectionObservation {
    .unresolved
  }

  func settle(for interval: TimeInterval) {
    snapshot.transport.settle(for: interval)
  }
}

final class ListeningModeCoordinator {
  private let candidates: [ListeningModeCandidate]
  private let logger: DebugLogger

  init(candidates: [ListeningModeCandidate], logger: DebugLogger) {
    self.candidates = candidates
    self.logger = logger
  }

  static func candidates(
    avDevices: [PrivateAudioDevice],
    halCandidates: [ListeningModeCandidate]
  ) -> [ListeningModeCandidate] {
    let joinedAVObjects = halCandidates.compactMap {
      ($0.avTransport as? PrivateAudioDevice)?.object
    }
    let joinedAVIdentifiers = Set(
      joinedAVObjects.compactMap {
        PrivateAudioDiscovery.deviceIdentifier(for: $0)
      })
    let standaloneAVCandidates = avDevices.compactMap {
      device -> ListeningModeCandidate? in
      let identifier = PrivateAudioDiscovery.deviceIdentifier(for: device.object)
      guard !joinedAVObjects.contains(where: { $0 === device.object }),
        identifier.map({ !joinedAVIdentifiers.contains($0) }) ?? true,
        let name = device.name
      else { return nil }
      return ListeningModeCandidate(
        displayName: name,
        selectableNames: [name],
        avTransport: device,
        halTransport: nil,
        route: .unknown,
        avIdentifiesActiveOutput: device.isActiveOperationalEndpoint
      )
    }
    return halCandidates + standaloneAVCandidates
  }

  func resolve(
    command: CLICommand,
    named requestedName: String?,
    chooseAmbiguous: ([String]) -> ListeningModeAmbiguousChoice
  ) -> CompatibleDeviceResolution {
    let selectedCandidate: ListeningModeCandidate

    if let requestedName {
      let matches = candidates.filter { candidate in
        candidate.selectableNames.contains {
          $0.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
        }
      }
      guard matches.count == 1, let match = matches.first else {
        logger.warning(
          "device_selection",
          matches.isEmpty ? "no-exact-name-match" : "ambiguous-device-name"
        )
        return matches.isEmpty ? .noDevice : .ambiguousDevice
      }
      selectedCandidate = match
    } else {
      guard !candidates.isEmpty else { return .noDevice }

      let activeCandidates = candidates.filter {
        $0.route == .selected || $0.avIdentifiesActiveOutput
      }
      if activeCandidates.count == 1, let active = activeCandidates.first {
        selectedCandidate = active
      } else if activeCandidates.count > 1 {
        logger.warning("device_selection", "ambiguous-active-device")
        return .ambiguousDevice
      } else if candidates.count == 1 {
        selectedCandidate = candidates[0]
      } else if candidates.allSatisfy({ $0.halTransport == nil }) {
        // When HAL is absent, retain the established AV-only first-device
        // behavior on older systems.
        selectedCandidate = candidates[0]
      } else if candidates.allSatisfy({ $0.halTransport != nil }) {
        switch chooseAmbiguous(candidates.map(\.displayName)) {
        case .selected(let index) where candidates.indices.contains(index):
          selectedCandidate = candidates[index]
        case .selected, .unavailable:
          return .ambiguousDevice
        case .cancelled:
          return .cancelled
        }
      } else {
        logger.warning("device_selection", "ambiguous-device-inventory")
        return .ambiguousDevice
      }
    }

    guard let snapshot = selectTransport(for: selectedCandidate, command: command) else {
      return .noDevice
    }
    logger.info("listening_mode.transport", snapshot.transport.listeningModeTransportKind.rawValue)
    return .devices([ListeningModeCommandDevice(snapshot: snapshot)])
  }

  private func selectTransport(
    for candidate: ListeningModeCandidate,
    command: CLICommand
  ) -> ListeningModeTransportSnapshot? {
    let transports: [any ListeningModeTransport]
    switch candidate.route {
    case .selected:
      transports = [candidate.avTransport, candidate.halTransport].compactMap { $0 }
    case .notSelected:
      transports = [candidate.halTransport].compactMap { $0 }
    case .unknown:
      transports = [candidate.avTransport, candidate.halTransport].compactMap { $0 }
    }
    guard !transports.isEmpty else { return nil }

    var snapshots: [ListeningModeTransportSnapshot] = []
    for transport in transports {
      let captured = snapshot(for: transport, command: command)
      snapshots.append(captured)
      if isReady(captured, for: command) {
        return captured
      }
    }

    // Keeping the preferred provider lets CommandExecution preserve its
    // established unknown/unsupported result when the logical device exists
    // but the command-specific preflight cannot proceed.
    guard let preferred = snapshots.first else { return nil }
    switch command {
    case .listeningModeSet, .listeningModeCycle:
      return ListeningModeTransportSnapshot(
        transport: preferred.transport,
        availableModes: preferred.availableModes,
        currentMode: preferred.currentMode,
        canSet: false
      )
    case .version, .status, .supportReport,
      .listeningModeGet, .listeningModeList,
      .conversationAwarenessGet, .conversationAwarenessSet:
      return preferred
    }
  }

  private func snapshot(
    for transport: any ListeningModeTransport,
    command: CLICommand
  ) -> ListeningModeTransportSnapshot {
    let availableModes: [ListeningMode]
    let currentMode: ListeningMode?
    let canSet: Bool

    switch command {
    case .listeningModeGet:
      availableModes = []
      currentMode = transport.currentListeningMode()
      canSet = false
    case .listeningModeList:
      currentMode = transport.currentListeningMode()
      availableModes = normalizedModes(from: transport)
      canSet = false
    case .listeningModeSet, .listeningModeCycle:
      currentMode = transport.currentListeningMode()
      availableModes = normalizedModes(from: transport)
      canSet = transport.canSetListeningMode()
    case .version, .status, .supportReport,
      .conversationAwarenessGet, .conversationAwarenessSet:
      availableModes = []
      currentMode = nil
      canSet = false
    }

    return ListeningModeTransportSnapshot(
      transport: transport,
      availableModes: availableModes,
      currentMode: currentMode,
      canSet: canSet
    )
  }

  private func normalizedModes(
    from transport: any ListeningModeTransport
  ) -> [ListeningMode] {
    let advertised = Set(transport.availableListeningModes())
    return ListeningMode.allCases.filter { advertised.contains($0) }
  }

  private func isReady(
    _ snapshot: ListeningModeTransportSnapshot,
    for command: CLICommand
  ) -> Bool {
    switch command {
    case .listeningModeGet:
      return snapshot.currentMode != nil
    case .listeningModeList:
      return !snapshot.availableModes.isEmpty
    case .listeningModeSet(let target):
      let stateIsSafe =
        snapshot.transport.listeningModeTransportKind == .av
        || snapshot.currentMode != nil
      return stateIsSafe
        && snapshot.availableModes.contains(target)
        && snapshot.canSet
    case .listeningModeCycle(let requested):
      let base = requested ?? ListeningMode.allCases.filter { $0 != .off }
      let supported = base.filter { snapshot.availableModes.contains($0) }
      let stateIsSafe =
        snapshot.transport.listeningModeTransportKind == .av
        || snapshot.currentMode != nil
      return stateIsSafe && supported.count >= 2 && snapshot.canSet
    case .version, .status, .supportReport,
      .conversationAwarenessGet, .conversationAwarenessSet:
      return false
    }
  }
}
