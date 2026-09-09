import CoreAudio
import Darwin
import Foundation

private let bluetoothListeningModeSelector = NSSelectorFromString("listeningMode")
private let bluetoothDeviceForAudioIDSelector = NSSelectorFromString("bluetoothDevice:")
private let statusAVDeviceIDSelector = NSSelectorFromString("deviceID")
private let statusAVCurrentModeSelector = NSSelectorFromString(
  "currentBluetoothListeningMode"
)
private let statusAVSupportsCASelector = NSSelectorFromString(
  "supportsConversationDetection"
)
private let statusAVCAEnabledSelector = NSSelectorFromString(
  "isConversationDetectionEnabled"
)
private let statusListeningModesByRawValue: [String: ListeningMode] = [
  "AVOutputDeviceBluetoothListeningModeNormal": .off,
  "AVOutputDeviceBluetoothListeningModeAudioTransparency": .transparency,
  "AVOutputDeviceBluetoothListeningModeAutomatic": .adaptive,
  "AVOutputDeviceBluetoothListeningModeActiveNoiseCancellation": .noiseCancellation,
]

enum BluetoothRuntimeRead<Value> {
  case value(Value)
  case unavailable
}

protocol BluetoothAudioRuntime: BluetoothAudioDeviceMappingBackend {
  func listeningMode(_ device: AnyObject) -> BluetoothRuntimeRead<UInt8>
}

@objc private protocol IOBluetoothDeviceScalarShim {
  @objc(listeningMode) func listeningModeValue() -> UInt8
}

@objc private protocol IOBluetoothAudioManagerClassShim {
  @objc(bluetoothDevice:) func bluetoothDeviceValue(_ audioDeviceID: UInt32) -> AnyObject?
}

@objc private protocol StatusConversationAwarenessSupportShim {
  @objc(supportsConversationDetection) func supportsConversationAwareness() -> Bool
}

@objc private protocol StatusConversationAwarenessStateShim {
  @objc(isConversationDetectionEnabled) func conversationAwarenessEnabled() -> Bool
}

final class SystemBluetoothAudioRuntime: BluetoothAudioRuntime {
  private let deviceClass: AnyClass?
  private let audioManagerClass: AnyObject?
  private let logger: DebugLogger

  init(logger: DebugLogger) {
    self.logger = logger
    let framework = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
    guard dlopen(framework, RTLD_NOW) != nil else {
      logger.warning("bluetooth.framework", "unavailable")
      deviceClass = nil
      audioManagerClass = nil
      return
    }
    deviceClass = NSClassFromString("IOBluetoothDevice")
    audioManagerClass = NSClassFromString("IOBluetoothAudioManager") as AnyObject?
    logger.debug("bluetooth.device_class", deviceClass == nil ? "unavailable" : "available")
    logger.debug(
      "bluetooth.audio_manager_class",
      audioManagerClass == nil ? "unavailable" : "available"
    )
  }

  func listeningMode(_ device: AnyObject) -> BluetoothRuntimeRead<UInt8> {
    scalar(device, selector: bluetoothListeningModeSelector) { $0.listeningModeValue() }
  }

  func bluetoothDevice(
    for audioDeviceID: AudioDeviceID
  ) -> AudioRoutingRead<AnyObject?> {
    guard let audioManagerClass,
          audioManagerClass.responds(to: bluetoothDeviceForAudioIDSelector)
    else { return .unavailable }
    let shim = unsafeBitCast(audioManagerClass, to: IOBluetoothAudioManagerClassShim.self)
    guard let device = shim.bluetoothDeviceValue(audioDeviceID) else {
      return .value(nil)
    }
    guard isExpectedDevice(device) else {
      logger.debug("routing.bluetooth_mapping_type", "unexpected")
      return .unavailable
    }
    return .value(device)
  }

  private func scalar<Value>(
    _ device: AnyObject,
    selector: Selector,
    read: (IOBluetoothDeviceScalarShim) -> Value
  ) -> BluetoothRuntimeRead<Value> {
    guard isExpectedDevice(device), device.responds(to: selector) else {
      return .unavailable
    }
    let shim = unsafeBitCast(device, to: IOBluetoothDeviceScalarShim.self)
    return .value(read(shim))
  }

