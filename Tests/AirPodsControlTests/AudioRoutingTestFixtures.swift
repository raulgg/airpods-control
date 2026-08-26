import CoreAudio
import Foundation

final class FakeAudioRoutingBackend: AudioRoutingBackend {
  var audioDevices: AudioRoutingRead<[AudioDeviceID]> = .value([])
  var outputDefaults: [AudioRoutingRead<AudioDeviceID?>] = [.value(nil), .value(nil)]
  var inputDefaults: [AudioRoutingRead<AudioDeviceID?>] = [.value(nil), .value(nil)]
  var aggregates: [AudioDeviceID: AudioRoutingRead<Bool>] = [:]
  var transports: [AudioDeviceID: AudioRoutingRead<UInt32>] = [:]
  var alive: [AudioDeviceID: AudioRoutingRead<Bool>] = [:]
  var inputStreams: [AudioDeviceID: AudioRoutingRead<Bool>] = [:]
  var outputStreams: [AudioDeviceID: AudioRoutingRead<Bool>] = [:]
  var manufacturers: [AudioDeviceID: AudioRoutingRead<String?>] = [:]
  var names: [AudioDeviceID: AudioRoutingRead<String?>] = [:]
  var appleAudioDevices: [AudioDeviceID: AudioRoutingRead<Bool>] = [:]
  var listeningModes: [AudioDeviceID: AudioRoutingRead<UInt32>] = [:]
  var listeningModePresence: [AudioDeviceID: Bool] = [:]
  var listeningModeSupport: [AudioDeviceID: AudioRoutingRead<UInt32>] = [:]
  var listeningModeSettable: [AudioDeviceID: AudioRoutingRead<Bool>] = [:]
  var listeningModeWriteResult: AudioRoutingWrite = .unavailable
  private(set) var listeningModeWrites: [(AudioDeviceID, UInt32)] = []
  private(set) var audioDeviceReadCount = 0
  private(set) var outputDefaultReadCount = 0
  private(set) var inputDefaultReadCount = 0
  private(set) var aggregateReads: [AudioDeviceID] = []
  private(set) var transportReads: [AudioDeviceID] = []
  private(set) var listeningModeReads: [AudioDeviceID] = []

  func readAudioDevices() -> AudioRoutingRead<[AudioDeviceID]> {
    audioDeviceReadCount += 1
    return audioDevices
  }

  func readDefaultDevice(
    for direction: AudioRoutingDirection
  ) -> AudioRoutingRead<AudioDeviceID?> {
    switch direction {
    case .output:
      defer { outputDefaultReadCount += 1 }
      return read(outputDefaults, at: outputDefaultReadCount)
    case .input:
      defer { inputDefaultReadCount += 1 }
      return read(inputDefaults, at: inputDefaultReadCount)
    }
  }

  func isAggregateDevice(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    aggregateReads.append(deviceID)
    return aggregates[deviceID] ?? .value(false)
  }

