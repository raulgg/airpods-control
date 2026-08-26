import CoreAudio
import Foundation

enum ListeningModeTransportKind: String {
  case av
  case hal
}

enum ListeningModeAvailabilityObservation {
  case value([ListeningMode])
  case unavailable
}

protocol ListeningModeTransport: AnyObject {
  var name: String? { get }
  var listeningModeTransportKind: ListeningModeTransportKind { get }

  func availableListeningModes() -> [ListeningMode]
  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation
  func currentListeningMode() -> ListeningMode?
  func canSetListeningMode() -> Bool
  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode>
  func setListeningModeAndReadBack(
    _ target: ListeningMode,
    allowOff: Bool
  ) -> DeviceWriteObservation<ListeningMode>
  func settle(for interval: TimeInterval)
}

extension ListeningModeTransport {
  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation {
    .value(availableListeningModes())
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode,
    allowOff: Bool
  ) -> DeviceWriteObservation<ListeningMode> {
    setListeningModeAndReadBack(target)
  }
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

final class HALListeningModeTransport: ListeningModeTransport {
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
    guard case .value(let modes) = listeningModeAvailabilityObservation() else {
      return []
    }
    return modes
  }

  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation {
    guard
      case .value(let rawMask) = backend.readBluetoothListeningModeSupport(
        for: audioDeviceID
      )
    else { return .unavailable }

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
    return .value(ListeningMode.allCases.filter { modes.contains($0) })
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
    setListeningModeAndReadBack(target, allowOff: false)
  }

