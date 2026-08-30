import CoreAudio
import Foundation

private struct PlacementPropertyAddress: Equatable {
  let objectID: AudioObjectID
  let selector: AudioObjectPropertySelector
  let scope: AudioObjectPropertyScope
  let element: AudioObjectPropertyElement

  init(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) {
    self.objectID = objectID
    selector = address.mSelector
    scope = address.mScope
    element = address.mElement
  }
}

private final class FakeInEarPlacementPropertyAccess: CoreAudioPropertyAccess {
  var presentSelectors: Set<AudioObjectPropertySelector> = [
    AudioObjectPropertySelector(0x6965_6465), // iede
    AudioObjectPropertySelector(0x7072_6973), // pris
    AudioObjectPropertySelector(0x6965_7362), // iesb
  ]
  var dataSizeStatusBySelector: [AudioObjectPropertySelector: OSStatus] = [:]
  var reportedDataSizeBySelector: [AudioObjectPropertySelector: UInt32] = [
    AudioObjectPropertySelector(0x6965_7362): 8,
  ]
  var readStatusBySelector: [AudioObjectPropertySelector: OSStatus] = [:]
  var returnedDataSizeBySelector: [AudioObjectPropertySelector: UInt32] = [:]
  var dataBySelector: [AudioObjectPropertySelector: [UInt8]] = [:]
  var sequentialUInt32ValuesBySelector: [AudioObjectPropertySelector: [UInt32]] = [:]
  private var sequentialReadIndices: [AudioObjectPropertySelector: Int] = [:]

  private(set) var propertyChecks: [PlacementPropertyAddress] = []
  private(set) var sizeReads: [PlacementPropertyAddress] = []
  private(set) var valueReads: [PlacementPropertyAddress] = []

  func hasProperty(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress
  ) -> Bool {
    propertyChecks.append(PlacementPropertyAddress(objectID, address))
    return presentSelectors.contains(address.mSelector)
  }

  func readPropertyDataSize(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32
  ) -> OSStatus {
    sizeReads.append(PlacementPropertyAddress(objectID, address))
    dataSize = reportedDataSizeBySelector[address.mSelector]
      ?? UInt32(MemoryLayout<UInt32>.size)
    return dataSizeStatusBySelector[address.mSelector] ?? noErr
  }

  func readPropertyData(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32,
    data: UnsafeMutableRawPointer
  ) -> OSStatus {
    valueReads.append(PlacementPropertyAddress(objectID, address))
    let selector = address.mSelector
    if let status = readStatusBySelector[selector], status != noErr {
      return status
    }
    let bytes: [UInt8]
    if let values = sequentialUInt32ValuesBySelector[selector], !values.isEmpty {
      let index = sequentialReadIndices[selector] ?? 0
      let value = values[min(index, values.count - 1)]
      sequentialReadIndices[selector] = index + 1
      bytes = withUnsafeBytes(of: value) { Array($0) }
    } else {
      bytes = dataBySelector[selector] ?? []
    }
    if !bytes.isEmpty {
      bytes.withUnsafeBytes { source in
        data.copyMemory(
          from: source.baseAddress!,
          byteCount: min(Int(dataSize), bytes.count)
        )
      }
    }
    dataSize = returnedDataSizeBySelector[selector] ?? dataSize
    return noErr
  }

  func isPropertySettable(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    settable: inout DarwinBoolean
  ) -> OSStatus {
    settable = DarwinBoolean(false)
    return noErr
  }

  func writePropertyData(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: UInt32,
    data: UnsafeRawPointer
  ) -> OSStatus {
    noErr
  }
}