  func readTransportType(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> {
    transportReads.append(deviceID)
    return transports[deviceID] ?? .value(kAudioDeviceTransportTypeBluetooth)
  }

  func readDeviceIsAlive(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    alive[deviceID] ?? .value(true)
  }

  func readHasStreams(
    for deviceID: AudioDeviceID,
    direction: AudioRoutingDirection
  ) -> AudioRoutingRead<Bool> {
    switch direction {
    case .input: return inputStreams[deviceID] ?? .value(false)
    case .output: return outputStreams[deviceID] ?? .value(true)
    }
  }

  func readManufacturer(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<String?> {
    manufacturers[deviceID] ?? .value("Apple Inc.")
  }

  func readName(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<String?> {
    names[deviceID] ?? .value("Test AirPods")
  }

  func readIsAppleAudioDevice(
    _ deviceID: AudioDeviceID
  ) -> AudioRoutingRead<Bool> {
    appleAudioDevices[deviceID] ?? .unavailable
  }

  func readBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> {
    listeningModeReads.append(deviceID)
    return listeningModes[deviceID] ?? .unavailable
  }

  func hasBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> Bool {
    listeningModePresence[deviceID] ?? (listeningModes[deviceID] != nil)
  }

  func readBluetoothListeningModeSupport(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> {
    listeningModeSupport[deviceID] ?? .unavailable
  }

  func isBluetoothListeningModeSettable(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<Bool> {
    listeningModeSettable[deviceID] ?? .unavailable
  }

  func writeBluetoothListeningMode(
    _ rawValue: UInt32,
    for deviceID: AudioDeviceID
  ) -> AudioRoutingWrite {
    listeningModeWrites.append((deviceID, rawValue))
    return listeningModeWriteResult
  }

  private func read<Value>(
    _ values: [AudioRoutingRead<Value>],
    at index: Int
  ) -> AudioRoutingRead<Value> {
    precondition(!values.isEmpty)
    return values[min(index, values.count - 1)]
  }
}

struct FakeBluetoothEntry {
  var mode: UInt8? = 3
}

final class FakeBluetoothAudioRuntime: BluetoothAudioRuntime {
  var entries: [ObjectIdentifier: FakeBluetoothEntry] = [:]
  var mappings: [AudioDeviceID: AudioRoutingRead<AnyObject?>] = [:]
  private(set) var mappingReads: [AudioDeviceID] = []

  func add(_ device: AnyObject, entry: FakeBluetoothEntry) {
    entries[ObjectIdentifier(device)] = entry
  }

  func listeningMode(_ device: AnyObject) -> BluetoothRuntimeRead<UInt8> {
    optional(entries[ObjectIdentifier(device)]?.mode)
  }

  func bluetoothDevice(
    for audioDeviceID: AudioDeviceID
  ) -> AudioRoutingRead<AnyObject?> {
    mappingReads.append(audioDeviceID)
    return mappings[audioDeviceID] ?? .unavailable
  }

  private func optional<Value>(_ value: Value?) -> BluetoothRuntimeRead<Value> {
    value.map(BluetoothRuntimeRead.value) ?? .unavailable
  }
}

final class FakeActiveAudioEndpointProbe: ActiveAudioEndpointProbing {
  var read: ActiveAudioEndpointCapture
  private(set) var captureCount = 0

  init(_ read: ActiveAudioEndpointCapture) {
    self.read = read
  }

  func capture() -> ActiveAudioEndpointCapture {
    captureCount += 1
    return read
  }
}

final class EqualBluetoothObject: NSObject {
  let identity: Int

  init(identity: Int) {
    self.identity = identity
  }

  override func isEqual(_ object: Any?) -> Bool {
    (object as? EqualBluetoothObject)?.identity == identity
  }

  override var hash: Int { identity }
}

struct FakeInventoryEndpoint {
  let audioDeviceID: AudioDeviceID
  let bluetoothDevice: AnyObject
  var aggregate: AudioRoutingRead<Bool> = .value(false)
  var transport: AudioRoutingRead<UInt32> = .value(kAudioDeviceTransportTypeBluetooth)
  var alive: AudioRoutingRead<Bool> = .value(true)
  var inputStreams: AudioRoutingRead<Bool> = .value(false)
  var outputStreams: AudioRoutingRead<Bool> = .value(true)
  var manufacturer: AudioRoutingRead<String?> = .value("Apple Inc.")
  var name: AudioRoutingRead<String?> = .value("Test AirPods")
  var appleAudioDevice: AudioRoutingRead<Bool> = .unavailable
  var listeningModePresent = true
  var listeningMode: AudioRoutingRead<UInt32> = .unavailable
  var mapping: AudioRoutingRead<AnyObject?>? = nil
}

func makeBluetoothController(
  inventory: [FakeInventoryEndpoint],
  featureEntries: [(AnyObject, FakeBluetoothEntry)] = [],
  backend: FakeAudioRoutingBackend = FakeAudioRoutingBackend(),
  configureRuntime: (FakeBluetoothAudioRuntime) -> Void = { _ in },
  activeProbe: (any ActiveAudioEndpointProbing)? = nil,
  readStatusListeningMode: Bool = true
) -> (IOBluetoothStatusController, FakeBluetoothAudioRuntime) {
  let runtime = FakeBluetoothAudioRuntime()
  for (device, entry) in featureEntries { runtime.add(device, entry: entry) }
  backend.audioDevices = .value(inventory.map(\.audioDeviceID))
  for endpoint in inventory {
    let id = endpoint.audioDeviceID
    backend.aggregates[id] = endpoint.aggregate
    backend.transports[id] = endpoint.transport
    backend.alive[id] = endpoint.alive
    backend.inputStreams[id] = endpoint.inputStreams
    backend.outputStreams[id] = endpoint.outputStreams
    backend.manufacturers[id] = endpoint.manufacturer
    backend.names[id] = endpoint.name
    backend.appleAudioDevices[id] = endpoint.appleAudioDevice
    backend.listeningModePresence[id] = endpoint.listeningModePresent
    backend.listeningModes[id] = endpoint.listeningMode
    runtime.mappings[id] = endpoint.mapping ?? .value(endpoint.bluetoothDevice)
  }
  configureRuntime(runtime)
  let controller = IOBluetoothStatusController(
    runtime: runtime,
    routingBackend: backend,
    activeEndpointProbe: activeProbe,
    readStatusListeningMode: readStatusListeningMode,
    logger: DebugLogger(enabled: false)
  )!
  return (controller, runtime)
}

func makeBluetoothController(
  devices: [(AnyObject, FakeBluetoothEntry)],
  backend: FakeAudioRoutingBackend = FakeAudioRoutingBackend(),
  configureRuntime: (FakeBluetoothAudioRuntime) -> Void = { _ in },
  activeProbe: (any ActiveAudioEndpointProbing)? = nil
) -> (IOBluetoothStatusController, FakeBluetoothAudioRuntime) {
  let inventory = devices.enumerated().map { index, value in
    FakeInventoryEndpoint(
      audioDeviceID: AudioDeviceID(1_000 + index),
      bluetoothDevice: value.0,
      name: .value("Test AirPods \(index + 1)")
    )
  }
  return makeBluetoothController(
    inventory: inventory,
    featureEntries: devices,
    backend: backend,
    configureRuntime: configureRuntime,
    activeProbe: activeProbe
  )
}
