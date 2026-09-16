import CoreAudio
import Foundation

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
