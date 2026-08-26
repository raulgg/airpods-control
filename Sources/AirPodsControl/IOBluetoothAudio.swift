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

private let bluetoothModeByRawValue: [UInt32: ListeningMode] = [
  1: .off,
  2: .noiseCancellation,
  3: .transparency,
  4: .adaptive,
]

private enum CoreAudioListeningModeObservation {
  case value(ListeningMode)
  case unavailable
  case unrecognized
  case conflict
  case readFailure
}

final class IOBluetoothStatusDevice: CompatibleAudioDevice {
  let object: AnyObject
  let name: String?
  private let coreAudioListeningMode: CoreAudioListeningModeObservation
  private let runtime: any BluetoothAudioRuntime
  private let routingObserver: AudioRoutingObserver

  fileprivate init(
    object: AnyObject,
    name: String,
    coreAudioListeningMode: CoreAudioListeningModeObservation,
    runtime: any BluetoothAudioRuntime,
    routingObserver: AudioRoutingObserver
  ) {
    self.object = object
    self.name = name
    self.coreAudioListeningMode = coreAudioListeningMode
    self.runtime = runtime
    self.routingObserver = routingObserver
  }

  func supportReportMetadata() -> SupportReportDeviceMetadata {
    SupportReportDeviceMetadata(
      family: nil,
      modelIdentifier: nil,
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: currentListeningMode() != nil
    )
  }

  func availableListeningModes() -> [ListeningMode] { [] }

  func currentListeningMode() -> ListeningMode? {
    switch coreAudioListeningMode {
    case let .value(mode): return mode
    case .unrecognized, .conflict: return nil
    case .unavailable, .readFailure: break
    }
    guard case let .value(rawMode) = runtime.listeningMode(object) else { return nil }
    return bluetoothModeByRawValue[UInt32(rawMode)]
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

  func canSetListeningMode() -> Bool { false }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    DeviceWriteObservation(setterAccepted: false, observed: currentListeningMode())
  }

  func supportsConversationAwareness() -> Bool? {
    guard let endpoint = routingObserver.activeFeatureEndpoint(for: object),
          endpoint.responds(to: statusAVSupportsCASelector)
    else { return nil }
    let shim = unsafeBitCast(endpoint, to: StatusConversationAwarenessSupportShim.self)
    return shim.supportsConversationAwareness()
  }

  func conversationAwarenessState() -> Bool? {
    guard let endpoint = routingObserver.activeFeatureEndpoint(for: object),
          endpoint.responds(to: statusAVCAEnabledSelector)
    else { return nil }
    let shim = unsafeBitCast(endpoint, to: StatusConversationAwarenessStateShim.self)
    return shim.conversationAwarenessEnabled()
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

  func canSetConversationAwareness() -> Bool { false }

  func setConversationAwarenessAndReadBack(
    _ target: Bool
  ) -> DeviceWriteObservation<Bool> {
    DeviceWriteObservation(setterAccepted: false, observed: conversationAwarenessState())
  }

  func readAudioOutputSelectionStatus() -> AudioDeviceSelectionObservation {
    routingObserver.selectionObservation(bluetoothDevice: object, direction: .output)
  }

  func readAudioInputSelectionStatus() -> AudioDeviceSelectionObservation {
    routingObserver.selectionObservation(bluetoothDevice: object, direction: .input)
  }

  func settle(for interval: TimeInterval) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
  }
}

private let recognizedAppleAudioManufacturers: Set<String> = [
  "Apple",
  "Apple Inc.",
  "Beats Electronics",
  "Beats Electronics LLC",
  "Beats Electronics, LLC",
]
private let maximumCoreAudioDeviceNameLength = 512

private enum AppleAudioAdmission: Equatable {
  case positive
  case unavailable
  case negative
}

private struct CoreAudioBluetoothEndpoint {
  let audioDeviceID: AudioDeviceID
  let bluetoothDevice: AnyObject
  let hasOutput: Bool
  let name: String?
  let appleAudioAdmission: AppleAudioAdmission
  let listeningMode: AudioRoutingRead<UInt32>
}

private struct CoreAudioBluetoothDeviceGroup {
  let equalityAnchor: AnyObject
  var endpoints: [CoreAudioBluetoothEndpoint]
}

private struct IOBluetoothListeningModeBinding {
  let name: String
  let audioDeviceID: AudioDeviceID
  let bluetoothDevice: AnyObject
}

