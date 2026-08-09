import CoreAudio
import Foundation

// These public transport FOURCC values were introduced after the deployment
// target. Spelling the stable values locally keeps the macOS 12 build while
// still classifying the known Continuity transports conservatively.
private let continuityCaptureWiredTransport: UInt32 = 0x6363_7764 // ccwd
private let continuityCaptureWirelessTransport: UInt32 = 0x6363_776C // ccwl
private let continuityCaptureTransport: UInt32 = 0x6363_6170 // ccap

// BTAudioHAL exposes these device properties through the ordinary Core Audio
// property API. They are runtime-gated because they are absent from the public
// SDK and from non-Apple Bluetooth audio devices.
private let appleAudioDeviceProperty: AudioObjectPropertySelector = 0x6961_6170 // iaap
private let bluetoothListeningModeProperty: AudioObjectPropertySelector = 0x6C73_746D // lstm
private let bluetoothListeningModeSupportProperty: AudioObjectPropertySelector =
  0x6C73_6D73 // lsms

enum AudioRoutingDirection: CaseIterable {
  case output
  case input

  fileprivate var defaultDeviceSelector: AudioObjectPropertySelector {
    switch self {
    case .output: return kAudioHardwarePropertyDefaultOutputDevice
    case .input: return kAudioHardwarePropertyDefaultInputDevice
    }
  }

  fileprivate var logLabel: String {
    switch self {
    case .output: return "output"
    case .input: return "input"
    }
  }

  fileprivate var propertyScope: AudioObjectPropertyScope {
    switch self {
    case .output: return kAudioObjectPropertyScopeOutput
    case .input: return kAudioObjectPropertyScopeInput
    }
  }
}

enum AudioRoutingRead<Value> {
  case value(Value)
  case unavailable
  case failure(OSStatus)
}

enum AudioRoutingWrite: Equatable {
  case success
  case unavailable
  case notSettable
  case failure(OSStatus)
}

protocol CoreAudioPropertyAccess {
  func hasProperty(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress
  ) -> Bool
  func readPropertyDataSize(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32
  ) -> OSStatus
  func readPropertyData(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32,
    data: UnsafeMutableRawPointer
  ) -> OSStatus
  func isPropertySettable(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    settable: inout DarwinBoolean
  ) -> OSStatus
  func writePropertyData(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: UInt32,
    data: UnsafeRawPointer
  ) -> OSStatus
}

struct SystemCoreAudioPropertyAccess: CoreAudioPropertyAccess {
  func hasProperty(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress
  ) -> Bool {
    AudioObjectHasProperty(objectID, &address)
  }

  func readPropertyDataSize(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32
  ) -> OSStatus {
    AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
  }

  func readPropertyData(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32,
    data: UnsafeMutableRawPointer
  ) -> OSStatus {
    AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, data)
  }

  func isPropertySettable(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    settable: inout DarwinBoolean
  ) -> OSStatus {
    AudioObjectIsPropertySettable(objectID, &address, &settable)
  }

  func writePropertyData(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: UInt32,
    data: UnsafeRawPointer
  ) -> OSStatus {
    AudioObjectSetPropertyData(objectID, &address, 0, nil, dataSize, data)
  }
}