  private func isExpectedDevice(_ device: AnyObject) -> Bool {
    guard let deviceClass, let object = device as? NSObject else { return false }
    return object.isKind(of: deviceClass)
  }
}

private let activeOutputDeviceSelector = NSSelectorFromString("outputDevice")
private let activeAssociatedDeviceIDSelector = NSSelectorFromString(
  "associatedAudioDeviceID"
)
private let maximumActiveRouteIdentifierLength = 512

// This is optional enrichment, not inventory or routing evidence. It returns
// a singular AV endpoint only after the context route is stable and its
// associated NSString is translated by public Core Audio.
struct SystemActiveAudioEndpointProbe: ActiveAudioEndpointProbing {
  let outputContext: AnyObject

  func capture() -> ActiveAudioEndpointCapture {
    guard let before = endpointAndIdentifier(),
          outputContext.responds(to: activeAssociatedDeviceIDSelector),
          let rawAssociatedID = outputContext.perform(activeAssociatedDeviceIDSelector)?
          .takeUnretainedValue(),
          let associatedUID = rawAssociatedID as? String,
          !associatedUID.isEmpty,
          associatedUID.utf8.count <= maximumActiveRouteIdentifierLength,
          let after = endpointAndIdentifier()
    else { return .unavailable }
    guard before.identifier == after.identifier else { return .routeChanged }

    switch translateDeviceUID(associatedUID) {
    case let .value(.some(deviceID)):
      return .value(
        ActiveAudioEndpointBinding(audioDeviceID: deviceID, endpoint: before.endpoint)
      )
    case .value(nil), .unavailable:
      return .unavailable
    case let .failure(status):
      return .failure(status)
    }
  }

  private func endpointAndIdentifier() -> (endpoint: AnyObject, identifier: String)? {
    guard outputContext.responds(to: activeOutputDeviceSelector),
          let endpoint = outputContext.perform(activeOutputDeviceSelector)?
          .takeUnretainedValue(),
          endpoint.responds(to: statusAVDeviceIDSelector),
          let identifier = endpoint.perform(statusAVDeviceIDSelector)?
          .takeUnretainedValue() as? String,
          !identifier.isEmpty,
          identifier.utf8.count <= maximumActiveRouteIdentifierLength
    else { return nil }
    return (endpoint, identifier)
  }

  private func translateDeviceUID(
    _ uid: String
  ) -> AudioRoutingRead<AudioDeviceID?> {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceUID = uid as CFString
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
      return .unavailable
    }
    let status = withUnsafePointer(to: &deviceUID) { qualifier in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<CFString>.size),
        qualifier,
        &dataSize,
        &deviceID
      )
    }
    guard status == noErr else { return .failure(status) }
    guard dataSize == MemoryLayout<AudioDeviceID>.size else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    return .value(deviceID == kAudioObjectUnknown ? nil : deviceID)
  }
}

final class IOBluetoothStatusDevice: AudioDeviceStatusReading {
  let object: AnyObject
  let name: String?
  private let coreAudioListeningMode: CoreAudioListeningModeObservation
  private let coreAudioInEarPlacement: CoreAudioInEarPlacementObservation
  private let runtime: any BluetoothAudioRuntime
  private let routingObserver: AudioRoutingObserver

  init(
    object: AnyObject,
    name: String,
    coreAudioListeningMode: CoreAudioListeningModeObservation,
    coreAudioInEarPlacement: CoreAudioInEarPlacementObservation,
    runtime: any BluetoothAudioRuntime,
    routingObserver: AudioRoutingObserver
  ) {
    self.object = object
    self.name = name
    self.coreAudioListeningMode = coreAudioListeningMode
    self.coreAudioInEarPlacement = coreAudioInEarPlacement
    self.runtime = runtime
    self.routingObserver = routingObserver
  }

  func readListeningModeStatus() -> DeviceStatusField<ListeningMode> {
    if let endpoint = routingObserver.activeFeatureEndpoint(for: object),
       endpoint.responds(to: statusAVCurrentModeSelector),
       let rawMode = endpoint.perform(statusAVCurrentModeSelector)?
       .takeUnretainedValue() as? String
    {
      guard let mode = statusListeningModesByRawValue[rawMode] else {
        return .unresolved
      }
      return .value(mode)
    }

    switch coreAudioListeningMode {
    case let .value(mode): return .value(mode)
    case .unrecognized, .conflict: return .unresolved
    case .unavailable, .readFailure: break
    }

    if case let .value(rawMode) = runtime.listeningMode(object),
       let mode = bluetoothModeByRawValue[UInt32(rawMode)]
    {
      return .value(mode)
    }
    if case .readFailure = coreAudioListeningMode {
      return .readError
    }
    return .unresolved
  }