func testCoreAudioInEarPlacementReadsMapBothPrimaryOrientations() {
  let deviceID = AudioDeviceID(121)
  let access = FakeInEarPlacementPropertyAccess()
  access.dataBySelector[AudioObjectPropertySelector(0x6965_6465)] = bytes(UInt32(1))
  access.dataBySelector[AudioObjectPropertySelector(0x7072_6973)] = bytes(UInt32(1))
  access.dataBySelector[AudioObjectPropertySelector(0x6965_7362)] = pairBytes(1, 2)
  let backend = CoreAudioRoutingBackend(propertyAccess: access)

  check(
    placementValue(backend.readBluetoothInEarPlacement(for: deviceID))
      == BluetoothEarPlacement(left: .inEar, right: .outOfEar),
    "iesb primary/secondary values map left-first when pris is left"
  )

  access.dataBySelector[AudioObjectPropertySelector(0x7072_6973)] = bytes(UInt32(2))
  check(
    placementValue(backend.readBluetoothInEarPlacement(for: deviceID))
      == BluetoothEarPlacement(left: .outOfEar, right: .inEar),
    "iesb primary/secondary values map right-first when pris is right"
  )

  let expectedSelectors = [
    AudioObjectPropertySelector(0x6965_6465),
    AudioObjectPropertySelector(0x7072_6973),
    AudioObjectPropertySelector(0x6965_7362),
    AudioObjectPropertySelector(0x7072_6973),
  ]
  check(
    access.propertyChecks.map(\.selector) == expectedSelectors + expectedSelectors,
    "placement properties are presence-gated in a stable order"
  )
  check(
    access.sizeReads.map(\.selector) == expectedSelectors + expectedSelectors
      && access.valueReads.map(\.selector) == expectedSelectors + expectedSelectors,
    "placement properties are sized before exact reads"
  )
  check(
    access.propertyChecks.allSatisfy {
      $0.scope == kAudioObjectPropertyScopeGlobal
        && $0.element == kAudioObjectPropertyElementMain
        && $0.objectID == deviceID
    },
    "placement properties use global/main addresses"
  )
}

func testCoreAudioInEarPlacementReadsPreserveAvailabilityFailuresAndSizes() {
  let deviceID = AudioDeviceID(122)

  let missingAccess = FakeInEarPlacementPropertyAccess()
  missingAccess.presentSelectors.remove(
    AudioObjectPropertySelector(0x6965_6465)
  )
  let missingBackend = CoreAudioRoutingBackend(propertyAccess: missingAccess)
  check(
    placementUnavailable(missingBackend.readBluetoothInEarPlacement(for: deviceID)),
    "a missing iede gate is unavailable without reading any value"
  )
  check(missingAccess.sizeReads.isEmpty && missingAccess.valueReads.isEmpty,
        "a missing gate is not sized or read")

  let sizeFailure: OSStatus = -7_101
  let sizeFailureAccess = FakeInEarPlacementPropertyAccess()
  sizeFailureAccess.dataSizeStatusBySelector[AudioObjectPropertySelector(0x6965_6465)] =
    sizeFailure
  let sizeFailureBackend = CoreAudioRoutingBackend(propertyAccess: sizeFailureAccess)
  check(
    placementFailure(sizeFailureBackend.readBluetoothInEarPlacement(for: deviceID))
      == sizeFailure,
    "a placement size-query error preserves its OSStatus"
  )

  let readFailure: OSStatus = -7_102
  let readFailureAccess = FakeInEarPlacementPropertyAccess()
  readFailureAccess.dataBySelector[AudioObjectPropertySelector(0x6965_6465)] = bytes(1)
  readFailureAccess.readStatusBySelector[AudioObjectPropertySelector(0x6965_6465)] =
    readFailure
  let readFailureBackend = CoreAudioRoutingBackend(propertyAccess: readFailureAccess)
  check(
    placementFailure(readFailureBackend.readBluetoothInEarPlacement(for: deviceID))
      == readFailure,
    "a placement value-read error preserves its OSStatus"
  )

  for selector in [
    AudioObjectPropertySelector(0x6965_6465),
    AudioObjectPropertySelector(0x7072_6973),
    AudioObjectPropertySelector(0x6965_7362),
  ] {
    let malformedAccess = FakeInEarPlacementPropertyAccess()
    malformedAccess.reportedDataSizeBySelector[selector] = selector
      == AudioObjectPropertySelector(0x6965_7362) ? 4 : 8
    malformedAccess.dataBySelector[AudioObjectPropertySelector(0x6965_6465)] = bytes(1)
    malformedAccess.dataBySelector[AudioObjectPropertySelector(0x7072_6973)] = bytes(1)
    malformedAccess.dataBySelector[AudioObjectPropertySelector(0x6965_7362)] = pairBytes(1, 1)
    let malformedBackend = CoreAudioRoutingBackend(propertyAccess: malformedAccess)
    check(
      placementFailure(malformedBackend.readBluetoothInEarPlacement(for: deviceID))
        == kAudioHardwareBadPropertySizeError,
      "a malformed (selector) payload fails closed"
    )
  }

  let changedSizeAccess = FakeInEarPlacementPropertyAccess()
  changedSizeAccess.dataBySelector[AudioObjectPropertySelector(0x6965_6465)] = bytes(1)
  changedSizeAccess.dataBySelector[AudioObjectPropertySelector(0x7072_6973)] = bytes(1)
  changedSizeAccess.dataBySelector[AudioObjectPropertySelector(0x6965_7362)] = pairBytes(1, 1)
  changedSizeAccess.returnedDataSizeBySelector[AudioObjectPropertySelector(0x6965_7362)] = 4
  let changedSizeBackend = CoreAudioRoutingBackend(propertyAccess: changedSizeAccess)
  check(
    placementFailure(changedSizeBackend.readBluetoothInEarPlacement(for: deviceID))
      == kAudioHardwareBadPropertySizeError,
    "a changed iesb payload size fails closed"
  )
}