protocol AudioRoutingBackend {
  func readAudioDevices() -> AudioRoutingRead<[AudioDeviceID]>
  func readDefaultDevice(
    for direction: AudioRoutingDirection
  ) -> AudioRoutingRead<AudioDeviceID?>
  func isAggregateDevice(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool>
  func readTransportType(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32>
  func readDeviceIsAlive(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool>
  func readHasStreams(
    for deviceID: AudioDeviceID,
    direction: AudioRoutingDirection
  ) -> AudioRoutingRead<Bool>
  func readManufacturer(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<String?>
  func readName(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<String?>
  func readIsAppleAudioDevice(
    _ deviceID: AudioDeviceID
  ) -> AudioRoutingRead<Bool>
  func readBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32>
  func readBluetoothListeningModeSupport(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32>
  func isBluetoothListeningModeSettable(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<Bool>
  func writeBluetoothListeningMode(
    _ rawValue: UInt32,
    for deviceID: AudioDeviceID
  ) -> AudioRoutingWrite
}

struct CoreAudioRoutingBackend: AudioRoutingBackend {
  private let maximumAudioDeviceCount = 1_024
  private let propertyAccess: any CoreAudioPropertyAccess

  init(
    propertyAccess: any CoreAudioPropertyAccess = SystemCoreAudioPropertyAccess()
  ) {
    self.propertyAccess = propertyAccess
  }

  func readAudioDevices() -> AudioRoutingRead<[AudioDeviceID]> {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
      return .unavailable
    }
    var dataSize: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &dataSize
    )
    guard sizeStatus == noErr else { return .failure(sizeStatus) }
    let stride = MemoryLayout<AudioDeviceID>.stride
    guard Int(dataSize) % stride == 0,
          Int(dataSize) / stride <= maximumAudioDeviceCount
    else { return .failure(kAudioHardwareBadPropertySizeError) }

    let expectedSize = dataSize
    var devices = [AudioDeviceID](
      repeating: AudioDeviceID(kAudioObjectUnknown),
      count: Int(dataSize) / stride
    )
    guard !devices.isEmpty else { return .value([]) }
    let readStatus = devices.withUnsafeMutableBytes { buffer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        buffer.baseAddress!
      )
    }
    guard readStatus == noErr else { return .failure(readStatus) }
    guard dataSize == expectedSize else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    return .value(devices.filter { $0 != kAudioObjectUnknown })
  }

  func readDefaultDevice(
    for direction: AudioRoutingDirection
  ) -> AudioRoutingRead<AudioDeviceID?> {
    var address = AudioObjectPropertyAddress(
      mSelector: direction.defaultDeviceSelector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
      return .unavailable
    }
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &dataSize,
      &deviceID
    )
    guard status == noErr else { return .failure(status) }
    guard dataSize == MemoryLayout<AudioDeviceID>.size else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    return .value(deviceID == kAudioObjectUnknown ? nil : deviceID)
  }

  func isAggregateDevice(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyClass,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var classID = AudioClassID(0)
    var dataSize = UInt32(MemoryLayout<AudioClassID>.size)
    guard AudioObjectHasProperty(deviceID, &address) else {
      return .unavailable
    }
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &dataSize,
      &classID
    )
    guard status == noErr else { return .failure(status) }
    guard dataSize == MemoryLayout<AudioClassID>.size else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    return .value(classID == kAudioAggregateDeviceClassID)
  }

  func readTransportType(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var transportType = UInt32(kAudioDeviceTransportTypeUnknown)
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectHasProperty(deviceID, &address) else {
      return .unavailable
    }
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &dataSize,
      &transportType
    )
    guard status == noErr else { return .failure(status) }
    guard dataSize == MemoryLayout<UInt32>.size else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    return .value(transportType)
  }

  func readDeviceIsAlive(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    readUInt32Property(
      kAudioDevicePropertyDeviceIsAlive,
      from: deviceID,
      scope: kAudioObjectPropertyScopeGlobal
    ).map { $0 != 0 }
  }

  func readHasStreams(
    for deviceID: AudioDeviceID,
    direction: AudioRoutingDirection
  ) -> AudioRoutingRead<Bool> {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: direction.propertyScope,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return .unavailable }
    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &dataSize
    )
    guard status == noErr else { return .failure(status) }
    guard Int(dataSize) % MemoryLayout<AudioStreamID>.stride == 0 else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    return .value(dataSize != 0)
  }

  func readManufacturer(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<String?> {
    readStringProperty(kAudioObjectPropertyManufacturer, from: deviceID)
  }

  func readName(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<String?> {
    readStringProperty(kAudioObjectPropertyName, from: deviceID)
  }

  func readIsAppleAudioDevice(
    _ deviceID: AudioDeviceID
  ) -> AudioRoutingRead<Bool> {
    readUInt32Property(
      appleAudioDeviceProperty,
      from: deviceID,
      scope: kAudioObjectPropertyScopeGlobal
    ).map { $0 != 0 }
  }

  func readBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> {
    readUInt32Property(
      bluetoothListeningModeProperty,
      from: deviceID,
      scope: kAudioObjectPropertyScopeGlobal
    )
  }

  func readBluetoothListeningModeSupport(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> {
    readUInt32Property(
      bluetoothListeningModeSupportProperty,
      from: deviceID,
      scope: kAudioObjectPropertyScopeGlobal
    )
  }

  func isBluetoothListeningModeSettable(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<Bool> {
    var address = bluetoothListeningModeAddress
    guard propertyAccess.hasProperty(deviceID, address: &address) else {
      return .unavailable
    }
    var settable = DarwinBoolean(false)
    let status = propertyAccess.isPropertySettable(
      deviceID,
      address: &address,
      settable: &settable
    )
    guard status == noErr else { return .failure(status) }
    return .value(settable.boolValue)
  }

  func writeBluetoothListeningMode(
    _ rawValue: UInt32,
    for deviceID: AudioDeviceID
  ) -> AudioRoutingWrite {
    switch isBluetoothListeningModeSettable(for: deviceID) {
    case .unavailable:
      return .unavailable
    case let .failure(status):
      return .failure(status)
    case .value(false):
      return .notSettable
    case .value(true):
      break
    }

    var address = bluetoothListeningModeAddress
    var dataSize: UInt32 = 0
    let sizeStatus = propertyAccess.readPropertyDataSize(
      deviceID,
      address: &address,
      dataSize: &dataSize
    )
    guard sizeStatus == noErr else { return .failure(sizeStatus) }
    guard dataSize == MemoryLayout<UInt32>.size else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }

    var value = rawValue
    let status = withUnsafePointer(to: &value) { data in
      propertyAccess.writePropertyData(
        deviceID,
        address: &address,
        dataSize: dataSize,
        data: data
      )
    }
    return status == noErr ? .success : .failure(status)
  }

  private func readUInt32Property(
    _ selector: AudioObjectPropertySelector,
    from deviceID: AudioDeviceID,
    scope: AudioObjectPropertyScope
  ) -> AudioRoutingRead<UInt32> {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    guard propertyAccess.hasProperty(deviceID, address: &address) else {
      return .unavailable
    }
    var reportedSize: UInt32 = 0
    let sizeStatus = propertyAccess.readPropertyDataSize(
      deviceID,
      address: &address,
      dataSize: &reportedSize
    )
    guard sizeStatus == noErr else { return .failure(sizeStatus) }
    guard reportedSize == MemoryLayout<UInt32>.size else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    var value: UInt32 = 0
    var dataSize = reportedSize
    let status = propertyAccess.readPropertyData(
      deviceID,
      address: &address,
      dataSize: &dataSize,
      data: &value
    )
    guard status == noErr else { return .failure(status) }
    guard dataSize == MemoryLayout<UInt32>.size else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    return .value(value)
  }

  private var bluetoothListeningModeAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: bluetoothListeningModeProperty,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private func readStringProperty(
    _ selector: AudioObjectPropertySelector,
    from deviceID: AudioDeviceID
  ) -> AudioRoutingRead<String?> {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return .unavailable }
    var value: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &dataSize,
      &value
    )
    guard status == noErr else { return .failure(status) }
    guard dataSize == MemoryLayout<Unmanaged<CFString>?>.size else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    return .value(value.map { $0.takeRetainedValue() as String })
  }
}