  func readConversationAwarenessStatus() -> DeviceStatusField<Bool> {
    guard let endpoint = routingObserver.activeFeatureEndpoint(for: object) else {
      return .unresolved
    }
    guard endpoint.responds(to: statusAVSupportsCASelector) else { return .unresolved }
    let support = unsafeBitCast(
      endpoint,
      to: StatusConversationAwarenessSupportShim.self
    )
    guard support.supportsConversationAwareness() else { return .unsupported }
    guard endpoint.responds(to: statusAVCAEnabledSelector) else { return .readError }
    let state = unsafeBitCast(endpoint, to: StatusConversationAwarenessStateShim.self)
    return .value(state.conversationAwarenessEnabled())
  }

  func readInEarPlacementStatus() -> DeviceStatusField<BluetoothEarPlacement> {
    switch coreAudioInEarPlacement {
    case let .value(placement): return .value(placement)
    case .unavailable: return .unsupported
    case .unknown, .conflict: return .unresolved
    case .readFailure: return .readError
    }
  }

  func readAudioOutputSelectionStatus() -> AudioDeviceSelectionObservation {
    routingObserver.selectionObservation(bluetoothDevice: object, direction: .output)
  }

  func readAudioInputSelectionStatus() -> AudioDeviceSelectionObservation {
    routingObserver.selectionObservation(bluetoothDevice: object, direction: .input)
  }

}

enum IOBluetoothStatusControllerCreationResult {
  case success(IOBluetoothStatusController)
  case unavailable
  case readError(OSStatus)
}

final class IOBluetoothStatusController {
  private let devices: [IOBluetoothStatusDevice]
  private let listeningModeBindings: [IOBluetoothListeningModeBinding]
  private let routingBackend: any AudioRoutingBackend
  private let routingObserver: AudioRoutingObserver
  private let logger: DebugLogger

  static func create(
    logger: DebugLogger,
    activeOutputContext: AnyObject?,
    readStatusListeningMode: Bool = true,
    readStatusInEarPlacement: Bool = true,
    allowOffCache: (any ListeningModeAllowOffCaching)? = nil
  ) -> IOBluetoothStatusControllerCreationResult {
    let runtime = SystemBluetoothAudioRuntime(logger: logger)
    return create(
      runtime: runtime,
      routingBackend: CoreAudioRoutingBackend(),
      activeEndpointProbe: activeOutputContext.map(SystemActiveAudioEndpointProbe.init),
      readStatusListeningMode: readStatusListeningMode,
      readStatusInEarPlacement: readStatusInEarPlacement,
      allowOffCache: allowOffCache,
      logger: logger
    )
  }

  static func create(
    runtime: any BluetoothAudioRuntime,
    routingBackend: any AudioRoutingBackend,
    activeEndpointProbe: (any ActiveAudioEndpointProbing)? = nil,
    readStatusListeningMode: Bool = true,
    readStatusInEarPlacement: Bool = false,
    allowOffCache: (any ListeningModeAllowOffCaching)? = nil,
    logger: DebugLogger
  ) -> IOBluetoothStatusControllerCreationResult {
    let audioDeviceIDs: [AudioDeviceID]
    switch routingBackend.readAudioDevices() {
    case let .value(value):
      audioDeviceIDs = value
    case .unavailable:
      logger.warning("core_audio.device_inventory", "unavailable")
      return .unavailable
    case let .failure(status):
      logger.warning("core_audio.device_inventory.error", status)
      return .readError(status)
    }
    logger.info("core_audio.device_count", audioDeviceIDs.count)
    return .success(
      IOBluetoothStatusController(
        audioDeviceIDs: audioDeviceIDs,
        runtime: runtime,
        routingBackend: routingBackend,
        activeEndpointProbe: activeEndpointProbe,
        readStatusListeningMode: readStatusListeningMode,
        readStatusInEarPlacement: readStatusInEarPlacement,
        allowOffCache: allowOffCache,
        logger: logger
      )
    )
  }

