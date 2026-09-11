import CoreAudio
import Foundation

// BTAudioHAL exposes these device properties through the ordinary Core Audio
// property API. They are runtime-gated because they are absent from the public
// SDK and from non-Apple Bluetooth audio devices.
private let appleAudioDeviceProperty: AudioObjectPropertySelector = 0x6961_6170 // iaap
private let bluetoothListeningModeProperty: AudioObjectPropertySelector = 0x6C73_746D // lstm
private let bluetoothListeningModeSupportProperty: AudioObjectPropertySelector =
  0x6C73_6D73 // lsms
private let bluetoothInEarPlacementProperty: AudioObjectPropertySelector =
  0x6965_7362 // iesb
private let bluetoothPrimaryEarProperty: AudioObjectPropertySelector =
  0x7072_6973 // pris
private let bluetoothInEarDetectionEnabledProperty: AudioObjectPropertySelector =
  0x6965_6465 // iede

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

  func readDeviceUID(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<String?> {
    readStringProperty(kAudioDevicePropertyDeviceUID, from: deviceID)
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

  func hasBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> Bool {
    var address = bluetoothListeningModeAddress
    return propertyAccess.hasProperty(deviceID, address: &address)
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

  func readBluetoothInEarPlacement(
    for deviceID: AudioDeviceID
  ) -> BluetoothEarPlacementRead {
    switch readUInt32Property(
      bluetoothInEarDetectionEnabledProperty,
      from: deviceID,
      scope: kAudioObjectPropertyScopeGlobal
    ) {
    case .unavailable:
      return .unavailable
    case let .failure(status):
      return .failure(status)
    case .value(0):
      return .unavailable
    case .value(1):
      break
    case .value:
      return .unknown
    }

    let primarySideBefore: UInt32
    switch readUInt32Property(
      bluetoothPrimaryEarProperty,
      from: deviceID,
      scope: kAudioObjectPropertyScopeGlobal
    ) {
    case .unavailable:
      return .unavailable
    case let .failure(status):
      return .failure(status)
    case let .value(value) where value == 1 || value == 2:
      primarySideBefore = value
    case .value:
      return .unknown
    }

    let rawPlacement: (UInt32, UInt32)
    switch readUInt32PairProperty(
      bluetoothInEarPlacementProperty,
      from: deviceID,
      scope: kAudioObjectPropertyScopeGlobal
    ) {
    case .unavailable:
      return .unavailable
    case let .failure(status):
      return .failure(status)
    case let .value(value):
      rawPlacement = value
    }

    let primarySideAfter: UInt32
    switch readUInt32Property(
      bluetoothPrimaryEarProperty,
      from: deviceID,
      scope: kAudioObjectPropertyScopeGlobal
    ) {
    case .unavailable:
      return .unavailable
    case let .failure(status):
      return .failure(status)
    case let .value(value) where value == 1 || value == 2:
      primarySideAfter = value
    case .value:
      return .unknown
    }
    guard primarySideBefore == primarySideAfter else { return .unknown }

    guard let primary = mapBluetoothEarPlacementState(rawPlacement.0),
          let secondary = mapBluetoothEarPlacementState(rawPlacement.1)
    else { return .unknown }

    if primarySideBefore == 1 {
      return .value(BluetoothEarPlacement(left: primary, right: secondary))
    }
    return .value(BluetoothEarPlacement(left: secondary, right: primary))
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

  private func readUInt32PairProperty(
    _ selector: AudioObjectPropertySelector,
    from deviceID: AudioDeviceID,
    scope: AudioObjectPropertyScope
  ) -> AudioRoutingRead<(UInt32, UInt32)> {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    guard propertyAccess.hasProperty(deviceID, address: &address) else {
      return .unavailable
    }
    let expectedSize = UInt32(2 * MemoryLayout<UInt32>.size)
    var reportedSize: UInt32 = 0
    let sizeStatus = propertyAccess.readPropertyDataSize(
      deviceID,
      address: &address,
      dataSize: &reportedSize
    )
    guard sizeStatus == noErr else { return .failure(sizeStatus) }
    guard reportedSize == expectedSize else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }

    var values = [UInt32](repeating: 0, count: 2)
    var dataSize = reportedSize
    let status = values.withUnsafeMutableBytes { buffer in
      propertyAccess.readPropertyData(
        deviceID,
        address: &address,
        dataSize: &dataSize,
        data: buffer.baseAddress!
      )
    }
    guard status == noErr else { return .failure(status) }
    guard dataSize == expectedSize else {
      return .failure(kAudioHardwareBadPropertySizeError)
    }
    return .value((values[0], values[1]))
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

private func mapBluetoothEarPlacementState(
  _ rawValue: UInt32
) -> BluetoothEarPlacementState? {
  switch rawValue {
  case 1: return .inEar
  case 2: return .outOfEar
  case 3: return .inCase
  default: return nil
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
