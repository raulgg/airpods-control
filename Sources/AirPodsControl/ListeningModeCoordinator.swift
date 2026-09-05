import CoreAudio
import Foundation

enum ListeningModeTransportKind: String {
  case av
  case hal
}

enum ListeningModeAvailabilityObservation {
  case value([ListeningMode])
  case partial([ListeningMode])
  case unavailable
  case readError
}

enum ListeningModeStateObservation {
  case value(ListeningMode)
  case unknown
  case unavailable
  case readError
}

extension ListeningModeStateObservation {
  var value: ListeningMode? {
    guard case let .value(mode) = self else { return nil }
    return mode
  }
}

protocol ListeningModeTransport: AnyObject {
  var name: String? { get }
  var listeningModeTransportKind: ListeningModeTransportKind { get }

  func availableListeningModes() -> [ListeningMode]
  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation
  func currentListeningMode() -> ListeningMode?
  func listeningModeStateObservation() -> ListeningModeStateObservation
  func canSetListeningMode() -> Bool
  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode>
  func settle(for interval: TimeInterval)
}

extension ListeningModeTransport {
  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation {
    .value(availableListeningModes())
  }

  func listeningModeStateObservation() -> ListeningModeStateObservation {
    currentListeningMode().map(ListeningModeStateObservation.value) ?? .unknown
  }

}

protocol ListeningModeAllowOffTransport: ListeningModeTransport {
  func setListeningModeAndReadBackAllowingOff(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode>
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
  .off: 1,
  .noiseCancellation: 2,
  .transparency: 3,
  .adaptive: 4,
]
private let halListeningModeSupportMask: UInt32 = 0b111
private let halReadbackAttempts = 16
private let halReadbackInterval: TimeInterval = 0.05

final class HALListeningModeTransport: ListeningModeAllowOffTransport {
  let name: String?
  let audioDeviceID: AudioDeviceID
  let bluetoothDevice: AnyObject
  var listeningModeTransportKind: ListeningModeTransportKind { .hal }

  private let backend: any AudioRoutingBackend
  private let logger: DebugLogger
  private let wait: (TimeInterval) -> Void

  init(
    name: String,
    audioDeviceID: AudioDeviceID,
    bluetoothDevice: AnyObject,
    backend: any AudioRoutingBackend,
    logger: DebugLogger,
    wait: @escaping (TimeInterval) -> Void = { interval in
      RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
    }
  ) {
    self.name = name
    self.audioDeviceID = audioDeviceID
    self.bluetoothDevice = bluetoothDevice
    self.backend = backend
    self.logger = logger
    self.wait = wait
  }

  func availableListeningModes() -> [ListeningMode] {
    switch listeningModeAvailabilityObservation() {
    case let .value(modes), let .partial(modes): return modes
    case .unavailable, .readError: return []
    }
  }

  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation {
    let rawMask: UInt32
    switch backend.readBluetoothListeningModeSupport(for: audioDeviceID) {
    case let .value(value): rawMask = value
    case .unavailable: return .unavailable
    case .failure: return .readError
    }

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
    let recognized = ListeningMode.allCases.filter { modes.contains($0) }
    return unknownMask == 0 ? .value(recognized) : .partial(recognized)
  }

  func currentListeningMode() -> ListeningMode? {
    guard case let .value(mode) = listeningModeStateObservation() else { return nil }
    return mode
  }

