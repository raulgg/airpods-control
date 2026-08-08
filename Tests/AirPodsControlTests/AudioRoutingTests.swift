import CoreAudio
import Foundation

private final class FakeAudioRoutingBackend: AudioRoutingBackend {
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
  private(set) var audioDeviceReadCount = 0
  private(set) var outputDefaultReadCount = 0
  private(set) var inputDefaultReadCount = 0
  private(set) var aggregateReads: [AudioDeviceID] = []
  private(set) var transportReads: [AudioDeviceID] = []

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
    listeningModes[deviceID] ?? .unavailable
  }

  private func read<Value>(
    _ values: [AudioRoutingRead<Value>],
    at index: Int
  ) -> AudioRoutingRead<Value> {
    precondition(!values.isEmpty)
    return values[min(index, values.count - 1)]
  }
}

private struct FakeBluetoothEntry {
  var mode: UInt8? = 3
}

private final class FakeBluetoothAudioRuntime: BluetoothAudioRuntime {
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

private final class FakeActiveAudioEndpointProbe: ActiveAudioEndpointProbing {
  var read: AudioRoutingRead<ActiveAudioEndpointBinding>
  private(set) var captureCount = 0

  init(_ read: AudioRoutingRead<ActiveAudioEndpointBinding>) {
    self.read = read
  }

  func capture() -> AudioRoutingRead<ActiveAudioEndpointBinding> {
    captureCount += 1
    return read
  }
}

private final class EqualBluetoothObject: NSObject {
  let identity: Int

  init(identity: Int) {
    self.identity = identity
  }

  override func isEqual(_ object: Any?) -> Bool {
    (object as? EqualBluetoothObject)?.identity == identity
  }

  override var hash: Int { identity }
}

private struct FakeInventoryEndpoint {
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
  var listeningMode: AudioRoutingRead<UInt32> = .unavailable
  var mapping: AudioRoutingRead<AnyObject?>? = nil
}

private func makeBluetoothController(
  inventory: [FakeInventoryEndpoint],
  featureEntries: [(AnyObject, FakeBluetoothEntry)] = [],
  backend: FakeAudioRoutingBackend = FakeAudioRoutingBackend(),
  configureRuntime: (FakeBluetoothAudioRuntime) -> Void = { _ in },
  activeProbe: (any ActiveAudioEndpointProbing)? = nil
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
    backend.listeningModes[id] = endpoint.listeningMode
    runtime.mappings[id] = endpoint.mapping ?? .value(endpoint.bluetoothDevice)
  }
  configureRuntime(runtime)
  let controller = IOBluetoothStatusController(
    runtime: runtime,
    routingBackend: backend,
    activeEndpointProbe: activeProbe,
    logger: DebugLogger(enabled: false)
  )!
  return (controller, runtime)
}

private func makeBluetoothController(
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

func testCoreAudioInventoryDeduplicatesEndpointsAndAcceptsSparseMapping() {
  let canonical = EqualBluetoothObject(identity: 1)
  let inputWrapper = EqualBluetoothObject(identity: 1)
  let backend = FakeAudioRoutingBackend()
  let (controller, runtime) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 101,
        bluetoothDevice: inputWrapper,
        inputStreams: .value(true),
        outputStreams: .value(false),
        name: .value("Input AirPods")
      ),
      FakeInventoryEndpoint(
        audioDeviceID: 202,
        bluetoothDevice: canonical,
        name: .value("Office AirPods"),
        appleAudioDevice: .value(true),
        listeningMode: .value(3)
      ),
    ],
    backend: backend
  )

  let devices = controller.selectDevices(named: nil, policy: .allOrExact)
  check(devices?.count == 1,
        "input and output endpoints mapping to one canonical object form one record")
  check(devices?.first?.name == "Office AirPods",
        "the output endpoint supplies the deterministic Core Audio display name")
  check(devices?.first?.availableListeningModes() == [],
        "the status-only adapter does not advertise modes for write commands")
  check(devices?.first?.readListeningModeStatus().value == .transparency,
        "HAL current mode is preferred over a sparse mapped object")
  check(devices?.first?.readConversationAwarenessStatus().isUnresolved == true,
        "a sparse mapped object reports unknown Conversation Awareness honestly")
  check(runtime.mappingReads == [101, 202],
        "each positively gated Core Audio endpoint is mapped exactly once")
  check(backend.audioDeviceReadCount == 1, "the public device inventory is captured once")
  check(
    controller.selectDevices(named: "office airpods", policy: .allOrExact)?.count == 1,
    "status exact-name selection uses the Core Audio name case insensitively"
  )
}