func testCoreAudioInEarPlacementReadsFailClosedForDisabledOrUnknownEvidence() {
  let deviceID = AudioDeviceID(123)
  let disabledAccess = FakeInEarPlacementPropertyAccess()
  disabledAccess.dataBySelector[AudioObjectPropertySelector(0x6965_6465)] = bytes(0)
  let disabledBackend = CoreAudioRoutingBackend(propertyAccess: disabledAccess)
  check(
    placementUnavailable(disabledBackend.readBluetoothInEarPlacement(for: deviceID)),
    "a disabled iede gate reports unavailable"
  )
  check(
    disabledAccess.valueReads.map(\.selector)
      == [AudioObjectPropertySelector(0x6965_6465)],
    "a disabled gate prevents pris and iesb reads"
  )

  let unknownGateAccess = FakeInEarPlacementPropertyAccess()
  unknownGateAccess.dataBySelector[AudioObjectPropertySelector(0x6965_6465)] = bytes(2)
  let unknownGateBackend = CoreAudioRoutingBackend(propertyAccess: unknownGateAccess)
  check(
    placementUnknown(unknownGateBackend.readBluetoothInEarPlacement(for: deviceID)),
    "an unrecognized iede value is unknown"
  )

  let unknownStateAccess = FakeInEarPlacementPropertyAccess()
  unknownStateAccess.dataBySelector[AudioObjectPropertySelector(0x6965_6465)] = bytes(1)
  unknownStateAccess.dataBySelector[AudioObjectPropertySelector(0x7072_6973)] = bytes(1)
  unknownStateAccess.dataBySelector[AudioObjectPropertySelector(0x6965_7362)] = pairBytes(1, 99)
  let unknownStateBackend = CoreAudioRoutingBackend(propertyAccess: unknownStateAccess)
  check(
    placementUnknown(unknownStateBackend.readBluetoothInEarPlacement(for: deviceID)),
    "an unrecognized iesb state is unknown rather than guessed"
  )

  let changingPrimaryAccess = FakeInEarPlacementPropertyAccess()
  changingPrimaryAccess.dataBySelector[AudioObjectPropertySelector(0x6965_6465)] = bytes(1)
  changingPrimaryAccess.dataBySelector[AudioObjectPropertySelector(0x6965_7362)] = pairBytes(1, 1)
  changingPrimaryAccess.sequentialUInt32ValuesBySelector[
    AudioObjectPropertySelector(0x7072_6973)
  ] = [1, 2]
  let changingPrimaryBackend = CoreAudioRoutingBackend(
    propertyAccess: changingPrimaryAccess
  )
  check(
    placementUnknown(
      changingPrimaryBackend.readBluetoothInEarPlacement(for: deviceID)
    ),
    "a changing physical primary side is rejected rather than misattributed"
  )
}

func runCoreAudioInEarPlacementPropertyTests() {
  testCoreAudioInEarPlacementReadsMapBothPrimaryOrientations()
  testCoreAudioInEarPlacementReadsPreserveAvailabilityFailuresAndSizes()
  testCoreAudioInEarPlacementReadsFailClosedForDisabledOrUnknownEvidence()
}

private func bytes(_ value: UInt32) -> [UInt8] {
  var value = value
  return withUnsafeBytes(of: &value) { Array($0) }
}

private func pairBytes(_ primary: UInt32, _ secondary: UInt32) -> [UInt8] {
  bytes(primary) + bytes(secondary)
}

private func placementValue(
  _ read: BluetoothEarPlacementRead
) -> BluetoothEarPlacement? {
  if case let .value(value) = read { return value }
  return nil
}

private func placementUnavailable(_ read: BluetoothEarPlacementRead) -> Bool {
  if case .unavailable = read { return true }
  return false
}

private func placementUnknown(_ read: BluetoothEarPlacementRead) -> Bool {
  if case .unknown = read { return true }
  return false
}

private func placementFailure(_ read: BluetoothEarPlacementRead) -> OSStatus? {
  if case let .failure(status) = read { return status }
  return nil
}