private extension AudioRoutingRead {
  func map<Mapped>(_ transform: (Value) -> Mapped) -> AudioRoutingRead<Mapped> {
    switch self {
    case let .value(value): return .value(transform(value))
    case .unavailable: return .unavailable
    case let .failure(status): return .failure(status)
    }
  }
}

protocol BluetoothAudioDeviceMappingBackend {
  func bluetoothDevice(
    for audioDeviceID: AudioDeviceID
  ) -> AudioRoutingRead<AnyObject?>
}

func bluetoothDevicesAreExactlyEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool {
  if lhs === rhs { return true }
  guard let left = lhs as? NSObject, let right = rhs as? NSObject else {
    return false
  }
  // IOBluetoothDevice implements equality using its canonical device
  // identity. Requiring agreement in both directions avoids accepting a
  // permissive equality implementation from an unexpected object type.
  return left.isEqual(right) && right.isEqual(left)
}

struct ActiveAudioEndpointBinding {
  let audioDeviceID: AudioDeviceID
  let endpoint: AnyObject
}

protocol ActiveAudioEndpointProbing {
  func capture() -> AudioRoutingRead<ActiveAudioEndpointBinding>
}

private enum StableBluetoothRoute {
  case noDefault
  case composite
  case notBluetooth
  case device(AudioDeviceID, AnyObject)
  case unresolved
  case readError
}

private struct AudioRoutingSnapshot {
  let output: StableBluetoothRoute
  let input: StableBluetoothRoute

  func route(for direction: AudioRoutingDirection) -> StableBluetoothRoute {
    switch direction {
    case .output: return output
    case .input: return input
    }
  }
}