func testCoreAudioInventoryRequiresEveryPositiveEndpointGate() {
  let valid = NSObject()
  let validAppleShortName = NSObject()
  let validBeats = NSObject()
  let dead = NSObject()
  let readError = NSObject()
  let nonApple = NSObject()
  let noStreams = NSObject()
  let aggregate = NSObject()
  let bluetoothLE = NSObject()
  let unmapped = NSObject()
  let unnamed = NSObject()
  let applePropertyFalse = NSObject()
  let applePropertyFailure = NSObject()
  let featureReadFailure = NSObject()
  let (controller, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(audioDeviceID: 1, bluetoothDevice: valid,
                          manufacturer: .value("Acme"), name: .value("Valid AirPods"),
                          appleAudioDevice: .value(true)),
    FakeInventoryEndpoint(audioDeviceID: 2, bluetoothDevice: validAppleShortName,
                          manufacturer: .value("Apple"), name: .value("Other AirPods")),
    FakeInventoryEndpoint(audioDeviceID: 14, bluetoothDevice: validBeats,
                          manufacturer: .value("Beats Electronics, LLC"),
                          name: .value("Valid Beats")),
    FakeInventoryEndpoint(audioDeviceID: 3, bluetoothDevice: dead,
                          alive: .value(false), name: .value("Dead")),
    FakeInventoryEndpoint(audioDeviceID: 4, bluetoothDevice: readError,
                          alive: .failure(-70), name: .value("Read Error")),
    FakeInventoryEndpoint(audioDeviceID: 5, bluetoothDevice: nonApple,
                          manufacturer: .value("Acme"), name: .value("Acme")),
    FakeInventoryEndpoint(audioDeviceID: 6, bluetoothDevice: noStreams,
                          inputStreams: .value(false), outputStreams: .value(false),
                          name: .value("No Streams")),
    FakeInventoryEndpoint(audioDeviceID: 7, bluetoothDevice: aggregate,
                          aggregate: .value(true), name: .value("Aggregate")),
    FakeInventoryEndpoint(audioDeviceID: 8, bluetoothDevice: bluetoothLE,
                          transport: .value(kAudioDeviceTransportTypeBluetoothLE),
                          name: .value("BLE")),
    FakeInventoryEndpoint(audioDeviceID: 9, bluetoothDevice: unmapped,
                          name: .value("Unmapped"), mapping: .value(nil)),
    FakeInventoryEndpoint(audioDeviceID: 10, bluetoothDevice: unnamed,
                          name: .value(nil)),
    FakeInventoryEndpoint(audioDeviceID: 11, bluetoothDevice: applePropertyFalse,
                          name: .value("Rejected False"), appleAudioDevice: .value(false)),
    FakeInventoryEndpoint(audioDeviceID: 12, bluetoothDevice: applePropertyFailure,
                          name: .value("Rejected Error"),
                          appleAudioDevice: .failure(-71)),
    FakeInventoryEndpoint(audioDeviceID: 13, bluetoothDevice: featureReadFailure,
                          name: .value("Feature Unknown"), appleAudioDevice: .value(true),
                          listeningMode: .failure(-72)),
  ])
  let devices = controller.selectDevices(named: nil, policy: .allOrExact)
  check(
    devices?.map(\.name)
      == ["Valid AirPods", "Other AirPods", "Valid Beats", "Feature Unknown"],
    "only endpoints with a positive HAL Apple-audio signal or exact manufacturer fallback survive"
  )
  check(devices?.last?.readListeningModeStatus().isReadError == true,
        "a failed advertised HAL current-mode read is retained as a read error")
}