  private init(
    audioDeviceIDs: [AudioDeviceID],
    runtime: any BluetoothAudioRuntime,
    routingBackend: any AudioRoutingBackend,
    activeEndpointProbe: (any ActiveAudioEndpointProbing)?,
    readStatusListeningMode: Bool,
    readStatusInEarPlacement: Bool,
    allowOffCache: (any ListeningModeAllowOffCaching)?,
    logger: DebugLogger
  ) {
    self.logger = logger
    self.routingBackend = routingBackend

    let routingObserver = AudioRoutingObserver(
      backend: routingBackend,
      bluetoothBackend: runtime,
      activeEndpointProbe: activeEndpointProbe,
      logger: logger
    )
    self.routingObserver = routingObserver
    let inventory = IOBluetoothInventory.capture(
      audioDeviceIDs: audioDeviceIDs,
      runtime: runtime,
      routingBackend: routingBackend,
      routingObserver: routingObserver,
      readStatusListeningMode: readStatusListeningMode,
      readStatusInEarPlacement: readStatusInEarPlacement,
      allowOffCache: allowOffCache,
      logger: logger
    )
    devices = inventory.devices
    listeningModeBindings = inventory.listeningModeBindings
  }

  func listeningModeCandidates() -> [ListeningModeCandidate] {
    return listeningModeBindings.map { binding in
      let route = routingObserver.listeningModeOutputRoute(
        bluetoothDevice: binding.bluetoothDevice
      )
      let transport = HALListeningModeTransport(
        name: binding.name,
        audioDeviceID: binding.audioDeviceID,
        bluetoothDevice: binding.bluetoothDevice,
        backend: routingBackend,
        logger: logger
      )
      let avTransport = routingObserver.activeFeatureEndpoint(
        for: binding.bluetoothDevice
      ).flatMap { endpoint in
        PrivateAudioDevice.compatible(
          object: endpoint,
          sources: [.contextSingular],
          index: 0,
          logger: logger
        )
      }
      let avJoinEvidence = routingObserver.activeFeatureEndpointJoinEvidence(
        for: binding.bluetoothDevice
      )

      let names = [transport.name, avTransport?.name]
        .compactMap { $0 }
        .reduce(into: [String]()) { result, name in
          guard !result.contains(where: {
            $0.localizedCaseInsensitiveCompare(name) == .orderedSame
          }) else { return }
          result.append(name)
        }
      return ListeningModeCandidate(
        displayName: transport.name ?? "Compatible device",
        selectableNames: names,
        avTransport: avTransport,
        halTransport: transport,
        route: route,
        avJoinEvidence: avJoinEvidence,
        allowOffCorrelation: binding.allowOffCorrelation
      )
    }
  }

  func selectDevices(
    named requestedName: String?,
    policy: DeviceSelectionPolicy
  ) -> [IOBluetoothStatusDevice]? {
    guard case let .selected(devices) = resolveDevices(
      named: requestedName,
      policy: policy
    ) else { return nil }
    return devices
  }

  func resolveDevices(
    named requestedName: String?,
    policy: DeviceSelectionPolicy
  ) -> DeviceSelection<IOBluetoothStatusDevice> {
    if let requestedName {
      let matches = devices.filter {
        $0.name?.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
      }
      guard let selected = matches.first else {
        logger.warning("device_selection", "no-exact-name-match")
        return .noDevice
      }
      guard matches.count == 1 else {
        logger.warning("device_selection", "ambiguous-device-name")
        return .ambiguousDevice
      }
      logger.info("selected_device", selected.name)
      return .selected([selected])
    }

    guard !devices.isEmpty else {
      logger.warning("device_selection", "no-compatible-device")
      return .noDevice
    }
    switch policy {
    case .singleOrExact:
      guard devices.count == 1, let selected = devices.first else {
        logger.warning("device_selection", "ambiguous-device")
        return .ambiguousDevice
      }
      logger.info("selected_device", selected.name)
      return .selected([selected])
    case .allOrExact:
      logger.info("selected_device_count", devices.count)
      return .selected(devices)
    }
  }

}
