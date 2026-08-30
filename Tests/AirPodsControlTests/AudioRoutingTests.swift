import CoreAudio
import Foundation

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

func testCoreAudioStatusReadsPlacementOnlyForStatusAndPreservesTypedState() {
  let device = NSObject()
  let backend = FakeAudioRoutingBackend()
  let placement = BluetoothEarPlacement(left: .inEar, right: .outOfEar)
  let (controller, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 111,
        bluetoothDevice: device,
        name: .value("Placement AirPods"),
        appleAudioDevice: .value(true),
        inEarPlacement: .value(placement)
      ),
    ],
    backend: backend
  )
  let statusDevice = controller.selectDevices(named: nil, policy: .allOrExact)![0]
  check(
    placementStatusValue(statusDevice.readInEarPlacementStatus()) == placement,
    "status exposes the typed HAL placement value"
  )
  check(
    backend.inEarPlacementReads == [111],
    "status reads placement once per eligible endpoint"
  )

  let controlBackend = FakeAudioRoutingBackend()
  let (controlController, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 112,
        bluetoothDevice: device,
        name: .value("Control AirPods"),
        appleAudioDevice: .value(true),
        inEarPlacement: .value(placement)
      ),
    ],
    backend: controlBackend,
    readStatusListeningMode: false
  )
  let controlDevice = controlController.selectDevices(
    named: nil,
    policy: .allOrExact
  )![0]
  check(
    controlDevice.readInEarPlacementStatus().isUnsupported,
    "control discovery does not expose a placement snapshot"
  )
  check(
    controlBackend.inEarPlacementReads.isEmpty,
    "non-status discovery never queries HAL placement"
  )
}

func testCoreAudioStatusPlacementGroupsFailClosed() {
  let same = EqualBluetoothObject(identity: 113)
  let sameInput = EqualBluetoothObject(identity: 113)
  let samePlacement = BluetoothEarPlacement(left: .inEar, right: .inCase)
  let sameBackend = FakeAudioRoutingBackend()
  let (sameController, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 113,
        bluetoothDevice: same,
        name: .value("Same Placement"),
        appleAudioDevice: .value(true),
        inEarPlacement: .value(samePlacement)
      ),
      FakeInventoryEndpoint(
        audioDeviceID: 114,
        bluetoothDevice: sameInput,
        inputStreams: .value(true),
        outputStreams: .value(false),
        appleAudioDevice: .value(true),
        inEarPlacement: .value(samePlacement)
      ),
    ],
    backend: sameBackend
  )
  let sameDevice = sameController.selectDevices(named: nil, policy: .allOrExact)![0]
  check(
    placementStatusValue(sameDevice.readInEarPlacementStatus()) == samePlacement,
    "identical endpoint placement evidence is retained"
  )
  check(
    placementStatusValue(sameDevice.readInEarPlacementStatus()) == samePlacement,
    "placement status remains stable across repeated access"
  )
  check(
    sameBackend.inEarPlacementReads == [113, 114],
    "every eligible endpoint contributes one placement read"
  )

  let conflict = EqualBluetoothObject(identity: 115)
  let conflictInput = EqualBluetoothObject(identity: 115)
  let (conflictController, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(
      audioDeviceID: 115,
      bluetoothDevice: conflict,
      name: .value("Conflicting Placement"),
      appleAudioDevice: .value(true),
      inEarPlacement: .value(
        BluetoothEarPlacement(left: .inEar, right: .outOfEar)
      )
    ),
    FakeInventoryEndpoint(
      audioDeviceID: 116,
      bluetoothDevice: conflictInput,
      inputStreams: .value(true),
      outputStreams: .value(false),
      appleAudioDevice: .value(true),
      inEarPlacement: .value(
        BluetoothEarPlacement(left: .outOfEar, right: .inEar)
      )
    ),
  ])
  let conflictDevice = conflictController.selectDevices(
    named: nil,
    policy: .allOrExact
  )![0]
  check(
    conflictDevice.readInEarPlacementStatus().isUnresolved,
    "conflicting endpoint placement evidence is unresolved"
  )

  let readErrorDevice = NSObject()
  let (readErrorController, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(
      audioDeviceID: 117,
      bluetoothDevice: readErrorDevice,
      name: .value("Placement Error"),
      appleAudioDevice: .value(true),
      inEarPlacement: .failure(-7_111)
    ),
  ])
  let readError = readErrorController.selectDevices(
    named: nil,
    policy: .allOrExact
  )![0]
  check(
    readError.readInEarPlacementStatus().isReadError,
    "a HAL placement read error remains field-specific"
  )

  let valueAndFailure = EqualBluetoothObject(identity: 118)
  let valueAndFailureInput = EqualBluetoothObject(identity: 118)
  let valueAndFailurePlacement = BluetoothEarPlacement(
    left: .inCase,
    right: .outOfEar
  )
  let (valueAndFailureController, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(
      audioDeviceID: 118,
      bluetoothDevice: valueAndFailure,
      name: .value("Placement Partial Error"),
      appleAudioDevice: .value(true),
      inEarPlacement: .value(valueAndFailurePlacement)
    ),
    FakeInventoryEndpoint(
      audioDeviceID: 119,
      bluetoothDevice: valueAndFailureInput,
      inputStreams: .value(true),
      outputStreams: .value(false),
      appleAudioDevice: .value(true),
      inEarPlacement: .failure(-7_112)
    ),
  ])
  let valueAndFailureDevice = valueAndFailureController.selectDevices(
    named: nil,
    policy: .allOrExact
  )![0]
  check(
    valueAndFailureDevice.readInEarPlacementStatus().isReadError,
    "a failed sibling prevents a definitive placement value"
  )

  let unknownAndFailure = EqualBluetoothObject(identity: 120)
  let unknownAndFailureInput = EqualBluetoothObject(identity: 120)
  let (unknownAndFailureController, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(
      audioDeviceID: 120,
      bluetoothDevice: unknownAndFailure,
      name: .value("Placement Unknown Partial Error"),
      appleAudioDevice: .value(true),
      inEarPlacement: .unknown
    ),
    FakeInventoryEndpoint(
      audioDeviceID: 121,
      bluetoothDevice: unknownAndFailureInput,
      inputStreams: .value(true),
      outputStreams: .value(false),
      appleAudioDevice: .value(true),
      inEarPlacement: .failure(-7_114)
    ),
  ])
  let unknownAndFailureDevice = unknownAndFailureController.selectDevices(
    named: nil,
    policy: .allOrExact
  )![0]
  check(
    unknownAndFailureDevice.readInEarPlacementStatus().isReadError,
    "a failed sibling is not hidden by unknown placement evidence"
  )

  let conflictAndFailure = EqualBluetoothObject(identity: 122)
  let conflictAndFailureInput = EqualBluetoothObject(identity: 122)
  let conflictAndFailureSecondInput = EqualBluetoothObject(identity: 122)
  let (conflictAndFailureController, _) = makeBluetoothController(inventory: [
    FakeInventoryEndpoint(
      audioDeviceID: 122,
      bluetoothDevice: conflictAndFailure,
      name: .value("Placement Conflict Partial Error"),
      appleAudioDevice: .value(true),
      inEarPlacement: .value(
        BluetoothEarPlacement(left: .inEar, right: .outOfEar)
      )
    ),
    FakeInventoryEndpoint(
      audioDeviceID: 123,
      bluetoothDevice: conflictAndFailureInput,
      inputStreams: .value(true),
      outputStreams: .value(false),
      appleAudioDevice: .value(true),
      inEarPlacement: .value(
        BluetoothEarPlacement(left: .outOfEar, right: .inEar)
      )
    ),
    FakeInventoryEndpoint(
      audioDeviceID: 124,
      bluetoothDevice: conflictAndFailureSecondInput,
      inputStreams: .value(true),
      outputStreams: .value(false),
      appleAudioDevice: .value(true),
      inEarPlacement: .failure(-7_115)
    ),
  ])
  let conflictAndFailureDevice = conflictAndFailureController.selectDevices(
    named: nil,
    policy: .allOrExact
  )![0]
  check(
    conflictAndFailureDevice.readInEarPlacementStatus().isReadError,
    "a failed sibling is not hidden by conflicting placement evidence"
  )
}