func testGroupedEndpointIdentityConflictsFailClosed() {
  let canonical = EqualBluetoothObject(identity: 21)
  let conflictingWrapper = EqualBluetoothObject(identity: 21)
  let (appleConflictController, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(audioDeviceID: 21, bluetoothDevice: canonical,
                          name: .value("Conflict AirPods"),
                          appleAudioDevice: .value(true)),
    FakeInventoryEndpoint(audioDeviceID: 22, bluetoothDevice: conflictingWrapper,
                          inputStreams: .value(true), outputStreams: .value(false),
                          appleAudioDevice: .value(false)),
  ])
  check(
    appleConflictController.selectDevices(named: nil, policy: .allOrExact) == nil,
    "conflicting positive and negative HAL Apple-audio evidence rejects the exact group"
  )

  let neutralWrapper = EqualBluetoothObject(identity: 31)
  let positiveWrapper = EqualBluetoothObject(identity: 31)
  let failingWrapper = EqualBluetoothObject(identity: 31)
  let (neutralController, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(audioDeviceID: 31, bluetoothDevice: positiveWrapper,
                          name: .value("Neutral Sibling AirPods"),
                          appleAudioDevice: .value(true), listeningMode: .value(3)),
    FakeInventoryEndpoint(audioDeviceID: 32, bluetoothDevice: neutralWrapper,
                          inputStreams: .value(true), outputStreams: .value(false),
                          manufacturer: .value("Unknown"), name: .value("Ignored"),
                          appleAudioDevice: .unavailable,
                          listeningMode: .value(0)),
    FakeInventoryEndpoint(audioDeviceID: 33, bluetoothDevice: failingWrapper,
                          inputStreams: .value(true), outputStreams: .value(false),
                          appleAudioDevice: .failure(-74),
                          listeningMode: .failure(-75)),
  ])
  let neutral = neutralController.selectDevices(named: nil, policy: .allOrExact)?[0]
  check(neutral?.readListeningModeStatus().value == .transparency,
        "positive evidence survives unavailable/read-error siblings and a zero sentinel")

  let futureMode = NSObject()
  let (futureController, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(audioDeviceID: 35, bluetoothDevice: futureMode,
                            name: .value("Future Mode"), appleAudioDevice: .value(true),
                            listeningMode: .value(5)),
    ],
    featureEntries: [(futureMode, FakeBluetoothEntry(mode: 3))]
  )
  let future = futureController.selectDevices(named: nil, policy: .allOrExact)![0]
  check(future.readListeningModeStatus().isUnresolved,
        "a nonzero future HAL mode suppresses the lower-priority mapped fallback")

  let mixedFuture = NSObject()
  let (mixedFutureController, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(audioDeviceID: 36, bluetoothDevice: mixedFuture,
                          name: .value("Mixed Future"), appleAudioDevice: .value(true),
                          listeningMode: .value(3)),
    FakeInventoryEndpoint(audioDeviceID: 37, bluetoothDevice: mixedFuture,
                          inputStreams: .value(true), outputStreams: .value(false),
                          name: .value("Mixed Future Input"),
                          appleAudioDevice: .value(true), listeningMode: .value(5)),
  ])
  let mixedFutureDevice = mixedFutureController.selectDevices(
    named: nil,
    policy: .allOrExact
  )![0]
  check(mixedFutureDevice.readListeningModeStatus().isUnresolved,
        "a future HAL mode mixed with a recognized value remains unresolved")

  let modeConflict = EqualBluetoothObject(identity: 41)
  let (modeConflictController, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(audioDeviceID: 41, bluetoothDevice: modeConflict,
                            name: .value("Mode Conflict"),
                            appleAudioDevice: .value(true), listeningMode: .value(2)),
      FakeInventoryEndpoint(audioDeviceID: 42, bluetoothDevice: modeConflict,
                            inputStreams: .value(true), outputStreams: .value(false),
                            name: .value("Mode Conflict Input"),
                            appleAudioDevice: .value(true), listeningMode: .value(3)),
    ],
    featureEntries: [(modeConflict, FakeBluetoothEntry(mode: 1))]
  )
  let conflicted = modeConflictController.selectDevices(
    named: nil,
    policy: .allOrExact
  )![0]
  check(conflicted.readListeningModeStatus().isUnresolved,
        "different recognized HAL modes stay unresolved instead of falling back")
}