// One observer belongs to one status controller. It lazily captures each
// public default route, maps it back to the canonical IOBluetoothDevice once,
// verifies that the route did not change during that mapping, and shares the
// result across every candidate. Other commands never construct this observer.
final class AudioRoutingObserver {
  private let backend: any AudioRoutingBackend
  private let bluetoothBackend: any BluetoothAudioDeviceMappingBackend
  private let activeEndpointProbe: (any ActiveAudioEndpointProbing)?
  private let logger: DebugLogger
  private let lock = NSLock()
  private var storedSnapshot: AudioRoutingSnapshot?
  private var didCaptureActiveFeatureEndpoint = false
  private var storedActiveFeatureEndpoint: AnyObject?

  init(
    backend: any AudioRoutingBackend = CoreAudioRoutingBackend(),
    bluetoothBackend: any BluetoothAudioDeviceMappingBackend,
    activeEndpointProbe: (any ActiveAudioEndpointProbing)? = nil,
    logger: DebugLogger
  ) {
    self.backend = backend
    self.bluetoothBackend = bluetoothBackend
    self.activeEndpointProbe = activeEndpointProbe
    self.logger = logger
  }

  func selectionObservation(
    bluetoothDevice candidate: AnyObject,
    direction: AudioRoutingDirection
  ) -> AudioDeviceSelectionObservation {
    switch snapshot().route(for: direction) {
    case .noDefault, .composite, .notBluetooth:
      return .notSelected
    case let .device(_, selected):
      let matches = bluetoothDevicesAreExactlyEqual(candidate, selected)
      logger.debug("routing.\(direction.logLabel).identity_match", matches)
      return matches ? .selected : .notSelected
    case .unresolved:
      return .unresolved
    case .readError:
      return .readError
    }
  }

  func listeningModeOutputRoute(
    bluetoothDevice candidate: AnyObject
  ) -> ListeningModeCandidateRoute {
    switch snapshot().route(for: .output) {
    case .noDefault, .notBluetooth:
      return .notSelected
    case .composite:
      return .unknown
    case let .device(_, selected):
      return bluetoothDevicesAreExactlyEqual(candidate, selected)
        ? .selected
        : .notSelected
    case .unresolved, .readError:
      return .unknown
    }
  }

  // Feature enrichment is deliberately narrower than selection. Only the
  // singular active AV endpoint may supply mode/Conversation Awareness, and
  // only when its associated Core Audio ID is the same stable default output
  // whose IOBluetoothDevice exactly equals this candidate.
  func activeFeatureEndpoint(for candidate: AnyObject) -> AnyObject? {
    guard case let .device(defaultOutputID, selectedBluetoothDevice) =
      snapshot().route(for: .output),
      bluetoothDevicesAreExactlyEqual(candidate, selectedBluetoothDevice),
      let activeEndpointProbe
    else { return nil }

    lock.lock()
    defer { lock.unlock() }
    if didCaptureActiveFeatureEndpoint { return storedActiveFeatureEndpoint }
    didCaptureActiveFeatureEndpoint = true

    switch activeEndpointProbe.capture() {
    case let .value(binding) where binding.audioDeviceID == defaultOutputID:
      logger.debug("routing.active_feature_join", true)
      storedActiveFeatureEndpoint = binding.endpoint
    case .value:
      logger.debug("routing.active_feature_join", false)
    case .unavailable:
      logger.debug("routing.active_feature_join", "unavailable")
    case let .failure(status):
      logger.debug("routing.active_feature_join.error", status)
    }
    return storedActiveFeatureEndpoint
  }

  private func snapshot() -> AudioRoutingSnapshot {
    lock.lock()
    defer { lock.unlock() }
    if let storedSnapshot { return storedSnapshot }

    let beforeOutput = backend.readDefaultDevice(for: .output)
    let beforeInput = backend.readDefaultDevice(for: .input)
    let mappedOutput = routeBeforeStabilityCheck(beforeOutput, direction: .output)
    let mappedInput = routeBeforeStabilityCheck(beforeInput, direction: .input)
    let afterOutput = backend.readDefaultDevice(for: .output)
    let afterInput = backend.readDefaultDevice(for: .input)

    let snapshot = AudioRoutingSnapshot(
      output: stableRoute(
        mappedOutput,
        before: beforeOutput,
        after: afterOutput,
        direction: .output
      ),
      input: stableRoute(
        mappedInput,
        before: beforeInput,
        after: afterInput,
        direction: .input
      )
    )
    storedSnapshot = snapshot
    logger.debug("routing.snapshot", "captured")
    return snapshot
  }