  func listeningModeStateObservation() -> ListeningModeStateObservation {
    switch backend.readBluetoothListeningMode(for: audioDeviceID) {
    case .value(let rawValue):
      logger.debug("hal.listening_mode_raw", rawValue)
      return halListeningModeByRawValue[rawValue]
        .map(ListeningModeStateObservation.value) ?? .unknown
    case .unavailable:
      logger.debug("hal.listening_mode", "unavailable")
      return .unavailable
    case .failure(let status):
      logger.debug("hal.listening_mode", "read-error")
      logger.debug("hal.listening_mode_error", status)
      return .readError
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
    setListeningModeAndReadBack(target, allowOff: false)
  }

  func setListeningModeAndReadBackAllowingOff(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    setListeningModeAndReadBack(target, allowOff: true)
  }

  private func setListeningModeAndReadBack(
    _ target: ListeningMode,
    allowOff: Bool
  ) -> DeviceWriteObservation<ListeningMode> {
    guard let rawTarget = halWritableRawValueByListeningMode[target],
      target == .off ? allowOff : availableListeningModes().contains(target)
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
    let settleThroughDeadline = target == .off && setterAccepted
    var observed: ListeningMode?
    for attempt in 1...halReadbackAttempts {
      settle(for: halReadbackInterval)
      observed = currentListeningMode()
      logger.debug("hal.verify.listening_mode.attempt", attempt)
      if observed == target, !settleThroughDeadline { break }
      if !setterAccepted { break }
    }
    return DeviceWriteObservation(
      setterAccepted: setterAccepted,
      observed: observed
    )
  }

  func settle(for interval: TimeInterval) {
    wait(interval)
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
  let allowOffCorrelation: ListeningModeAllowOffCorrelation?

  init(
    displayName: String,
    selectableNames: [String],
    avTransport: (any ListeningModeTransport)?,
    halTransport: (any ListeningModeTransport)?,
    route: ListeningModeCandidateRoute,
    avJoinEvidence: ActiveFeatureEndpointJoinEvidence? = nil,
    allowOffCorrelation: ListeningModeAllowOffCorrelation? = nil
  ) {
    self.displayName = displayName
    self.selectableNames = selectableNames
    self.avTransport = avTransport
    self.halTransport = halTransport
    self.route = route
    self.avJoinEvidence = avJoinEvidence
      ?? (avTransport == nil ? .unavailable : .matched)
    self.allowOffCorrelation = allowOffCorrelation
  }
}

enum ListeningModeAmbiguousChoice {
  case selected(index: Int)
  case unavailable
}

enum ListeningModeHALDiscovery: Equatable {
  // An empty candidate list is meaningful only when discovery succeeded.
  case available
  case unavailable
  case readError
}

struct ListeningModeSession {
  let name: String?
  let transport: any ListeningModeTransport
  let availableModes: [ListeningMode]
  let currentMode: ListeningMode?
  let stateObservation: ListeningModeStateObservation
  let availabilityObservation: ListeningModeAvailabilityObservation?
  let writePlan: ListeningModeWritePlan?
  let allowOffAuthorization: ListeningModeAllowOffAuthorization?
  let blocksCachedAllowOff: Bool

  var cachedAllowOffEvidence: CachedAllowOffEvidence? {
    allowOffAuthorization?.cachedEvidence
  }
}

enum ListeningModeResolution {
  case session(ListeningModeSession)
  case failed(TerminalReason)
}

final class ListeningModeCoordinator {
  private let avCandidates: [ListeningModeCandidate]
  private let halCandidates: [ListeningModeCandidate]
  private let halDiscovery: ListeningModeHALDiscovery
  private let logger: DebugLogger

  init(
    avDevices: [PrivateAudioDevice],
    halCandidates: [ListeningModeCandidate],
    halDiscovery: ListeningModeHALDiscovery = .available,
    logger: DebugLogger
  ) {
    avCandidates = avDevices.compactMap { device in
      guard let name = device.name else { return nil }
      return ListeningModeCandidate(
        displayName: name,
        selectableNames: [name],
        avTransport: device,
        halTransport: nil,
        route: device.isActiveOperationalEndpoint ? .selected : .unknown,
        allowOffCorrelation: nil
      )
    }
    self.halCandidates = halCandidates
    self.halDiscovery = halDiscovery
    self.logger = logger
  }

  init(
    candidates: [ListeningModeCandidate],
    halDiscovery: ListeningModeHALDiscovery = .available,
    logger: DebugLogger
  ) {
    avCandidates = candidates.filter { $0.halTransport == nil }
    halCandidates = candidates.filter { $0.halTransport != nil }
    self.halDiscovery = halDiscovery
    self.logger = logger
  }

  // One selected AV candidate already ready for this command. Otherwise nil,
  // which means load HAL and call resolve(). Does not offer the chooser.
  func uniqueSelectedReadySession(
    command: ListeningModeCommand,
    named requestedName: String?
  ) -> ListeningModeSession? {
    let selectedCandidate: ListeningModeCandidate
    if let requestedName {
      let matches = matching(requestedName, in: avCandidates)
      guard matches.count == 1, let only = matches.first else { return nil }
      selectedCandidate = only
    } else {
      let candidates = logicalCandidates()
      guard candidates.count == 1, let only = candidates.first else { return nil }
      selectedCandidate = only
    }
    guard selectedCandidate.route == .selected else { return nil }
    guard let session = selectTransport(for: selectedCandidate, command: command),
      isReady(session, for: command)
    else { return nil }
    return session
  }

  func resolve(
    command: ListeningModeCommand,
    named requestedName: String?,
    chooseAmbiguous: ([String]) -> ListeningModeAmbiguousChoice
  ) -> ListeningModeResolution {
    let selectedCandidate: ListeningModeCandidate

    if let requestedName {
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
        return matchCount == 0
          ? discoveryFailureResolution(for: command) ?? .failed(.noDevice)
          : .failed(.ambiguousDevice)
      }
      selectedCandidate = halMatches.first ?? avMatches[0]
    } else {
      let candidates = logicalCandidates()
      guard !candidates.isEmpty else {
        return discoveryFailureResolution(for: command) ?? .failed(.noDevice)
      }
      if candidates.count == 1, let only = candidates.first {
        selectedCandidate = only
      } else {
        switch chooseAmbiguous(candidates.map(\.displayName)) {
        case .selected(let index) where candidates.indices.contains(index):
          selectedCandidate = candidates[index]
        case .selected, .unavailable:
          return .failed(.ambiguousDevice)
        }
      }
    }

    guard let session = selectTransport(for: selectedCandidate, command: command) else {
      return discoveryFailureResolution(for: command) ?? .failed(.noDevice)
    }
    logger.info("listening_mode.transport", session.transport.listeningModeTransportKind.rawValue)
    return .session(session)
  }

  private func discoveryFailureResolution(
    for command: ListeningModeCommand
  ) -> ListeningModeResolution? {
    switch halDiscovery {
    case .available:
      return nil
    case .unavailable:
      return .failed(.unavailable)
    case .readError:
      switch command {
      case .get, .list:
        return .failed(.readError)
      case .set, .cycle:
        return .failed(.unavailable)
      }
    }
  }

  private func logicalCandidates() -> [ListeningModeCandidate] {
    let joinedHAL = halCandidates.map(attachUniqueActiveAV)
    let independentAV = avCandidates.filter { avCandidate in
      !joinedHAL.contains { halCandidate in
        representsJoinedAVTarget(avCandidate, in: halCandidate)
      }
    }
    return joinedHAL + independentAV
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
      avJoinEvidence: .matched,
      allowOffCorrelation: candidate.allowOffCorrelation
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
    var liveAllowOffAuthorization: ListeningModeAllowOffAuthorization?
    var blocksCachedAllowOff = false
    for transport in transports {
      let captured = session(
        for: transport,
        command: command,
        correlation: candidate.allowOffCorrelation,
        liveAllowOffAuthorization: liveAllowOffAuthorization,
        blocksCachedAllowOff: blocksCachedAllowOff
      )
      sessions.append(captured)
      if transport.listeningModeTransportKind == .av,
        captured.allowOffAuthorization != nil
      {
        liveAllowOffAuthorization = captured.allowOffAuthorization
      }
      if transport.listeningModeTransportKind == .av,
        captured.blocksCachedAllowOff
      {
        blocksCachedAllowOff = true
        liveAllowOffAuthorization = nil
      }
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
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?,
    liveAllowOffAuthorization: ListeningModeAllowOffAuthorization?,
    blocksCachedAllowOff: Bool
  ) -> ListeningModeSession {
    let availableModes: [ListeningMode]
    let currentMode: ListeningMode?
    let stateObservation: ListeningModeStateObservation
    let availabilityObservation: ListeningModeAvailabilityObservation?
    let canSet: Bool
    var allowOffAuthorization: ListeningModeAllowOffAuthorization?
    var allowsOffProbe = false
    var freshAVBlocksCachedAllowOff = false

    switch command {
    case .get:
      availableModes = []
      availabilityObservation = nil
      let currentObservedAt = transport.listeningModeTransportKind == .av
        ? correlation?.captureObservationTime()
        : nil
      stateObservation = transport.listeningModeStateObservation()
      currentMode = stateObservation.value
      canSet = false
      if currentMode == .off, let correlation, let currentObservedAt {
        correlation.observeCurrentOff(observedAt: currentObservedAt)
      }
    case .list, .set, .cycle:
      let preflight = availabilityPreflight(
        for: transport,
        command: command,
        correlation: correlation,
        liveAllowOffAuthorization: liveAllowOffAuthorization,
        blocksCachedAllowOff: blocksCachedAllowOff
      )
      currentMode = preflight.currentMode
      stateObservation = preflight.stateObservation
      availabilityObservation = preflight.availabilityObservation
      availableModes = preflight.availableModes
      allowOffAuthorization = preflight.allowOffAuthorization
      allowsOffProbe = preflight.allowsOffProbe
      freshAVBlocksCachedAllowOff = preflight.blocksCachedAllowOff
      switch command {
      case .list:
        canSet = false
      case .set, .cycle:
        canSet = transport.canSetListeningMode()
      case .get:
        canSet = false
      }
    }

    let effectiveModes: [ListeningMode]
    if allowOffAuthorization != nil || allowsOffProbe {
      let advertised = Set(availableModes).union([.off])
      effectiveModes = ListeningMode.allCases.filter { advertised.contains($0) }
    } else {
      effectiveModes = availableModes
    }

    let stateIsSafe = transport.listeningModeTransportKind == .av
      || currentMode != nil
    let writePlan = canSet && stateIsSafe
      ? ListeningModeWritePlan(
        transport: transport,
        availableModes: effectiveModes,
        allowOffAuthorization: allowOffAuthorization,
        allowsOffProbe: allowsOffProbe,
        allowOffCorrelation: correlation
      )
      : nil

    return ListeningModeSession(
      name: transport.name,
      transport: transport,
      availableModes: effectiveModes,
      currentMode: currentMode,
      stateObservation: stateObservation,
      availabilityObservation: availabilityObservation,
      writePlan: writePlan,
      allowOffAuthorization: allowOffAuthorization,
      blocksCachedAllowOff: freshAVBlocksCachedAllowOff
    )
  }

  private struct ListeningModeAvailabilityPreflight {
    let currentMode: ListeningMode?
    let stateObservation: ListeningModeStateObservation
    let availabilityObservation: ListeningModeAvailabilityObservation
    let availableModes: [ListeningMode]
    let allowOffAuthorization: ListeningModeAllowOffAuthorization?
    let allowsOffProbe: Bool
    let blocksCachedAllowOff: Bool
  }

  private func availabilityPreflight(
    for transport: any ListeningModeTransport,
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?,
    liveAllowOffAuthorization: ListeningModeAllowOffAuthorization?,
    blocksCachedAllowOff: Bool
  ) -> ListeningModeAvailabilityPreflight {
    let observedAt = transport.listeningModeTransportKind == .av
      ? correlation?.captureObservationTime()
      : nil
    let stateObservation = transport.listeningModeStateObservation()
    let currentMode = stateObservation.value
    let availability = transport.listeningModeAvailabilityObservation()
    let availableModes = normalizedModes(from: availability)
    let freshAVBlocksCachedAllowOff = availabilityBlocksCachedAllowOff(
      availability,
      transport: transport,
      command: command
    )
    let allowOffAuthorization = applyAllowOffPolicy(
      to: availability,
      transport: transport,
      command: command,
      correlation: correlation,
      liveAllowOffAuthorization: liveAllowOffAuthorization,
      blocksCachedAllowOff: blocksCachedAllowOff || freshAVBlocksCachedAllowOff,
      observedAt: observedAt
    )
    let allowsOffProbe = shouldProbeAllowOff(
      availability: availability,
      transport: transport,
      command: command,
      correlation: correlation,
      hasAuthorization: allowOffAuthorization != nil
    )
    return ListeningModeAvailabilityPreflight(
      currentMode: currentMode,
      stateObservation: stateObservation,
      availabilityObservation: availability,
      availableModes: availableModes,
      allowOffAuthorization: allowOffAuthorization,
      allowsOffProbe: allowsOffProbe,
      blocksCachedAllowOff: freshAVBlocksCachedAllowOff
    )
  }

  private func shouldProbeAllowOff(
    availability: ListeningModeAvailabilityObservation,
    transport: any ListeningModeTransport,
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?,
    hasAuthorization: Bool
  ) -> Bool {
    guard transport.listeningModeTransportKind == .hal,
      commandExplicitlyTargetsOff(command),
      case .value = availability,
      !hasAuthorization
    else { return false }
    return correlation?.hasCachedDenial() != true
  }

  private func commandExplicitlyTargetsOff(_ command: ListeningModeCommand) -> Bool {
    switch command {
    case .set(.off): return true
    case let .cycle(requested): return requested?.contains(.off) == true
    case .get, .list, .set: return false
    }
  }

  private func normalizedModes(
    from observation: ListeningModeAvailabilityObservation
  ) -> [ListeningMode] {
    let modes: [ListeningMode]
    switch observation {
    case let .value(value), let .partial(value): modes = value
    case .unavailable, .readError: return []
    }
    let advertised = Set(modes)
    return ListeningMode.allCases.filter { advertised.contains($0) }
  }

  private func applyAllowOffPolicy(
    to availability: ListeningModeAvailabilityObservation,
    transport: any ListeningModeTransport,
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?,
    liveAllowOffAuthorization: ListeningModeAllowOffAuthorization?,
    blocksCachedAllowOff: Bool,
    observedAt: Date?
  ) -> ListeningModeAllowOffAuthorization? {
    guard commandMayUseAllowOffCache(command) else { return nil }
    switch transport.listeningModeTransportKind {
    case .av:
      if case .value(let modes) = availability, modes.contains(.off) {
        if let correlation, let observedAt {
          return correlation.observeAvailability(availability, observedAt: observedAt)
        }
        return .live(cache: nil, record: nil)
      }
      if let correlation, let observedAt {
        _ = correlation.observeAvailability(availability, observedAt: observedAt)
      }
      return nil
    case .hal:
      guard case .value = availability else { return nil }
      guard !blocksCachedAllowOff else { return nil }
      return liveAllowOffAuthorization ?? correlation?.cachedAuthorization()
    }
  }

  private func availabilityBlocksCachedAllowOff(
    _ availability: ListeningModeAvailabilityObservation,
    transport: any ListeningModeTransport,
    command: ListeningModeCommand
  ) -> Bool {
    guard transport.listeningModeTransportKind == .av,
      commandMayUseAllowOffCache(command),
      case .value(let modes) = availability
    else { return false }
    return !modes.contains(.off)
  }

  private func commandMayUseAllowOffCache(_ command: ListeningModeCommand) -> Bool {
    switch command {
    case .list:
      return true
    case .set(.off):
      return true
    case .cycle(let requested):
      return requested?.contains(.off) == true
    case .get, .set:
      return false
    }
  }

  private func isReady(
    _ session: ListeningModeSession,
    for command: ListeningModeCommand
  ) -> Bool {
    switch command {
    case .get:
      switch session.stateObservation {
      case .value, .unknown: return true
      case .unavailable, .readError: return false
      }
    case .list:
      switch session.availabilityObservation {
      case .value, .partial: return true
      case .unavailable, .readError, .none: return false
      }
    case .set(let target):
      return session.writePlan?.canWrite(target) == true
    case .cycle(let requested):
      let base = requested ?? ListeningMode.allCases.filter { $0 != .off }
      let supported = base.filter { session.availableModes.contains($0) }
      return supported.count >= 2 && session.writePlan != nil
    }
  }
}