func testCoreAudioInventoryPreservesFirstGroupOccurrenceOrder() {
  let first = NSObject()
  let second = NSObject()
  let (controller, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(audioDeviceID: 900, bluetoothDevice: first,
                          name: .value("First Seen"), appleAudioDevice: .value(true)),
    FakeInventoryEndpoint(audioDeviceID: 1, bluetoothDevice: second,
                          name: .value("Second Seen"), appleAudioDevice: .value(true)),
  ])
  check(
    controller.selectDevices(named: nil, policy: .allOrExact)?.map(\.name)
      == ["First Seen", "Second Seen"],
    "record order follows first public inventory occurrence, not opaque object IDs"
  )
}

func testCoreAudioInventoryReportsInactiveAndInputOnlySelectionExactly() {
  let canonical = NSObject()
  let endpoint = FakeInventoryEndpoint(
    audioDeviceID: 101,
    bluetoothDevice: canonical,
    inputStreams: .value(true),
    outputStreams: .value(false),
    name: .value("Input AirPods"),
    appleAudioDevice: .value(true)
  )

  let inactiveBackend = FakeAudioRoutingBackend()
  inactiveBackend.outputDefaults = [.value(50), .value(50)]
  inactiveBackend.inputDefaults = [.value(60), .value(60)]
  inactiveBackend.transports[50] = .value(kAudioDeviceTransportTypeBuiltIn)
  inactiveBackend.transports[60] = .value(kAudioDeviceTransportTypeBuiltIn)
  let (inactiveController, _) = makeBluetoothController(
    inventory: [endpoint],
    backend: inactiveBackend
  )
  let inactive = inactiveController.selectDevices(named: nil, policy: .allOrExact)![0]
  check(inactive.readAudioOutputSelectionStatus() == .notSelected,
        "an inventoried but inactive device reports output no")
  check(inactive.readAudioInputSelectionStatus() == .notSelected,
        "an inventoried but inactive device reports input no")

  let inputBackend = FakeAudioRoutingBackend()
  inputBackend.outputDefaults = [.value(50), .value(50)]
  inputBackend.inputDefaults = [.value(101), .value(101)]
  inputBackend.transports[50] = .value(kAudioDeviceTransportTypeBuiltIn)
  let (inputController, _) = makeBluetoothController(
    inventory: [endpoint],
    backend: inputBackend
  )
  let inputOnly = inputController.selectDevices(named: nil, policy: .allOrExact)![0]
  check(inputOnly.readAudioOutputSelectionStatus() == .notSelected,
        "an input-only selected device reports output no")
  check(inputOnly.readAudioInputSelectionStatus() == .selected,
        "an input-only selected device reports input yes")
}

func testBluetoothRoutingSnapshotIsLazyStableAndShared() {
  let first = NSObject()
  let second = NSObject()
  let backend = FakeAudioRoutingBackend()
  backend.outputDefaults = [.value(10), .value(10)]
  backend.inputDefaults = [.value(20), .value(20)]
  let (controller, runtime) = makeBluetoothController(
    devices: [
      (first, FakeBluetoothEntry()),
      (second, FakeBluetoothEntry()),
    ],
    backend: backend
  ) { runtime in
    runtime.mappings[10] = .value(first)
    runtime.mappings[20] = .value(second)
  }
  let devices = controller.selectDevices(named: nil, policy: .allOrExact)!
  check(backend.outputDefaultReadCount == 0, "inventory does no Core Audio route work")
  check(devices[0].readAudioOutputSelectionStatus() == .selected,
        "the exactly mapped output candidate is selected")
  check(devices[1].readAudioOutputSelectionStatus() == .notSelected,
        "a different canonical Bluetooth device is not output-selected")
  check(devices[0].readAudioInputSelectionStatus() == .notSelected,
        "a different canonical Bluetooth device is not input-selected")
  check(devices[1].readAudioInputSelectionStatus() == .selected,
        "the exactly mapped input candidate is selected")
  check(backend.outputDefaultReadCount == 2 && backend.inputDefaultReadCount == 2,
        "each direction is read before and after its mapping")
  check(runtime.mappingReads.filter { $0 == 10 || $0 == 20 } == [10, 20],
        "each direction mapping is captured once and shared by every candidate")
}

