import CoreAudio
import Foundation

func testListeningModeControlCandidatesReuseMappedOutputInventory() {
  let bluetoothDevice = EqualBluetoothObject(identity: 501)
  let backend = FakeAudioRoutingBackend()
  backend.outputDefaults = [.value(70), .value(70)]
  backend.inputDefaults = [.value(nil), .value(nil)]
  backend.listeningModeSupport[70] = .value(0b111)
  backend.listeningModeSettable[70] = .value(true)
  let (controller, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 70,
        bluetoothDevice: bluetoothDevice,
        name: .value("Control AirPods"),
        appleAudioDevice: .value(true),
        listeningMode: .value(3)
      )
    ],
    backend: backend
  )

  let candidates = controller.listeningModeCandidates()
  check(candidates.count == 1, "mapped output inventory supplies one control candidate")
  check(candidates.first?.displayName == "Control AirPods", "control keeps Core Audio name")
  check(candidates.first?.route == .selected, "mapped default output marks control selected")
  let transport = candidates.first?.halTransport as? HALListeningModeTransport
  check(transport?.audioDeviceID == 70, "control keeps the eligible playback endpoint")
  check(
    transport?.availableListeningModes()
      == [.transparency, .adaptive, .noiseCancellation],
    "control reads the HAL non-Off capability mask"
  )

  let inputOnlyDevice = EqualBluetoothObject(identity: 502)
  let (inputOnlyController, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 71,
        bluetoothDevice: inputOnlyDevice,
        inputStreams: .value(true),
        outputStreams: .value(false),
        name: .value("Input AirPods"),
        appleAudioDevice: .value(true),
        listeningMode: .value(3)
      )
    ]
  )
  check(
    inputOnlyController.listeningModeCandidates().isEmpty,
    "input-only endpoints never become listening-mode write targets"
  )
}

func testListeningModeControlTargetsTheEndpointThatExposesLstm() {
  let namedWrapper = EqualBluetoothObject(identity: 505)
  let controlWrapper = EqualBluetoothObject(identity: 505)
  let (controller, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 74,
        bluetoothDevice: namedWrapper,
        name: .value("Multi-Endpoint AirPods"),
        appleAudioDevice: .value(true),
        listeningModePresent: false
      ),
      FakeInventoryEndpoint(
        audioDeviceID: 75,
        bluetoothDevice: controlWrapper,
        name: .value(nil),
        appleAudioDevice: .value(true),
        listeningModePresent: true
      ),
    ],
    readStatusListeningMode: false
  )

  let candidates = controller.listeningModeCandidates()
  let transport = candidates.first?.halTransport as? HALListeningModeTransport
  check(candidates.count == 1, "one Bluetooth group produces one HAL control target")
  check(
    candidates.first?.displayName == "Multi-Endpoint AirPods",
    "the control target keeps the first named output"
  )
  check(
    transport?.audioDeviceID == 75,
    "the HAL write target uses the sibling output that exposes lstm"
  )

  let (unsupportedController, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 76,
        bluetoothDevice: namedWrapper,
        name: .value("Unsupported AirPods"),
        appleAudioDevice: .value(true),
        listeningModePresent: false
      ),
      FakeInventoryEndpoint(
        audioDeviceID: 77,
        bluetoothDevice: controlWrapper,
        name: .value(nil),
        appleAudioDevice: .value(true),
        listeningModePresent: false
      ),
    ],
    readStatusListeningMode: false
  )
  check(
    unsupportedController.listeningModeCandidates().isEmpty,
    "a Bluetooth group without lstm is not a HAL control target"
  )
}

