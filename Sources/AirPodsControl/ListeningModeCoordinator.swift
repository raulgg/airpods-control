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

enum ListeningModeCommand {
  case get
  case list
  case set(ListeningMode)
  case cycle([ListeningMode]?)

  init?(_ command: CLICommand) {
    switch command {
    case .listeningModeGet:
      self = .get
    case .listeningModeList:
      self = .list
    case .listeningModeSet(let target):
      self = .set(target)
    case .listeningModeCycle(let requested):
      self = .cycle(requested)
    case .version, .status, .supportReport,
      .conversationAwarenessGet, .conversationAwarenessSet:
      return nil
    }
  }
}

struct ListeningModeCandidate {
  let displayName: String
  let selectableNames: [String]
  let avTransport: (any ListeningModeTransport)?
  let halTransport: (any ListeningModeTransport)?
  let route: ListeningModeCandidateRoute
  let avJoinEvidence: ActiveFeatureEndpointJoinEvidence

  init(
    displayName: String,
    selectableNames: [String],
    avTransport: (any ListeningModeTransport)?,
    halTransport: (any ListeningModeTransport)?,
    route: ListeningModeCandidateRoute,
    avJoinEvidence: ActiveFeatureEndpointJoinEvidence? = nil
  ) {
    self.displayName = displayName
    self.selectableNames = selectableNames
    self.avTransport = avTransport
    self.halTransport = halTransport
    self.route = route
    self.avJoinEvidence = avJoinEvidence
      ?? (avTransport == nil ? .unavailable : .matched)
  }
}

enum ListeningModeAmbiguousChoice {
  case selected(index: Int)
  case cancelled
  case unavailable
}

struct ListeningModeSession {
  let name: String?
  let transport: any ListeningModeTransport
  let availableModes: [ListeningMode]
  let currentMode: ListeningMode?
  let canSet: Bool
}

enum ListeningModeResolution {
  case session(ListeningModeSession)
  case noDevice
  case ambiguousDevice
  case cancelled
}

final class ListeningModeCoordinator {
  private let avCandidates: [ListeningModeCandidate]
  private let halCandidates: [ListeningModeCandidate]
  private let logger: DebugLogger

  init(
    avDevices: [PrivateAudioDevice],
    halCandidates: [ListeningModeCandidate],
    logger: DebugLogger
  ) {
    avCandidates = avDevices.compactMap { device in
      guard let name = device.name else { return nil }
      return ListeningModeCandidate(
        displayName: name,
        selectableNames: [name],
        avTransport: device,
        halTransport: nil,
        route: device.isActiveOperationalEndpoint ? .selected : .unknown
      )
    }
    self.halCandidates = halCandidates
    self.logger = logger
  }

  init(candidates: [ListeningModeCandidate], logger: DebugLogger) {
    avCandidates = candidates.filter { $0.halTransport == nil }
    halCandidates = candidates.filter { $0.halTransport != nil }
    self.logger = logger
  }

  func resolve(
    command: ListeningModeCommand,
    named requestedName: String?,
    chooseAmbiguous: ([String]) -> ListeningModeAmbiguousChoice
  ) -> ListeningModeResolution {
    let selectedCandidate: ListeningModeCandidate

    if halCandidates.isEmpty {
      guard !avCandidates.isEmpty else { return .noDevice }
      if let requestedName {
        let matches = matching(requestedName, in: avCandidates)
        guard matches.count == 1, let match = matches.first else {
          logger.warning(
            "device_selection",
            matches.isEmpty ? "no-exact-name-match" : "ambiguous-device-name"
          )
          return matches.isEmpty ? .noDevice : .ambiguousDevice
        }
        selectedCandidate = match
      } else {
        selectedCandidate = avCandidates[0]
      }
    } else if let requestedName {
      let halMatches = matching(requestedName, in: halCandidates)
        .map(attachUniqueActiveAV)
      let avMatches = matching(requestedName, in: avCandidates).filter { avCandidate in
        !halMatches.contains { halCandidate in
          representsJoinedAVTarget(avCandidate, in: halCandidate)
        }
      }
      let matchCount = halMatches.count + avMatches.count
      guard matchCount == 1 else {
        logger.warning(
          "device_selection",
          matchCount == 0 ? "no-exact-name-match" : "ambiguous-device-name"
        )
        return matchCount == 0 ? .noDevice : .ambiguousDevice
      }
      selectedCandidate = halMatches.first ?? avMatches[0]
    } else {
      let selectedHALCandidates = halCandidates.filter { $0.route == .selected }
      if selectedHALCandidates.count == 1, let selected = selectedHALCandidates.first {
        selectedCandidate = attachUniqueActiveAV(to: selected)
      } else if selectedHALCandidates.count > 1 {
        logger.warning("device_selection", "ambiguous-active-device")
        return .ambiguousDevice
      } else if halCandidates.count == 1 {
        selectedCandidate = halCandidates[0]
      } else {
        switch chooseAmbiguous(halCandidates.map(\.displayName)) {
        case .selected(let index) where halCandidates.indices.contains(index):
          selectedCandidate = halCandidates[index]
        case .selected, .unavailable:
          return .ambiguousDevice
        case .cancelled:
          return .cancelled
        }
      }
    }

    guard let session = selectTransport(for: selectedCandidate, command: command) else {
      return .noDevice
    }
    logger.info("listening_mode.transport", session.transport.listeningModeTransportKind.rawValue)
    return .session(session)
  }