func testBluetoothRoutingFailuresAndChurnStayDirectionLocal() {
  let device = NSObject()
  let backend = FakeAudioRoutingBackend()
  backend.outputDefaults = [.failure(-50), .value(10)]
  backend.inputDefaults = [.value(20), .value(20)]
  let (controller, _) = makeBluetoothController(
    devices: [(device, FakeBluetoothEntry())],
    backend: backend
  ) { $0.mappings[20] = .value(device) }
  let selected = controller.selectDevices(named: nil, policy: .allOrExact)![0]
  check(selected.readAudioOutputSelectionStatus() == .readError,
        "a required output default read failure is a read error")
  check(selected.readAudioInputSelectionStatus() == .selected,
        "an output failure does not contaminate the input direction")

  let churnBackend = FakeAudioRoutingBackend()
  churnBackend.outputDefaults = [.value(30), .value(31)]
  let other = NSObject()
  let (churnController, churnRuntime) = makeBluetoothController(
    devices: [
      (device, FakeBluetoothEntry()),
      (other, FakeBluetoothEntry()),
    ],
    backend: churnBackend
  ) { $0.mappings[30] = .value(device) }
  let churnDevices = churnController.selectDevices(named: nil, policy: .allOrExact)!
  check(churnDevices.allSatisfy { $0.readAudioOutputSelectionStatus() == .unresolved },
        "route churn makes the shared direction snapshot unresolved")
  check(churnRuntime.mappingReads.filter { $0 == 30 }.count == 1,
        "route churn still maps at most once")
}

func testBluetoothRoutingTransportPolicyFailsClosed() {
  struct Scenario {
    let label: String
    let aggregate: AudioRoutingRead<Bool>
    let transport: AudioRoutingRead<UInt32>
    let expected: AudioDeviceSelectionObservation
    let mappingCalls: Int
  }
  let futureTransport: UInt32 = 0x7A7A_7A7A
  let scenarios: [Scenario] = [
    Scenario(label: "aggregate", aggregate: .value(true),
             transport: .value(kAudioDeviceTransportTypeBluetooth),
             expected: .notSelected, mappingCalls: 0),
    Scenario(label: "built-in", aggregate: .value(false),
             transport: .value(kAudioDeviceTransportTypeBuiltIn),
             expected: .notSelected, mappingCalls: 0),
    Scenario(label: "unknown", aggregate: .value(false),
             transport: .value(kAudioDeviceTransportTypeUnknown),
             expected: .unresolved, mappingCalls: 0),
    Scenario(label: "Bluetooth LE", aggregate: .value(false),
             transport: .value(kAudioDeviceTransportTypeBluetoothLE),
             expected: .unresolved, mappingCalls: 0),
    Scenario(label: "USB", aggregate: .value(false),
             transport: .value(kAudioDeviceTransportTypeUSB),
             expected: .unresolved, mappingCalls: 0),
    Scenario(label: "future", aggregate: .value(false),
             transport: .value(futureTransport), expected: .unresolved, mappingCalls: 0),
    Scenario(label: "transport unavailable", aggregate: .value(false),
             transport: .unavailable, expected: .unresolved, mappingCalls: 0),
    Scenario(label: "transport failure", aggregate: .value(false),
             transport: .failure(-51), expected: .readError, mappingCalls: 0),
    Scenario(label: "classic Bluetooth", aggregate: .value(false),
             transport: .value(kAudioDeviceTransportTypeBluetooth),
             expected: .selected, mappingCalls: 1),
  ]

  for scenario in scenarios {
    let device = NSObject()
    let backend = FakeAudioRoutingBackend()
    backend.outputDefaults = [.value(42), .value(42)]
    backend.aggregates[42] = scenario.aggregate
    backend.transports[42] = scenario.transport
    let (controller, runtime) = makeBluetoothController(
      devices: [(device, FakeBluetoothEntry())],
      backend: backend
    ) { $0.mappings[42] = .value(device) }
    let selected = controller.selectDevices(named: nil, policy: .allOrExact)![0]
    check(selected.readAudioOutputSelectionStatus() == scenario.expected,
          "\(scenario.label) transport follows the fail-closed policy")
    check(runtime.mappingReads.filter { $0 == 42 }.count == scenario.mappingCalls,
          "\(scenario.label) invokes the private mapper only when safe")
  }
}