final class IOBluetoothStatusController {
  private let devices: [IOBluetoothStatusDevice]
  private let listeningModeBindings: [IOBluetoothListeningModeBinding]
  private let routingBackend: any AudioRoutingBackend
  private let routingObserver: AudioRoutingObserver
  private let logger: DebugLogger

  convenience init?(
    logger: DebugLogger,
    activeOutputContext: AnyObject?,
    readStatusListeningMode: Bool = true
  ) {
    let runtime = SystemBluetoothAudioRuntime(logger: logger)
    self.init(
      runtime: runtime,
      routingBackend: CoreAudioRoutingBackend(),
      activeEndpointProbe: activeOutputContext.map(SystemActiveAudioEndpointProbe.init),
      readStatusListeningMode: readStatusListeningMode,
      logger: logger
    )
  }

  init?(
    runtime: any BluetoothAudioRuntime,
    routingBackend: any AudioRoutingBackend,
    activeEndpointProbe: (any ActiveAudioEndpointProbing)? = nil,
    readStatusListeningMode: Bool = true,
    logger: DebugLogger
  ) {
    self.logger = logger
    self.routingBackend = routingBackend
    let audioDeviceIDs: [AudioDeviceID]
    switch routingBackend.readAudioDevices() {
    case let .value(value):
      audioDeviceIDs = value
    case .unavailable:
      logger.warning("core_audio.device_inventory", "unavailable")
      return nil
    case let .failure(status):
      logger.warning("core_audio.device_inventory.error", status)
      return nil
    }
    logger.info("core_audio.device_count", audioDeviceIDs.count)

    let routingObserver = AudioRoutingObserver(
      backend: routingBackend,
      bluetoothBackend: runtime,
      activeEndpointProbe: activeEndpointProbe,
      logger: logger
    )
    self.routingObserver = routingObserver
    var groups: [CoreAudioBluetoothDeviceGroup] = []
    var mappedEndpointCount = 0
    for (index, audioDeviceID) in audioDeviceIDs.enumerated() {
      let prefix = "core_audio.candidate_\(index)"

      let aggregateRead = routingBackend.isAggregateDevice(audioDeviceID)
      Self.logBooleanRead(aggregateRead, key: "\(prefix).aggregate", logger: logger)
      guard case .value(false) = aggregateRead else {
        logger.debug("\(prefix).eligible", false)
        continue
      }

      let transportRead = routingBackend.readTransportType(for: audioDeviceID)
      let isClassicBluetooth: Bool
      switch transportRead {
      case .value(kAudioDeviceTransportTypeBluetooth):
        isClassicBluetooth = true
        logger.debug("\(prefix).transport", "classic-bluetooth")
      case .value:
        isClassicBluetooth = false
        logger.debug("\(prefix).transport", "other")
      case .unavailable:
        isClassicBluetooth = false
        logger.debug("\(prefix).transport", "unavailable")
      case let .failure(status):
        isClassicBluetooth = false
        logger.debug("\(prefix).transport", "read-error")
        logger.debug("\(prefix).transport_error", status)
      }
      guard isClassicBluetooth else {
        logger.debug("\(prefix).eligible", false)
        continue
      }

      let aliveRead = routingBackend.readDeviceIsAlive(audioDeviceID)
      Self.logBooleanRead(aliveRead, key: "\(prefix).alive", logger: logger)
      guard case .value(true) = aliveRead else {
        logger.debug("\(prefix).eligible", false)
        continue
      }

      let inputRead = routingBackend.readHasStreams(
        for: audioDeviceID,
        direction: .input
      )
      let outputRead = routingBackend.readHasStreams(
        for: audioDeviceID,
        direction: .output
      )
      let hasInput = Self.positiveValue(inputRead)
      let hasOutput = Self.positiveValue(outputRead)
      Self.logBooleanRead(inputRead, key: "\(prefix).input_streams", logger: logger)
      Self.logBooleanRead(outputRead, key: "\(prefix).output_streams", logger: logger)
      guard hasInput || hasOutput else {
        logger.debug("\(prefix).eligible", false)
        continue
      }

      let appleAudioAdmission: AppleAudioAdmission
      switch routingBackend.readIsAppleAudioDevice(audioDeviceID) {
      case .value(true):
        appleAudioAdmission = .positive
        logger.debug("\(prefix).apple_audio_property", true)
      case .value(false):
        appleAudioAdmission = .negative
        logger.debug("\(prefix).apple_audio_property", false)
      case .unavailable:
        logger.debug("\(prefix).apple_audio_property", "unavailable")
        let manufacturerRead = routingBackend.readManufacturer(for: audioDeviceID)
        if case let .value(.some(manufacturer)) = manufacturerRead {
          let recognized = recognizedAppleAudioManufacturers.contains(manufacturer)
          appleAudioAdmission = recognized ? .positive : .unavailable
          logger.debug("\(prefix).apple_manufacturer", recognized)
        } else {
          appleAudioAdmission = .unavailable
          switch manufacturerRead {
          case .value:
            logger.debug("\(prefix).manufacturer", "available")
          case .unavailable:
            logger.debug("\(prefix).manufacturer", "unavailable")
          case let .failure(status):
            logger.debug("\(prefix).manufacturer", "read-error")
            logger.debug("\(prefix).manufacturer_error", status)
          }
        }
      case let .failure(status):
        appleAudioAdmission = .unavailable
        logger.debug("\(prefix).apple_audio_property", "read-error")
        logger.debug("\(prefix).apple_audio_property_error", status)
      }

      let bluetoothDevice: AnyObject
      switch runtime.bluetoothDevice(for: audioDeviceID) {
      case let .value(.some(value)):
        bluetoothDevice = value
        logger.debug("\(prefix).mapping", "available")
      case .value(nil), .unavailable:
        logger.debug("\(prefix).mapping", "unavailable")
        logger.debug("\(prefix).eligible", false)
        continue
      case let .failure(status):
        logger.debug("\(prefix).mapping", "read-error")
        logger.debug("\(prefix).mapping_error", status)
        logger.debug("\(prefix).eligible", false)
        continue
      }

      let name = appleAudioAdmission == .positive
        ? Self.usableName(routingBackend.readName(for: audioDeviceID))
        : nil
      let listeningModeRead: AudioRoutingRead<UInt32> = readStatusListeningMode
        ? routingBackend.readBluetoothListeningMode(for: audioDeviceID)
        : .unavailable
      switch listeningModeRead {
      case let .value(listeningMode):
        logger.debug("\(prefix).listening_mode", "available")
        logger.debug(
          "\(prefix).recognized_listening_mode",
          bluetoothModeByRawValue[listeningMode] != nil
        )
      case .unavailable:
        logger.debug("\(prefix).listening_mode", "unavailable")
      case let .failure(status):
        logger.debug("\(prefix).listening_mode", "read-error")
        logger.debug("\(prefix).listening_mode_error", status)
      }
      logger.debug("\(prefix).name_available", name != nil)
      logger.debug("\(prefix).eligible", appleAudioAdmission == .positive)
      mappedEndpointCount += 1
      let endpoint = CoreAudioBluetoothEndpoint(
        audioDeviceID: audioDeviceID,
        bluetoothDevice: bluetoothDevice,
        hasOutput: hasOutput,
        name: name,
        appleAudioAdmission: appleAudioAdmission,
        listeningMode: listeningModeRead
      )
      if let groupIndex = groups.firstIndex(where: {
        bluetoothDevicesAreExactlyEqual($0.equalityAnchor, bluetoothDevice)
      }) {
        groups[groupIndex].endpoints.append(endpoint)
      } else {
        groups.append(
          CoreAudioBluetoothDeviceGroup(
            equalityAnchor: bluetoothDevice,
            endpoints: [endpoint]
          )
        )
      }
    }
    logger.info("bluetooth.mapped_endpoint_count", mappedEndpointCount)
    logger.info("bluetooth.mapped_device_count", groups.count)

    let compatibleDevices: [IOBluetoothStatusDevice] = groups.compactMap { group in
      guard !group.endpoints.contains(where: {
        $0.appleAudioAdmission == .negative
      }) else {
        logger.debug("bluetooth.apple_audio_consistency", "conflict")
        return nil
      }
      let positiveEndpoints = group.endpoints.filter {
        $0.appleAudioAdmission == .positive
      }
      let endpoints = positiveEndpoints.filter(\.hasOutput)
        + positiveEndpoints.filter { !$0.hasOutput }
      guard let primary = endpoints.first,
            let namedEndpoint = endpoints.first(where: { $0.name != nil }),
            let name = namedEndpoint.name
      else { return nil }
      return IOBluetoothStatusDevice(
        object: primary.bluetoothDevice,
        name: name,
        coreAudioListeningMode: Self.resolveListeningMode(
          from: group.endpoints,
          logger: logger
        ),
        runtime: runtime,
        routingObserver: routingObserver
      )
    }
    devices = compatibleDevices
    listeningModeBindings = groups.compactMap { group in
      guard !group.endpoints.contains(where: {
        $0.appleAudioAdmission == .negative
      }) else { return nil }
      let outputEndpoints = group.endpoints.filter {
        $0.appleAudioAdmission == .positive && $0.hasOutput
      }
      let controlEndpoints = outputEndpoints.filter {
        routingBackend.hasBluetoothListeningMode(for: $0.audioDeviceID)
      }
      guard let namedEndpoint = outputEndpoints.first(where: { $0.name != nil }),
            let outputEndpoint =
              controlEndpoints.first(where: { $0.name != nil })
              ?? controlEndpoints.first,
            let name = namedEndpoint.name
      else { return nil }
      return IOBluetoothListeningModeBinding(
        name: name,
        audioDeviceID: outputEndpoint.audioDeviceID,
        bluetoothDevice: outputEndpoint.bluetoothDevice
      )
    }
    logger.info("compatible_device_count", devices.count)
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
        avJoinEvidence: avJoinEvidence
      )
    }
  }

  func selectDevices(
    named requestedName: String?,
    policy: DeviceSelectionPolicy
  ) -> [IOBluetoothStatusDevice]? {
    if let requestedName {
      let matches = devices.filter {
        $0.name?.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
      }
      guard matches.count == 1 else {
        logger.warning(
          "device_selection",
          matches.isEmpty ? "no-exact-name-match" : "ambiguous-device-name"
        )
        return nil
      }
      logger.info("selected_device", matches[0].name)
      return matches
    }

    guard !devices.isEmpty else {
      logger.warning("device_selection", "no-compatible-device")
      return nil
    }
    switch policy {
    case .firstOrExact:
      logger.info("selected_device", devices[0].name)
      return [devices[0]]
    case .allOrExact:
      logger.info("selected_device_count", devices.count)
      return devices
    }
  }

  private static func positiveValue(_ read: AudioRoutingRead<Bool>) -> Bool {
    if case .value(true) = read { return true }
    return false
  }

  private static func usableName(
    _ read: AudioRoutingRead<String?>
  ) -> String? {
    guard case let .value(.some(value)) = read,
          !value.isEmpty,
          value.unicodeScalars.count <= maximumCoreAudioDeviceNameLength
    else { return nil }
    return value
  }

  private static func logBooleanRead(
    _ read: AudioRoutingRead<Bool>,
    key: String,
    logger: DebugLogger
  ) {
    switch read {
    case let .value(value): logger.debug(key, value)
    case .unavailable: logger.debug(key, "unavailable")
    case let .failure(status):
      logger.debug(key, "read-error")
      logger.debug("\(key)_error", status)
    }
  }

  private static func resolveListeningMode(
    from endpoints: [CoreAudioBluetoothEndpoint],
    logger: DebugLogger
  ) -> CoreAudioListeningModeObservation {
    var recognizedModes: Set<ListeningMode> = []
    var sawReadFailure = false
    var sawUnrecognizedMode = false
    for endpoint in endpoints {
      switch endpoint.listeningMode {
      case let .value(rawValue):
        if let mode = bluetoothModeByRawValue[rawValue] {
          recognizedModes.insert(mode)
        } else if rawValue != 0 {
          sawUnrecognizedMode = true
        }
      case .unavailable:
        break
      case .failure:
        sawReadFailure = true
      }
    }
    if recognizedModes.count > 1 {
      logger.debug("bluetooth.listening_mode_consistency", "conflict")
      return .conflict
    }
    if sawUnrecognizedMode {
      logger.debug("bluetooth.listening_mode_consistency", "unrecognized")
      return .unrecognized
    }
    if let mode = recognizedModes.first { return .value(mode) }
    if sawReadFailure {
      logger.debug("bluetooth.listening_mode_consistency", "read-error")
      return .readFailure
    }
    return .unavailable
  }
}