func testListeningModeControlInventoryDefersHALStateReads() {
  let bluetoothDevice = EqualBluetoothObject(identity: 504)
  let backend = FakeAudioRoutingBackend()
  backend.outputDefaults = [.value(73), .value(73)]
  backend.inputDefaults = [.value(nil), .value(nil)]
  backend.listeningModes[73] = .value(3)
  let (controller, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 73,
        bluetoothDevice: bluetoothDevice,
        name: .value("Deferred AirPods"),
        appleAudioDevice: .value(true),
        listeningMode: .value(3)
      )
    ],
    backend: backend,
    readStatusListeningMode: false
  )
  check(backend.listeningModeReads.isEmpty, "control inventory does not read HAL state")
  let transport = controller.listeningModeCandidates().first?.halTransport
    as? HALListeningModeTransport
  check(backend.listeningModeReads.isEmpty, "candidate construction keeps HAL state lazy")
  _ = transport?.currentListeningMode()
  check(backend.listeningModeReads == [73], "chosen HAL transport performs its own state read")
}

func testListeningModeControlCandidateJoinsOnlyExactActiveEndpoint() {
  let bluetoothDevice = EqualBluetoothObject(identity: 503)
  let backend = FakeAudioRoutingBackend()
  backend.outputDefaults = [.value(72), .value(72)]
  backend.inputDefaults = [.value(nil), .value(nil)]
  let rawAVDevice = FakeRawDevice(name: "Joined AirPods")
  let activeProbe = FakeActiveAudioEndpointProbe(
    .value(ActiveAudioEndpointBinding(audioDeviceID: 72, endpoint: rawAVDevice))
  )
  let (controller, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 72,
        bluetoothDevice: bluetoothDevice,
        name: .value("Joined AirPods"),
        appleAudioDevice: .value(true),
        listeningMode: .value(3)
      )
    ],
    backend: backend,
    activeProbe: activeProbe
  )

  let candidate = controller.listeningModeCandidates().first
  check(candidate?.route == .selected, "stable mapped route proves the control selected")
  check(
    (candidate?.avTransport as? PrivateAudioDevice)?.object === rawAVDevice,
    "exact Core Audio endpoint binding supplies the AV transport"
  )

  let wrongBackend = FakeAudioRoutingBackend()
  wrongBackend.outputDefaults = [.value(72), .value(72)]
  wrongBackend.inputDefaults = [.value(nil), .value(nil)]
  let wrongProbe = FakeActiveAudioEndpointProbe(
    .value(ActiveAudioEndpointBinding(audioDeviceID: 999, endpoint: rawAVDevice))
  )
  let (wrongController, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 72,
        bluetoothDevice: bluetoothDevice,
        name: .value("Joined AirPods"),
        appleAudioDevice: .value(true),
        listeningMode: .value(3)
      )
    ],
    backend: wrongBackend,
    activeProbe: wrongProbe
  )
  let unmatched = wrongController.listeningModeCandidates().first
  check(unmatched?.avTransport == nil, "a different Core Audio endpoint never name-joins AV")

  let compositeBackend = FakeAudioRoutingBackend()
  compositeBackend.outputDefaults = [.value(900), .value(900)]
  compositeBackend.inputDefaults = [.value(nil), .value(nil)]
  compositeBackend.aggregates[900] = .value(true)
  let (compositeController, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 72,
        bluetoothDevice: bluetoothDevice,
        name: .value("Joined AirPods"),
        appleAudioDevice: .value(true),
        listeningMode: .value(3)
      )
    ],
    backend: compositeBackend,
    activeProbe: activeProbe
  )
  check(
    compositeController.listeningModeCandidates().first?.route == .unknown,
    "a composite output is unknown rather than positively unselected for control"
  )
}