func testBluetoothRequiredRouteAndClassReadStates() {
  struct Scenario {
    let label: String
    let defaults: [AudioRoutingRead<AudioDeviceID?>]
    let aggregate: AudioRoutingRead<Bool>
    let expected: AudioDeviceSelectionObservation
    let mappingCalls: Int
  }
  let scenarios: [Scenario] = [
    Scenario(label: "default unavailable", defaults: [.unavailable, .unavailable],
             aggregate: .value(false), expected: .readError, mappingCalls: 0),
    Scenario(label: "default failure", defaults: [.failure(-60), .value(80)],
             aggregate: .value(false), expected: .readError, mappingCalls: 0),
    Scenario(label: "no default", defaults: [.value(nil), .value(nil)],
             aggregate: .value(false), expected: .notSelected, mappingCalls: 0),
    Scenario(label: "default reread failure", defaults: [.value(80), .failure(-61)],
             aggregate: .value(false), expected: .readError, mappingCalls: 1),
    Scenario(label: "aggregate class failure", defaults: [.value(80), .value(80)],
             aggregate: .failure(-62), expected: .readError, mappingCalls: 0),
    Scenario(label: "aggregate class unavailable", defaults: [.value(80), .value(80)],
             aggregate: .unavailable, expected: .unresolved, mappingCalls: 0),
  ]

  for scenario in scenarios {
    let candidate = NSObject()
    let backend = FakeAudioRoutingBackend()
    backend.outputDefaults = scenario.defaults
    backend.aggregates[80] = scenario.aggregate
    let (controller, runtime) = makeBluetoothController(
      devices: [(candidate, FakeBluetoothEntry())],
      backend: backend
    ) { $0.mappings[80] = .value(candidate) }
    let device = controller.selectDevices(named: nil, policy: .allOrExact)![0]
    check(device.readAudioOutputSelectionStatus() == scenario.expected,
          "\(scenario.label) has the required observation")
    check(runtime.mappingReads.filter { $0 == 80 }.count == scenario.mappingCalls,
          "\(scenario.label) does not over-read the private mapper")
  }
}

func testBluetoothCanonicalEqualityAcceptsDistinctSystemWrappers() {
  let candidate = EqualBluetoothObject(identity: 7)
  let mappedWrapper = EqualBluetoothObject(identity: 7)
  let backend = FakeAudioRoutingBackend()
  backend.outputDefaults = [.value(90), .value(90)]
  let (controller, _) = makeBluetoothController(
    devices: [(candidate, FakeBluetoothEntry())],
    backend: backend
  ) { $0.mappings[90] = .value(mappedWrapper) }
  let device = controller.selectDevices(named: nil, policy: .allOrExact)![0]
  check(device.readAudioOutputSelectionStatus() == .selected,
        "canonical IOBluetooth equality joins distinct system wrappers")
}