  private func routeBeforeStabilityCheck(
    _ defaultRead: AudioRoutingRead<AudioDeviceID?>,
    direction: AudioRoutingDirection
  ) -> StableBluetoothRoute {
    let deviceID: AudioDeviceID
    switch defaultRead {
    case let .failure(status):
      logger.warning("routing.default_\(direction.logLabel).error", status)
      return .readError
    case .unavailable:
      logger.debug("routing.default_\(direction.logLabel)", "unavailable")
      return .unresolved
    case .value(nil):
      return .noDefault
    case let .value(.some(value)):
      deviceID = value
    }

    // A composite is a distinct route. Its physical members are not selected.
    // This gate deliberately precedes every private mapping call.
    switch backend.isAggregateDevice(deviceID) {
    case let .failure(status):
      logger.warning("routing.selected_\(direction.logLabel)_class.error", status)
      return .readError
    case .unavailable:
      logger.debug("routing.selected_\(direction.logLabel)_class", "unavailable")
      return .unresolved
    case .value(true):
      return .composite
    case .value(false):
      break
    }

    switch backend.readTransportType(for: deviceID) {
    case let .failure(status):
      logger.warning("routing.transport_\(direction.logLabel).error", status)
      return .readError
    case .unavailable:
      logger.debug("routing.transport_\(direction.logLabel)", "unavailable")
      return .unresolved
    case .value(kAudioDeviceTransportTypeUnknown):
      logger.debug("routing.transport_\(direction.logLabel)", "unknown")
      return .unresolved
    case .value(kAudioDeviceTransportTypeBluetoothLE):
      logger.debug("routing.transport_\(direction.logLabel)", "bluetooth-le")
      return .unresolved
    case .value(kAudioDeviceTransportTypeUSB):
      // Unknown and BLE cannot be mapped by IOBluetoothAudioManager. USB is
      // conservative because the same AirPods Max/Beats may also remain in
      // the Bluetooth inventory while attached over USB.
      logger.debug("routing.transport_\(direction.logLabel)", "usb")
      return .unresolved
    case .value(kAudioDeviceTransportTypeBluetooth):
      logger.debug("routing.transport_\(direction.logLabel)", "classic-bluetooth")
      break
    case .value(kAudioDeviceTransportTypeBuiltIn),
         .value(kAudioDeviceTransportTypeAggregate),
         .value(kAudioDeviceTransportTypeVirtual),
         .value(kAudioDeviceTransportTypePCI),
         .value(kAudioDeviceTransportTypeFireWire),
         .value(kAudioDeviceTransportTypeHDMI),
         .value(kAudioDeviceTransportTypeDisplayPort),
         .value(kAudioDeviceTransportTypeAirPlay),
         .value(kAudioDeviceTransportTypeAVB),
         .value(kAudioDeviceTransportTypeThunderbolt),
         .value(kAudioDeviceTransportTypeAutoAggregate),
         .value(continuityCaptureWiredTransport),
         .value(continuityCaptureWirelessTransport),
         .value(continuityCaptureTransport):
      logger.debug("routing.transport_\(direction.logLabel)", "unrelated")
      return .notBluetooth
    case .value:
      logger.debug("routing.transport_\(direction.logLabel)", "unrecognized")
      return .unresolved
    }

    switch bluetoothBackend.bluetoothDevice(for: deviceID) {
    case let .failure(status):
      logger.warning("routing.bluetooth_\(direction.logLabel).error", status)
      return .readError
    case .unavailable, .value(nil):
      logger.debug("routing.bluetooth_\(direction.logLabel)", "unavailable")
      return .unresolved
    case let .value(.some(device)):
      return .device(deviceID, device)
    }
  }

  private func stableRoute(
    _ route: StableBluetoothRoute,
    before: AudioRoutingRead<AudioDeviceID?>,
    after: AudioRoutingRead<AudioDeviceID?>,
    direction: AudioRoutingDirection
  ) -> StableBluetoothRoute {
    let beforeID: AudioDeviceID?
    switch before {
    case let .value(value): beforeID = value
    case .unavailable, .failure: return route
    }

    let afterID: AudioDeviceID?
    switch after {
    case let .failure(status):
      logger.warning("routing.default_\(direction.logLabel)_reread.error", status)
      return .readError
    case .unavailable:
      logger.debug("routing.default_\(direction.logLabel)_reread", "unavailable")
      return .unresolved
    case let .value(value):
      afterID = value
    }

    guard beforeID == afterID else {
      logger.debug("routing.default_\(direction.logLabel)_stability", "changed")
      return .unresolved
    }
    logger.debug("routing.default_\(direction.logLabel)_stability", "stable")
    return route
  }
}