  func setListeningModeAndReadBack(
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

final class ListeningModeAllowOffAuthorization {
  let cachedEvidence: CachedAllowOffEvidence?

  private let cache: (any ListeningModeAllowOffCaching)?
  private let record: AllowOffCacheRecord?

  private init(
    cachedEvidence: CachedAllowOffEvidence?,
    cache: (any ListeningModeAllowOffCaching)?,
    record: AllowOffCacheRecord?
  ) {
    self.cachedEvidence = cachedEvidence
    self.cache = cache
    self.record = record
  }

  static func live(
    cache: (any ListeningModeAllowOffCaching)?,
    record: AllowOffCacheRecord?
  ) -> ListeningModeAllowOffAuthorization {
    ListeningModeAllowOffAuthorization(
      cachedEvidence: nil,
      cache: cache,
      record: record
    )
  }

  static func cached(
    cache: any ListeningModeAllowOffCaching,
    record: AllowOffCacheRecord
  ) -> ListeningModeAllowOffAuthorization {
    ListeningModeAllowOffAuthorization(
      cachedEvidence: record.evidence,
      cache: cache,
      record: record
    )
  }

  func invalidate() {
    guard let cache, let record else { return }
    _ = cache.remove(record: record)
  }
}

final class ListeningModeAllowOffCorrelation {
  private let targetAudioDeviceID: AudioDeviceID
  private let collisionAudioDeviceIDs: [AudioDeviceID]
  private let backend: any AudioRoutingBackend
  private let cache: any ListeningModeAllowOffCaching
  private let logger: DebugLogger
  private let now: () -> Date

  init(
    targetAudioDeviceID: AudioDeviceID,
    collisionAudioDeviceIDs: [AudioDeviceID],
    backend: any AudioRoutingBackend,
    cache: any ListeningModeAllowOffCaching,
    logger: DebugLogger,
    now: @escaping () -> Date = Date.init
  ) {
    self.targetAudioDeviceID = targetAudioDeviceID
    self.collisionAudioDeviceIDs = Array(Set(collisionAudioDeviceIDs)).sorted()
    self.backend = backend
    self.cache = cache
    self.logger = logger
    self.now = now
  }

  func observeAvailability(
    _ observation: ListeningModeAvailabilityObservation
  ) -> ListeningModeAllowOffAuthorization? {
    switch observation {
    case .unavailable:
      return nil
    case .value(let modes) where modes.contains(.off):
      var storedRecord: AllowOffCacheRecord?
      withUnambiguousRawUID { rawDeviceUID in
        _ = cache.storePositiveObservation(rawDeviceUID: rawDeviceUID)
        if case .hit(let record) = cache.lookup(rawDeviceUID: rawDeviceUID) {
          storedRecord = record
        }
      }
      // Fresh AV evidence can authorize this invocation even when the
      // disposable cache cannot be correlated or written.
      return .live(cache: storedRecord == nil ? nil : cache, record: storedRecord)
    case .value:
      withUnambiguousRawUID { rawDeviceUID in
        _ = cache.removeEvidence(rawDeviceUID: rawDeviceUID)
      }
      return nil
    }
  }

  func observeCurrentOff() {
    withUnambiguousRawUID { rawDeviceUID in
      _ = cache.storePositiveObservation(rawDeviceUID: rawDeviceUID)
    }
  }

  func cachedAuthorization() -> ListeningModeAllowOffAuthorization? {
    var record: AllowOffCacheRecord?
    withUnambiguousRawUID { rawDeviceUID in
      if case .hit(let value) = cache.lookup(rawDeviceUID: rawDeviceUID) {
        record = value
      }
    }
    guard let record else {
      logger.debug("allow_off_cache", "miss")
      return nil
    }
    logger.debug("allow_off_cache", "hit")
    let age = max(0, min(604_800, Int(now().timeIntervalSince(record.evidence.observedAt))))
    logger.debug("allow_off_cache.age_seconds", age)
    return .cached(cache: cache, record: record)
  }

  private func withUnambiguousRawUID(_ body: (String) -> Void) {
    guard collisionAudioDeviceIDs.contains(targetAudioDeviceID),
      !collisionAudioDeviceIDs.isEmpty
    else { return }

    var values: [(AudioDeviceID, String)] = []
    for audioDeviceID in collisionAudioDeviceIDs {
      guard case .value(.some(let rawUID)) = backend.readDeviceUID(for: audioDeviceID),
        !rawUID.isEmpty,
        rawUID.utf8.count <= 4_096
      else { return }
      values.append((audioDeviceID, rawUID))
    }
    guard let targetUID = values.first(where: { $0.0 == targetAudioDeviceID })?.1,
      values.filter({ $0.1 == targetUID }).count == 1
    else { return }
    body(targetUID)
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
  case cancelled
  case unavailable
}

struct ListeningModeSession {
  let name: String?
  let transport: any ListeningModeTransport
  let availableModes: [ListeningMode]
  let currentMode: ListeningMode?
  let writePlan: ListeningModeWritePlan?
  let allowOffAuthorization: ListeningModeAllowOffAuthorization?
  let blocksCachedAllowOff: Bool

  var cachedAllowOffEvidence: CachedAllowOffEvidence? {
    allowOffAuthorization?.cachedEvidence
  }
}

struct ListeningModeWritePlan {
  private let transport: any ListeningModeTransport
  private let availableModes: [ListeningMode]
  private let allowOffAuthorization: ListeningModeAllowOffAuthorization?
  private let authorizesHALOff: Bool

  init(
    transport: any ListeningModeTransport,
    availableModes: [ListeningMode],
    allowOffAuthorization: ListeningModeAllowOffAuthorization?
  ) {
    self.transport = transport
    self.availableModes = availableModes
    self.allowOffAuthorization = allowOffAuthorization
    authorizesHALOff = transport.listeningModeTransportKind == .hal
      && allowOffAuthorization != nil
  }

  func canWrite(_ target: ListeningMode) -> Bool {
    availableModes.contains(target)
  }

  func execute(_ target: ListeningMode) -> ListeningModeWriteResolution {
    precondition(canWrite(target), "write plan cannot execute an unavailable mode")
    let observation = transport.setListeningModeAndReadBack(
      target,
      allowOff: authorizesHALOff
    )
    if target == .off,
      authorizesHALOff,
      allowOffAuthorization?.cachedEvidence != nil,
      observation.setterAccepted,
      let observed = observation.observed,
      observed != .off
    {
      allowOffAuthorization?.invalidate()
    }
    return resolveListeningModeWrite(
      requested: target,
      setterAccepted: observation.setterAccepted,
      observed: observation.observed,
      transparencySupported: availableModes.contains(.transparency)
        && !authorizesHALOff
    )
  }
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
        route: device.isActiveOperationalEndpoint ? .selected : .unknown,
        allowOffCorrelation: nil
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
        let selectedAVCandidates = avCandidates.filter { $0.route == .selected }
        if selectedAVCandidates.count == 1, let selected = selectedAVCandidates.first {
          selectedCandidate = selected
        } else if selectedAVCandidates.count > 1 {
          logger.warning("device_selection", "ambiguous-active-device")
          return .ambiguousDevice
        } else {
          selectedCandidate = halCandidates[0]
        }
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
    let canSet: Bool
    var allowOffAuthorization: ListeningModeAllowOffAuthorization?
    var freshAVBlocksCachedAllowOff = false

    switch command {
    case .get:
      availableModes = []
      currentMode = transport.currentListeningMode()
      canSet = false
      if transport.listeningModeTransportKind == .av, currentMode == .off {
        correlation?.observeCurrentOff()
      }
    case .list:
      currentMode = transport.currentListeningMode()
      let availability = transport.listeningModeAvailabilityObservation()
      availableModes = normalizedModes(from: availability)
      freshAVBlocksCachedAllowOff = availabilityBlocksCachedAllowOff(
        availability,
        transport: transport,
        command: command
      )
      allowOffAuthorization = applyAllowOffPolicy(
        to: availability,
        transport: transport,
        command: command,
        correlation: correlation,
        liveAllowOffAuthorization: liveAllowOffAuthorization,
        blocksCachedAllowOff: blocksCachedAllowOff || freshAVBlocksCachedAllowOff
      )
      canSet = false
    case .set, .cycle:
      currentMode = transport.currentListeningMode()
      let availability = transport.listeningModeAvailabilityObservation()
      availableModes = normalizedModes(from: availability)
      freshAVBlocksCachedAllowOff = availabilityBlocksCachedAllowOff(
        availability,
        transport: transport,
        command: command
      )
      allowOffAuthorization = applyAllowOffPolicy(
        to: availability,
        transport: transport,
        command: command,
        correlation: correlation,
        liveAllowOffAuthorization: liveAllowOffAuthorization,
        blocksCachedAllowOff: blocksCachedAllowOff || freshAVBlocksCachedAllowOff
      )
      canSet = transport.canSetListeningMode()
    }

    let effectiveModes: [ListeningMode]
    if allowOffAuthorization != nil {
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
        allowOffAuthorization: allowOffAuthorization
      )
      : nil

    return ListeningModeSession(
      name: transport.name,
      transport: transport,
      availableModes: effectiveModes,
      currentMode: currentMode,
      writePlan: writePlan,
      allowOffAuthorization: allowOffAuthorization,
      blocksCachedAllowOff: freshAVBlocksCachedAllowOff
    )
  }

  private func normalizedModes(
    from observation: ListeningModeAvailabilityObservation
  ) -> [ListeningMode] {
    guard case .value(let modes) = observation else { return [] }
    let advertised = Set(modes)
    return ListeningMode.allCases.filter { advertised.contains($0) }
  }

  private func applyAllowOffPolicy(
    to availability: ListeningModeAvailabilityObservation,
    transport: any ListeningModeTransport,
    command: ListeningModeCommand,
    correlation: ListeningModeAllowOffCorrelation?,
    liveAllowOffAuthorization: ListeningModeAllowOffAuthorization?,
    blocksCachedAllowOff: Bool
  ) -> ListeningModeAllowOffAuthorization? {
    guard commandMayUseAllowOffCache(command) else { return nil }
    switch transport.listeningModeTransportKind {
    case .av:
      if case .value(let modes) = availability, modes.contains(.off) {
        return correlation?.observeAvailability(availability)
          ?? .live(cache: nil, record: nil)
      }
      _ = correlation?.observeAvailability(availability)
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
      return session.currentMode != nil
    case .list:
      return !session.availableModes.isEmpty
    case .set(let target):
      return session.writePlan?.canWrite(target) == true
    case .cycle(let requested):
      let base = requested ?? ListeningMode.allCases.filter { $0 != .off }
      let supported = base.filter { session.availableModes.contains($0) }
      return supported.count >= 2 && session.writePlan != nil
    }
  }
}