func testBluetoothMapperMissingAndDifferentDeviceAreDistinguished() {
  let candidate = NSObject()
  let other = NSObject()
  for (mapping, expected, label): (AudioRoutingRead<AnyObject?>,
                                   AudioDeviceSelectionObservation, String) in [
    (.value(nil), .unresolved, "nil mapping"),
    (.unavailable, .unresolved, "missing mapper"),
    (.failure(-52), .readError, "mapper failure"),
    (.value(other), .notSelected, "different canonical Bluetooth device"),
  ] {
    let backend = FakeAudioRoutingBackend()
    backend.outputDefaults = [.value(55), .value(55)]
    let (controller, _) = makeBluetoothController(
      devices: [(candidate, FakeBluetoothEntry())],
      backend: backend
    ) { $0.mappings[55] = mapping }
    let device = controller.selectDevices(named: nil, policy: .allOrExact)![0]
    check(device.readAudioOutputSelectionStatus() == expected,
          "\(label) has the correct selection observation")
  }
}

func testActiveAVFeatureEnrichmentRequiresExactStableOutputJoin() {
  let candidate = NSObject()
  let endpoint = FakeRawDevice(
    name: "Active AirPods",
    mode: rawListeningModeValues[.transparency]!,
    conversationAwarenessEnabled: true
  )
  let backend = FakeAudioRoutingBackend()
  backend.outputDefaults = [.value(70), .value(70)]
  let probe = FakeActiveAudioEndpointProbe(
    .value(ActiveAudioEndpointBinding(audioDeviceID: 70, endpoint: endpoint))
  )
  let (controller, _) = makeBluetoothController(
    devices: [(candidate, FakeBluetoothEntry(mode: 2))],
    backend: backend,
    configureRuntime: { $0.mappings[70] = .value(candidate) },
    activeProbe: probe
  )
  let device = controller.selectDevices(named: nil, policy: .allOrExact)![0]
  check(device.readListeningModeStatus().value == .transparency,
        "an exact active join preserves the AV listening-mode read")
  check(device.readConversationAwarenessStatus().value == true,
        "an exact active join preserves the AV Conversation Awareness read")
  check(probe.captureCount == 1, "active endpoint enrichment is cached")

  let wrongProbe = FakeActiveAudioEndpointProbe(
    .value(ActiveAudioEndpointBinding(audioDeviceID: 71, endpoint: endpoint))
  )
  let (wrongController, _) = makeBluetoothController(
    devices: [(candidate, FakeBluetoothEntry(mode: 2))],
    backend: backend,
    configureRuntime: { $0.mappings[70] = .value(candidate) },
    activeProbe: wrongProbe
  )
  let wrongDevice = wrongController.selectDevices(named: nil, policy: .allOrExact)![0]
  check(wrongDevice.readListeningModeStatus().value == .noiseCancellation,
        "a wrong-device enrichment falls back to exact IOBluetooth mode state")
  check(wrongDevice.readConversationAwarenessStatus().isUnresolved,
        "a wrong-device enrichment cannot attribute Conversation Awareness")
}

func runAudioRoutingTests() {
  testCoreAudioInventoryDeduplicatesEndpointsAndAcceptsSparseMapping()
  testCoreAudioInventoryRequiresEveryPositiveEndpointGate()
  testGroupedEndpointIdentityConflictsFailClosed()
  testCoreAudioInventoryPreservesFirstGroupOccurrenceOrder()
  testCoreAudioInventoryReportsInactiveAndInputOnlySelectionExactly()
  testBluetoothRoutingSnapshotIsLazyStableAndShared()
  testBluetoothRoutingFailuresAndChurnStayDirectionLocal()
  testBluetoothRoutingTransportPolicyFailsClosed()
  testBluetoothRequiredRouteAndClassReadStates()
  testBluetoothCanonicalEqualityAcceptsDistinctSystemWrappers()
  testBluetoothMapperMissingAndDifferentDeviceAreDistinguished()
  testActiveAVFeatureEnrichmentRequiresExactStableOutputJoin()
}

private extension DeviceStatusField {
  var value: State? {
    if case let .value(value) = self { return value }
    return nil
  }

  var isUnresolved: Bool {
    if case .unresolved = self { return true }
    return false
  }

  var isReadError: Bool {
    if case .readError = self { return true }
    return false
  }
}
