import CoreAudio
import Foundation
import Testing

@testable import AirPodsControlCore


@Suite("Audio routing")
struct AudioRoutingTests {

  @Test
  func coreAudioControllerCreationPreservesInventoryReadOutcome() throws {
    let unavailableBackend = FakeAudioRoutingBackend()
    let (unavailableResult, _) = makeBluetoothControllerResult(
      inventory: [],
      backend: unavailableBackend,
      inventoryRead: .unavailable
    )
    guard case .unavailable = unavailableResult else {
      Issue.record("unavailable Core Audio inventory stays unavailable")
      return
    }
    #expect(
      unavailableBackend.audioDeviceReadCount == 1,
      "unavailable inventory is read exactly once"
    )

    let failureStatus: OSStatus = -7_001
    let failureBackend = FakeAudioRoutingBackend()
    let (failureResult, _) = makeBluetoothControllerResult(
      inventory: [],
      backend: failureBackend,
      inventoryRead: .failure(failureStatus)
    )
    guard case let .readError(status) = failureResult else {
      Issue.record("failed Core Audio inventory becomes a typed read error")
      return
    }
    #expect(status == failureStatus, "inventory OSStatus is retained for diagnostics")
    #expect(
      failureBackend.audioDeviceReadCount == 1,
      "failed inventory is read exactly once"
    )

    let emptyBackend = FakeAudioRoutingBackend()
    let (emptyResult, _) = makeBluetoothControllerResult(
      inventory: [],
      backend: emptyBackend,
      inventoryRead: .value([])
    )
    guard case let .success(controller) = emptyResult else {
      Issue.record("an answered empty inventory creates an empty controller")
      return
    }
    guard case .noDevice = controller.resolveDevices(named: nil, policy: .allOrExact) else {
      Issue.record("an answered empty inventory creates an empty controller")
      return
    }
    #expect(
      emptyBackend.audioDeviceReadCount == 1,
      "successful inventory is read exactly once"
    )
  }

  @Test
  func coreAudioInventoryDeduplicatesEndpointsAndAcceptsSparseMapping() throws {
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
    #expect(devices?.count == 1,
          "input and output endpoints mapping to one canonical object form one record")
    #expect(devices?.first?.name == "Office AirPods",
          "the output endpoint supplies the deterministic Core Audio display name")
    #expect(devices?.first?.availableListeningModes() == [],
          "the status-only adapter does not advertise modes for write commands")
    #expect(devices?.first?.readListeningModeStatus().value == .transparency,
          "HAL current mode is preferred over a sparse mapped object")
    #expect(devices?.first?.readConversationAwarenessStatus().isUnresolved == true,
          "a sparse mapped object reports unknown Conversation Awareness honestly")
    #expect(runtime.mappingReads == [101, 202],
          "each positively gated Core Audio endpoint is mapped exactly once")
    #expect(backend.audioDeviceReadCount == 1, "the public device inventory is captured once")
    #expect(
      controller.selectDevices(named: "office airpods", policy: .allOrExact)?.count == 1,
      "status exact-name selection uses the Core Audio name case insensitively"
    )
  }

  @Test
  func coreAudioStatusPlacementJourneyUsesGroupedEvidenceOnlyForStatus() throws {
    let stablePlacement = BluetoothEarPlacement(left: .inEar, right: .inCase)
    let conflictingPlacement = BluetoothEarPlacement(left: .outOfEar, right: .inEar)
    let inventory =
      placementGroup(
        named: "Stable Placement",
        identity: 111,
        startingAt: 111,
        reads: [.value(stablePlacement), .value(stablePlacement)]
      )
      + placementGroup(
        named: "Conflicting Placement",
        identity: 113,
        startingAt: 113,
        reads: [.value(stablePlacement), .value(conflictingPlacement)]
      )
      + placementGroup(
        named: "Unknown Placement",
        identity: 115,
        startingAt: 115,
        reads: [.value(stablePlacement), .unknown]
      )
      + placementGroup(
        named: "Failed Placement",
        identity: 117,
        startingAt: 117,
        reads: [.value(stablePlacement), .failure(-7_111)]
      )
      + placementGroup(
        named: "Unavailable Placement",
        identity: 119,
        startingAt: 119,
        reads: [.unavailable]
      )
    let backend = FakeAudioRoutingBackend()
    let (controller, _) = makeBluetoothController(
      inventory: inventory,
      backend: backend
    )

    let devices = controller.selectDevices(named: nil, policy: .allOrExact)!
    #expect(
      devices.compactMap(\.name) == [
        "Stable Placement",
        "Conflicting Placement",
        "Unknown Placement",
        "Failed Placement",
        "Unavailable Placement",
      ],
      "status keeps the first occurrence order of grouped placement evidence"
    )
    #expect(
      placementStatusValue(devices[0].readInEarPlacementStatus()) == stablePlacement,
      "matching endpoint evidence produces one typed placement"
    )
    #expect(
      placementStatusValue(devices[0].readInEarPlacementStatus()) == stablePlacement,
      "the captured placement remains stable across repeated status access"
    )
    #expect(
      devices[1].readInEarPlacementStatus().isUnresolved
        && devices[2].readInEarPlacementStatus().isUnresolved,
      "conflicting or unknown endpoint evidence remains unresolved"
    )
    #expect(
      devices[3].readInEarPlacementStatus().isReadError,
      "a failed sibling prevents a definitive group placement"
    )
    #expect(
      devices[4].readInEarPlacementStatus().isUnsupported,
      "a group without placement evidence remains unsupported"
    )
    #expect(
      backend.inEarPlacementReads.count == inventory.count
        && Set(backend.inEarPlacementReads).count == inventory.count,
      "status captures placement once from every eligible endpoint"
    )

    let controlBackend = FakeAudioRoutingBackend()
    let (controlController, _) = makeBluetoothController(
      inventory: placementGroup(
        named: "Control Placement",
        identity: 120,
        startingAt: 120,
        reads: [.value(stablePlacement)]
      ),
      backend: controlBackend,
      readStatusListeningMode: false,
      readStatusInEarPlacement: false
    )
    let controlDevice = controlController.selectDevices(
      named: nil,
      policy: .allOrExact
    )![0]
    #expect(
      controlDevice.readInEarPlacementStatus().isUnsupported
        && controlBackend.inEarPlacementReads.isEmpty,
      "non-status discovery neither captures nor exposes placement"
    )
  }

  @Test
  func coreAudioInventoryRequiresEveryPositiveEndpointGate() throws {
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
    #expect(
      devices?.map(\.name)
        == ["Valid AirPods", "Other AirPods", "Valid Beats", "Feature Unknown"],
      "only endpoints with a positive HAL Apple-audio signal or exact manufacturer fallback survive"
    )
    #expect(devices?.last?.readListeningModeStatus().isReadError == true,
          "a failed advertised HAL current-mode read is retained as a read error")
  }

  @Test
  func groupedEndpointIdentityConflictsFailClosed() throws {
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
    #expect(
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
    #expect(neutral?.readListeningModeStatus().value == .transparency,
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
    #expect(future.readListeningModeStatus().isUnresolved,
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
    #expect(mixedFutureDevice.readListeningModeStatus().isUnresolved,
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
    #expect(conflicted.readListeningModeStatus().isUnresolved,
          "different recognized HAL modes stay unresolved instead of falling back")
  }

  @Test
  func coreAudioInventoryPreservesFirstGroupOccurrenceOrder() throws {
    let first = NSObject()
    let second = NSObject()
    let (controller, _) = makeBluetoothController(inventory: [
      FakeInventoryEndpoint(audioDeviceID: 900, bluetoothDevice: first,
                            name: .value("First Seen"), appleAudioDevice: .value(true)),
      FakeInventoryEndpoint(audioDeviceID: 1, bluetoothDevice: second,
                            name: .value("Second Seen"), appleAudioDevice: .value(true)),
    ])
    #expect(
      controller.selectDevices(named: nil, policy: .allOrExact)?.map(\.name)
        == ["First Seen", "Second Seen"],
      "record order follows first public inventory occurrence, not opaque object IDs"
    )
  }

  @Test
  func coreAudioInventoryReportsInactiveAndInputOnlySelectionExactly() throws {
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
    #expect(inactive.readAudioOutputSelectionStatus() == .notSelected,
          "an inventoried but inactive device reports output no")
    #expect(inactive.readAudioInputSelectionStatus() == .notSelected,
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
    #expect(inputOnly.readAudioOutputSelectionStatus() == .notSelected,
          "an input-only selected device reports output no")
    #expect(inputOnly.readAudioInputSelectionStatus() == .selected,
          "an input-only selected device reports input yes")
  }

  @Test
  func bluetoothRoutingSnapshotIsLazyStableAndShared() throws {
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
    #expect(backend.outputDefaultReadCount == 0, "inventory does no Core Audio route work")
    #expect(devices[0].readAudioOutputSelectionStatus() == .selected,
          "the exactly mapped output candidate is selected")
    #expect(devices[1].readAudioOutputSelectionStatus() == .notSelected,
          "a different canonical Bluetooth device is not output-selected")
    #expect(devices[0].readAudioInputSelectionStatus() == .notSelected,
          "a different canonical Bluetooth device is not input-selected")
    #expect(devices[1].readAudioInputSelectionStatus() == .selected,
          "the exactly mapped input candidate is selected")
    #expect(backend.outputDefaultReadCount == 2 && backend.inputDefaultReadCount == 2,
          "each direction is read before and after its mapping")
    #expect(runtime.mappingReads.filter { $0 == 10 || $0 == 20 } == [10, 20],
          "each direction mapping is captured once and shared by every candidate")
  }

  @Test
  func bluetoothRoutingFailuresAndChurnStayDirectionLocal() throws {
    let device = NSObject()
    let backend = FakeAudioRoutingBackend()
    backend.outputDefaults = [.failure(-50), .value(10)]
    backend.inputDefaults = [.value(20), .value(20)]
    let (controller, _) = makeBluetoothController(
      devices: [(device, FakeBluetoothEntry())],
      backend: backend
    ) { $0.mappings[20] = .value(device) }
    let selected = controller.selectDevices(named: nil, policy: .allOrExact)![0]
    #expect(selected.readAudioOutputSelectionStatus() == .readError,
          "a required output default read failure is a read error")
    #expect(selected.readAudioInputSelectionStatus() == .selected,
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
    #expect(churnDevices.allSatisfy { $0.readAudioOutputSelectionStatus() == .unresolved },
          "route churn makes the shared direction snapshot unresolved")
    #expect(churnRuntime.mappingReads.filter { $0 == 30 }.count == 1,
          "route churn still maps at most once")
  }

  @Test
  func bluetoothRoutingTransportPolicyFailsClosed() throws {
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
      #expect(selected.readAudioOutputSelectionStatus() == scenario.expected,
            "\(scenario.label) transport follows the fail-closed policy")
      #expect(runtime.mappingReads.filter { $0 == 42 }.count == scenario.mappingCalls,
            "\(scenario.label) invokes the private mapper only when safe")
    }
  }

  @Test
  func bluetoothRequiredRouteAndClassReadStates() throws {
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
      #expect(device.readAudioOutputSelectionStatus() == scenario.expected,
            "\(scenario.label) has the required observation")
      #expect(runtime.mappingReads.filter { $0 == 80 }.count == scenario.mappingCalls,
            "\(scenario.label) does not over-read the private mapper")
    }
  }

  @Test
  func bluetoothCanonicalEqualityAcceptsDistinctSystemWrappers() throws {
    let candidate = EqualBluetoothObject(identity: 7)
    let mappedWrapper = EqualBluetoothObject(identity: 7)
    let backend = FakeAudioRoutingBackend()
    backend.outputDefaults = [.value(90), .value(90)]
    let (controller, _) = makeBluetoothController(
      devices: [(candidate, FakeBluetoothEntry())],
      backend: backend
    ) { $0.mappings[90] = .value(mappedWrapper) }
    let device = controller.selectDevices(named: nil, policy: .allOrExact)![0]
    #expect(device.readAudioOutputSelectionStatus() == .selected,
          "canonical IOBluetooth equality joins distinct system wrappers")
  }

  @Test
  func bluetoothMapperMissingAndDifferentDeviceAreDistinguished() throws {
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
      #expect(device.readAudioOutputSelectionStatus() == expected,
            "\(label) has the correct selection observation")
    }
  }

  @Test
  func activeAVFeatureEnrichmentRequiresExactStableOutputJoin() throws {
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
    #expect(device.readListeningModeStatus().value == .transparency,
          "an exact active join preserves the AV listening-mode read")
    #expect(device.readConversationAwarenessStatus().value == true,
          "an exact active join preserves the AV Conversation Awareness read")
    #expect(probe.captureCount == 1, "active endpoint enrichment is cached")

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
    #expect(wrongDevice.readListeningModeStatus().value == .noiseCancellation,
          "a wrong-device enrichment falls back to exact IOBluetooth mode state")
    #expect(wrongDevice.readConversationAwarenessStatus().isUnresolved,
          "a wrong-device enrichment cannot attribute Conversation Awareness")
  }
}

private func placementGroup(
  named name: String,
  identity: Int,
  startingAt firstDeviceID: AudioDeviceID,
  reads: [BluetoothEarPlacementRead]
) -> [FakeInventoryEndpoint] {
  reads.enumerated().map { index, read in
    FakeInventoryEndpoint(
      audioDeviceID: firstDeviceID + AudioDeviceID(index),
      bluetoothDevice: EqualBluetoothObject(identity: identity),
      inputStreams: .value(index != 0),
      outputStreams: .value(index == 0),
      name: .value(index == 0 ? name : nil),
      appleAudioDevice: .value(true),
      inEarPlacement: read
    )
  }
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