func testListeningModeControlRejectsSingularAVFallbackAfterProbeMismatch() {
  let bluetoothDevice = EqualBluetoothObject(identity: 506)
  let backend = FakeAudioRoutingBackend()
  backend.outputDefaults = [.value(78), .value(78)]
  backend.inputDefaults = [.value(nil), .value(nil)]
  backend.listeningModeSupport[78] = .value(0b111)
  backend.listeningModeSettable[78] = .value(true)
  backend.listeningModeWriteResult = .success

  let unrelatedRawAVDevice = FakeRawDevice(name: "Unrelated AirPods")
  let mismatchedProbe = FakeActiveAudioEndpointProbe(
    .value(
      ActiveAudioEndpointBinding(
        audioDeviceID: 999,
        endpoint: unrelatedRawAVDevice
      )
    )
  )
  let (controller, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 78,
        bluetoothDevice: bluetoothDevice,
        name: .value("Selected AirPods"),
        appleAudioDevice: .value(true),
        listeningMode: .value(3)
      )
    ],
    backend: backend,
    activeProbe: mismatchedProbe,
    readStatusListeningMode: false
  )
  let unrelatedAV = PrivateAudioDevice.compatible(
    object: unrelatedRawAVDevice,
    sources: [.contextSingular],
    index: 0,
    logger: DebugLogger(enabled: false)
  )!
  let coordinator = ListeningModeCoordinator(
    avDevices: [unrelatedAV],
    halCandidates: controller.listeningModeCandidates(),
    logger: DebugLogger(enabled: false)
  )
  let invocation = try! parseInvocation(["lm", "set", "adaptive"])
  _ = CommandExecution.executeListeningMode(
    invocation,
    resolveSession: { command, name, _ in
      coordinator.resolve(
        command: command,
        named: name,
        chooseAmbiguous: { _ in .unavailable }
      )
    }
  )

  check(
    unrelatedRawAVDevice.listeningModeSetCount == 0,
    "a mismatched enrichment probe never writes through the singular AV endpoint"
  )
}

func testListeningModeAllowOffCorrelationIsLazyAndExact() {
  let clock = Date(timeIntervalSince1970: 2_000_001_000)
  let bluetoothDevice = EqualBluetoothObject(identity: 81)
  let backend = FakeAudioRoutingBackend()
  backend.deviceUIDs[81] = .value("exact-core-audio-uid")
  backend.listeningModes[81] = .value(2)
  backend.listeningModeSupport[81] = .value(0b111)
  let cache = InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xC7, count: 32),
    now: { clock }
  )!
  _ = cache.storePositiveObservation(rawDeviceUID: "exact-core-audio-uid")
  let (controller, _) = makeBluetoothController(
    inventory: [
      FakeInventoryEndpoint(
        audioDeviceID: 81,
        bluetoothDevice: bluetoothDevice,
        name: .value("Lazy AirPods"),
        appleAudioDevice: .value(true)
      )
    ],
    backend: backend,
    readStatusListeningMode: false,
    allowOffCache: cache
  )

  check(backend.deviceUIDReads.isEmpty, "control discovery never reads a cache identifier")
  let candidates = controller.listeningModeCandidates()
  check(backend.deviceUIDReads.isEmpty, "candidate construction keeps UID correlation lazy")

  let coordinator = ListeningModeCoordinator(
    candidates: candidates,
    logger: DebugLogger(enabled: false)
  )
  let listInvocation = try! parseInvocation(["lm", "list", "--json"])
  let listOutcome = CommandExecution.executeListeningMode(
    listInvocation,
    resolveSession: { command, name, _ in
      coordinator.resolve(
        command: command,
        named: name,
        chooseAmbiguous: { _ in .unavailable }
      )
    }
  )
  check(backend.deviceUIDReads == [81], "a cache-relevant selected operation reads one exact UID")
  check(
    (listOutcome.payload["supportedListeningModes"] as? [String])?.contains("off")
      == true,
    "the exact endpoint UID correlates its cached positive evidence"
  )

  backend.resetDeviceUIDReads()
  let getInvocation = try! parseInvocation(["lm", "get"])
  _ = CommandExecution.executeListeningMode(
    getInvocation,
    resolveSession: { command, name, _ in
      coordinator.resolve(
        command: command,
        named: name,
        chooseAmbiguous: { _ in .unavailable }
      )
    }
  )
  check(backend.deviceUIDReads.isEmpty, "HAL current-mode get never reads the UID cache key")
}

func runHALListeningModeCandidateTests() {
  testListeningModeControlCandidatesReuseMappedOutputInventory()
  testListeningModeControlTargetsTheEndpointThatExposesLstm()
  testListeningModeControlInventoryDefersHALStateReads()
  testListeningModeControlCandidateJoinsOnlyExactActiveEndpoint()
  testListeningModeControlRejectsSingularAVFallbackAfterProbeMismatch()
  testListeningModeAllowOffCorrelationIsLazyAndExact()
}
