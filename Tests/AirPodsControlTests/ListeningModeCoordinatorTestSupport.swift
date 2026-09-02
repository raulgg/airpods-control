import CoreAudio
import Foundation

final class FakeListeningModeTransport: ListeningModeAllowOffTransport {
  let name: String?
  let listeningModeTransportKind: ListeningModeTransportKind
  var modes: [ListeningMode]
  var current: ListeningMode?
  var settable: Bool
  var acceptsWrites: Bool
  var appliesWrites: Bool
  var availabilityObservation: ListeningModeAvailabilityObservation?
  var dropsWriteReadback = false
  private(set) var readModesCount = 0
  private(set) var readCurrentCount = 0
  private(set) var canSetCount = 0
  private(set) var setterTargets: [ListeningMode] = []
  private(set) var allowOffWrites: [Bool] = []

  init(
    name: String,
    kind: ListeningModeTransportKind,
    modes: [ListeningMode] = ListeningMode.allCases,
    current: ListeningMode? = .transparency,
    settable: Bool = true,
    acceptsWrites: Bool? = nil,
    appliesWrites: Bool = true
  ) {
    self.name = name
    listeningModeTransportKind = kind
    self.modes = modes
    self.current = current
    self.settable = settable
    self.acceptsWrites = acceptsWrites ?? settable
    self.appliesWrites = appliesWrites
  }

  func availableListeningModes() -> [ListeningMode] {
    readModesCount += 1
    return modes
  }

  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation {
    readModesCount += 1
    return availabilityObservation ?? .value(modes)
  }

  func currentListeningMode() -> ListeningMode? {
    readCurrentCount += 1
    return current
  }

  func canSetListeningMode() -> Bool {
    canSetCount += 1
    return settable
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    allowOffWrites.append(false)
    return applyWrite(target)
  }

  func setListeningModeAndReadBackAllowingOff(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    allowOffWrites.append(true)
    return applyWrite(target)
  }

  private func applyWrite(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    setterTargets.append(target)
    if appliesWrites { current = target }
    return DeviceWriteObservation(
      setterAccepted: acceptsWrites,
      observed: dropsWriteReadback ? nil : current
    )
  }

  func settle(for interval: TimeInterval) {}
}

final class OrdinaryHALListeningModeTransport: ListeningModeTransport {
  private let wrapped: FakeListeningModeTransport

  init(wrapped: FakeListeningModeTransport) {
    self.wrapped = wrapped
  }

  var name: String? { wrapped.name }
  var listeningModeTransportKind: ListeningModeTransportKind {
    wrapped.listeningModeTransportKind
  }

  func availableListeningModes() -> [ListeningMode] {
    wrapped.availableListeningModes()
  }

  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation {
    wrapped.listeningModeAvailabilityObservation()
  }

  func currentListeningMode() -> ListeningMode? {
    wrapped.currentListeningMode()
  }

  func canSetListeningMode() -> Bool {
    wrapped.canSetListeningMode()
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    wrapped.setListeningModeAndReadBack(target)
  }

  func settle(for interval: TimeInterval) {
    wrapped.settle(for: interval)
  }
}

final class FakeHALRoutingBackend: AudioRoutingBackend {
  var rawModeRead: AudioRoutingRead<UInt32> = .value(3)
  var supportRead: AudioRoutingRead<UInt32> = .value(0b111)
  var settableRead: AudioRoutingRead<Bool> = .value(true)
  var writeResult: AudioRoutingWrite = .success
  var appliesWrite = true
  var deviceUIDs: [AudioDeviceID: AudioRoutingRead<String?>] = [:]
  var onDeviceUIDRead: (() -> Void)?
  private(set) var writtenValues: [UInt32] = []
  private(set) var deviceUIDReads: [AudioDeviceID] = []

  func readAudioDevices() -> AudioRoutingRead<[AudioDeviceID]> { .unavailable }
  func readDefaultDevice(
    for direction: AudioRoutingDirection
  ) -> AudioRoutingRead<AudioDeviceID?> { .unavailable }
  func isAggregateDevice(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    .unavailable
  }
  func readTransportType(for deviceID: AudioDeviceID) -> AudioRoutingRead<UInt32> {
    .unavailable
  }
  func readDeviceIsAlive(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    .unavailable
  }
  func readHasStreams(
    for deviceID: AudioDeviceID,
    direction: AudioRoutingDirection
  ) -> AudioRoutingRead<Bool> { .unavailable }
  func readManufacturer(for deviceID: AudioDeviceID) -> AudioRoutingRead<String?> {
    .unavailable
  }
  func readName(for deviceID: AudioDeviceID) -> AudioRoutingRead<String?> {
    .unavailable
  }
  func readDeviceUID(for deviceID: AudioDeviceID) -> AudioRoutingRead<String?> {
    deviceUIDReads.append(deviceID)
    onDeviceUIDRead?()
    return deviceUIDs[deviceID] ?? .unavailable
  }
  func readIsAppleAudioDevice(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    .unavailable
  }
  func readBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> { rawModeRead }
  func hasBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> Bool { true }
  func readBluetoothListeningModeSupport(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> { supportRead }
  func isBluetoothListeningModeSettable(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<Bool> { settableRead }
  func writeBluetoothListeningMode(
    _ rawValue: UInt32,
    for deviceID: AudioDeviceID
  ) -> AudioRoutingWrite {
    writtenValues.append(rawValue)
    if appliesWrite, writeResult == .success {
      rawModeRead = .value(rawValue)
    }
    return writeResult
  }

  func resetWrites() {
    writtenValues.removeAll()
  }
}

func coordinatorOutcome(
  _ arguments: [String],
  candidates: [ListeningModeCandidate],
  choice: ListeningModeAmbiguousChoice = .unavailable,
  halDiscovery: ListeningModeHALDiscovery = .available
) -> CommandOutcome {
  let invocation = try! parseInvocation(arguments)
  let coordinator = ListeningModeCoordinator(
    candidates: candidates,
    halDiscovery: halDiscovery,
    logger: DebugLogger(enabled: false)
  )
  return CommandExecution.executeListeningMode(
    invocation,
    resolveSession: { command, name, _ in
      coordinator.resolve(
        command: command,
        named: name,
        chooseAmbiguous: { _ in choice }
      )
    }
  )
}
func candidate(
  name: String = "Desk AirPods",
  av: FakeListeningModeTransport? = nil,
  hal: FakeListeningModeTransport? = nil,
  route: ListeningModeCandidateRoute,
  allowOffCorrelation: ListeningModeAllowOffCorrelation? = nil
) -> ListeningModeCandidate {
  ListeningModeCandidate(
    displayName: name,
    selectableNames: [name],
    avTransport: av,
    halTransport: hal,
    route: route,
    allowOffCorrelation: allowOffCorrelation
  )
}