func testCoreAudioStatusPlacementMapsUnavailableUnknownAndFailure() {
  let scenarios: [(String, BluetoothEarPlacementRead, String)] = [
    ("unavailable", .unavailable, "unsupported"),
    ("unknown", .unknown, "unresolved"),
    ("failure", .failure(-7_113), "read-error"),
  ]
  for (index, scenario) in scenarios.enumerated() {
    let label = scenario.0
    let placement = scenario.1
    let expected = scenario.2
    let candidate = NSObject()
    let (controller, _) = makeBluetoothController(inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: AudioDeviceID(120 + index),
        bluetoothDevice: candidate,
        name: .value("Placement \(label)"),
        appleAudioDevice: .value(true),
        inEarPlacement: placement
      ),
    ])
    let device = controller.selectDevices(named: nil, policy: .allOrExact)![0]
    let status = device.readInEarPlacementStatus()
    let matches: Bool
    switch expected {
    case "unsupported": matches = status.isUnsupported
    case "unresolved": matches = status.isUnresolved
    case "read-error": matches = status.isReadError
    default: matches = false
    }
    check(matches, "a HAL placement \(label) maps to \(expected)")
  }
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
             aggregate: .value(false), expected: .unresolved, mappingCalls: 0),
    Scenario(label: "default failure", defaults: [.failure(-60), .value(80)],
             aggregate: .value(false), expected: .readError, mappingCalls: 0),
    Scenario(label: "no default", defaults: [.value(nil), .value(nil)],
             aggregate: .value(false), expected: .notSelected, mappingCalls: 0),
    Scenario(label: "default reread unavailable", defaults: [.value(80), .unavailable],
             aggregate: .value(false), expected: .unresolved, mappingCalls: 1),
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
  testCoreAudioStatusReadsPlacementOnlyForStatusAndPreservesTypedState()
  testCoreAudioStatusPlacementGroupsFailClosed()
  testCoreAudioStatusPlacementMapsUnavailableUnknownAndFailure()
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

  var isUnsupported: Bool {
    if case .unsupported = self { return true }
    return false
  }
}

private func placementStatusValue(
  _ status: DeviceStatusField<BluetoothEarPlacement>
) -> BluetoothEarPlacement? {
  if case let .value(value) = status { return value }
  return nil
}