  private func matching(
    _ requestedName: String,
    in candidates: [ListeningModeCandidate]
  ) -> [ListeningModeCandidate] {
    candidates.filter { candidate in
      candidate.selectableNames.contains {
        $0.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
      }
    }
  }

  private func attachUniqueActiveAV(
    to candidate: ListeningModeCandidate
  ) -> ListeningModeCandidate {
    guard candidate.route == .selected, candidate.avTransport == nil else {
      return candidate
    }
    guard candidate.avJoinEvidence == .unavailable else { return candidate }
    let activeAV = avCandidates.filter { $0.route == .selected }
    guard activeAV.count == 1, let avCandidate = activeAV.first,
          let avTransport = avCandidate.avTransport
    else {
      return candidate
    }
    let names = (candidate.selectableNames + avCandidate.selectableNames)
      .reduce(into: [String]()) { result, name in
        guard !result.contains(where: {
          $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        result.append(name)
      }
    return ListeningModeCandidate(
      displayName: candidate.displayName,
      selectableNames: names,
      avTransport: avTransport,
      halTransport: candidate.halTransport,
      route: candidate.route,
      avJoinEvidence: .matched
    )
  }

  private func representsJoinedAVTarget(
    _ avCandidate: ListeningModeCandidate,
    in halCandidate: ListeningModeCandidate
  ) -> Bool {
    guard halCandidate.avJoinEvidence == .matched,
          let avTransport = avCandidate.avTransport,
          let joinedTransport = halCandidate.avTransport
    else { return false }
    if avTransport === joinedTransport { return true }

    guard let avDevice = avTransport as? PrivateAudioDevice,
          let joinedDevice = joinedTransport as? PrivateAudioDevice
    else { return false }
    if avDevice.object === joinedDevice.object { return true }

    guard let avIdentifier = PrivateAudioDiscovery.deviceIdentifier(for: avDevice.object),
          let joinedIdentifier = PrivateAudioDiscovery.deviceIdentifier(
            for: joinedDevice.object
          )
    else { return false }
    return avIdentifier == joinedIdentifier
  }

  private func selectTransport(
    for candidate: ListeningModeCandidate,
    command: ListeningModeCommand
  ) -> ListeningModeSession? {
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

    var sessions: [ListeningModeSession] = []
    for transport in transports {
      let captured = session(for: transport, command: command)
      sessions.append(captured)
      if isReady(captured, for: command) {
        return captured
      }
    }

    // The preferred provider preserves the established unknown/unsupported
    // result when the logical device exists but preflight cannot proceed.
    return sessions.first
  }

  private func session(
    for transport: any ListeningModeTransport,
    command: ListeningModeCommand
  ) -> ListeningModeSession {
    let availableModes: [ListeningMode]
    let currentMode: ListeningMode?
    let canSet: Bool

    switch command {
    case .get:
      availableModes = []
      currentMode = transport.currentListeningMode()
      canSet = false
    case .list:
      currentMode = transport.currentListeningMode()
      availableModes = normalizedModes(from: transport)
      canSet = false
    case .set, .cycle:
      currentMode = transport.currentListeningMode()
      availableModes = normalizedModes(from: transport)
      canSet = transport.canSetListeningMode()
    }

    return ListeningModeSession(
      name: transport.name,
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
    _ session: ListeningModeSession,
    for command: ListeningModeCommand
  ) -> Bool {
    switch command {
    case .get:
      return session.currentMode != nil
    case .list:
      return !session.availableModes.isEmpty
    case .set(let target):
      let stateIsSafe =
        session.transport.listeningModeTransportKind == .av
        || session.currentMode != nil
      return stateIsSafe
        && session.availableModes.contains(target)
        && session.canSet
    case .cycle(let requested):
      let base = requested ?? ListeningMode.allCases.filter { $0 != .off }
      let supported = base.filter { session.availableModes.contains($0) }
      let stateIsSafe =
        session.transport.listeningModeTransportKind == .av
        || session.currentMode != nil
      return stateIsSafe && supported.count >= 2 && session.canSet
    }
  }
}
