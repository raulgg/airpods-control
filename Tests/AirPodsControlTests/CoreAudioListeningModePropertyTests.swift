import CoreAudio
import Foundation

private struct RecordedCoreAudioPropertyAddress: Equatable {
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

private final class FakeCoreAudioPropertyAccess: CoreAudioPropertyAccess {
  var propertyPresent = true
  var dataSizeStatus: OSStatus = noErr
  var reportedDataSize = UInt32(MemoryLayout<UInt32>.size)
  var readStatus: OSStatus = noErr
  var returnedDataSize: UInt32?
  var readValue: UInt32 = 0
  var settableStatus: OSStatus = noErr
  var propertySettable = true
  var writeStatus: OSStatus = noErr

  private(set) var propertyChecks: [RecordedCoreAudioPropertyAddress] = []
  private(set) var sizeReads: [RecordedCoreAudioPropertyAddress] = []
  private(set) var valueReads: [RecordedCoreAudioPropertyAddress] = []
  private(set) var settableReads: [RecordedCoreAudioPropertyAddress] = []
  private(set) var writes: [(
    address: RecordedCoreAudioPropertyAddress,
    dataSize: UInt32,
    value: UInt32
  )] = []

  func hasProperty(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress
  ) -> Bool {
    propertyChecks.append(RecordedCoreAudioPropertyAddress(objectID, address))
    return propertyPresent
  }

  func readPropertyDataSize(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32
  ) -> OSStatus {
    sizeReads.append(RecordedCoreAudioPropertyAddress(objectID, address))
    dataSize = reportedDataSize
    return dataSizeStatus
  }

  func readPropertyData(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32,
    data: UnsafeMutableRawPointer
  ) -> OSStatus {
    valueReads.append(RecordedCoreAudioPropertyAddress(objectID, address))
    guard readStatus == noErr else { return readStatus }
    data.storeBytes(of: readValue, as: UInt32.self)
    dataSize = returnedDataSize ?? dataSize
    return noErr
  }

  func isPropertySettable(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    settable: inout DarwinBoolean
  ) -> OSStatus {
    settableReads.append(RecordedCoreAudioPropertyAddress(objectID, address))
    settable = DarwinBoolean(propertySettable)
    return settableStatus
  }

  func writePropertyData(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: UInt32,
    data: UnsafeRawPointer
  ) -> OSStatus {
    writes.append(
      (
        RecordedCoreAudioPropertyAddress(objectID, address),
        dataSize,
        data.load(as: UInt32.self)
      )
    )
    return writeStatus
  }
}

func testCoreAudioListeningModeRawReadsAreRuntimeGatedAndExactlyUInt32() {
  let deviceID = AudioDeviceID(91)
  let listeningModeSelector = AudioObjectPropertySelector(0x6C73_746D) // lstm
  let listeningModeSupportSelector = AudioObjectPropertySelector(0x6C73_6D73) // lsms

  let missingAccess = FakeCoreAudioPropertyAccess()
  missingAccess.propertyPresent = false
  let missingBackend = CoreAudioRoutingBackend(propertyAccess: missingAccess)
  check(
    routingIsUnavailable(missingBackend.readBluetoothListeningMode(for: deviceID)),
    "a missing lstm property is unavailable"
  )
  check(
    !missingBackend.hasBluetoothListeningMode(for: deviceID),
    "a missing lstm property is absent from control discovery"
  )
  check(
    missingAccess.sizeReads.isEmpty && missingAccess.valueReads.isEmpty,
    "a missing property is never sized or read"
  )

  let access = FakeCoreAudioPropertyAccess()
  let backend = CoreAudioRoutingBackend(propertyAccess: access)
  check(
    backend.hasBluetoothListeningMode(for: deviceID),
    "an lstm property is present for control discovery without reading its value"
  )
  access.readValue = 0x1234_5678
  check(
    routingValue(backend.readBluetoothListeningMode(for: deviceID)) == 0x1234_5678,
    "lstm exposes the exact raw UInt32 value"
  )
  access.readValue = 0xA5A5_5A5A
  check(
    routingValue(backend.readBluetoothListeningModeSupport(for: deviceID))
      == 0xA5A5_5A5A,
    "lsms exposes the exact raw UInt32 value without mapping it"
  )

  let listeningModeAddress = RecordedCoreAudioPropertyAddress(
    deviceID,
    AudioObjectPropertyAddress(
      mSelector: listeningModeSelector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  )
  let expectedReadAddresses = [
    listeningModeAddress,
    RecordedCoreAudioPropertyAddress(
      deviceID,
      AudioObjectPropertyAddress(
        mSelector: listeningModeSupportSelector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
    ),
  ]
  check(
    access.propertyChecks == [listeningModeAddress] + expectedReadAddresses,
    "presence, lstm, and lsms are runtime-gated at global/main"
  )
  check(
    access.sizeReads == expectedReadAddresses && access.valueReads == expectedReadAddresses,
    "both raw properties are sized before their exact reads"
  )
}

func testCoreAudioListeningModeRawReadsPreserveSizeAndReadFailures() {
  let deviceID = AudioDeviceID(92)
  let sizeFailure: OSStatus = -7_001
  let readFailure: OSStatus = -7_002

  let sizeFailureAccess = FakeCoreAudioPropertyAccess()
  sizeFailureAccess.dataSizeStatus = sizeFailure
  let sizeFailureBackend = CoreAudioRoutingBackend(propertyAccess: sizeFailureAccess)
  check(
    routingFailure(sizeFailureBackend.readBluetoothListeningMode(for: deviceID))
      == sizeFailure,
    "a lstm size-query OSStatus is preserved"
  )
  check(
    sizeFailureAccess.valueReads.isEmpty,
    "a failed size query prevents a value read"
  )

  for malformedSize in [UInt32(0), UInt32(3), UInt32(8)] {
    let malformedAccess = FakeCoreAudioPropertyAccess()
    malformedAccess.reportedDataSize = malformedSize
    let malformedBackend = CoreAudioRoutingBackend(propertyAccess: malformedAccess)
    check(
      routingFailure(malformedBackend.readBluetoothListeningModeSupport(for: deviceID))
        == kAudioHardwareBadPropertySizeError,
      "lsms rejects a reported \(malformedSize)-byte payload"
    )
    check(
      malformedAccess.valueReads.isEmpty,
      "a malformed lsms size is rejected before reading"
    )
  }

  let readFailureAccess = FakeCoreAudioPropertyAccess()
  readFailureAccess.readStatus = readFailure
  let readFailureBackend = CoreAudioRoutingBackend(propertyAccess: readFailureAccess)
  check(
    routingFailure(readFailureBackend.readBluetoothListeningMode(for: deviceID))
      == readFailure,
    "a lstm read OSStatus is preserved"
  )

  let changedSizeAccess = FakeCoreAudioPropertyAccess()
  changedSizeAccess.returnedDataSize = 2
  let changedSizeBackend = CoreAudioRoutingBackend(propertyAccess: changedSizeAccess)
  check(
    routingFailure(changedSizeBackend.readBluetoothListeningMode(for: deviceID))
      == kAudioHardwareBadPropertySizeError,
    "lstm rejects a read that changes the returned payload size"
  )
}

func testCoreAudioListeningModeSettableCheckIsTypedAndRuntimeGated() {
  let deviceID = AudioDeviceID(93)
  let expectedAddress = RecordedCoreAudioPropertyAddress(
    deviceID,
    AudioObjectPropertyAddress(
      mSelector: AudioObjectPropertySelector(0x6C73_746D),
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  )

  let missingAccess = FakeCoreAudioPropertyAccess()
  missingAccess.propertyPresent = false
  let missingBackend = CoreAudioRoutingBackend(propertyAccess: missingAccess)
  check(
    routingIsUnavailable(missingBackend.isBluetoothListeningModeSettable(for: deviceID)),
    "settable is unavailable when lstm is missing"
  )
  check(
    missingAccess.settableReads.isEmpty,
    "a missing lstm property is not queried for settable state"
  )

  let failureAccess = FakeCoreAudioPropertyAccess()
  failureAccess.settableStatus = -7_003
  let failureBackend = CoreAudioRoutingBackend(propertyAccess: failureAccess)
  check(
    routingFailure(failureBackend.isBluetoothListeningModeSettable(for: deviceID))
      == -7_003,
    "the settable-query OSStatus is preserved"
  )

  for expected in [false, true] {
    let access = FakeCoreAudioPropertyAccess()
    access.propertySettable = expected
    let backend = CoreAudioRoutingBackend(propertyAccess: access)
    check(
      routingValue(backend.isBluetoothListeningModeSettable(for: deviceID)) == expected,
      "the raw Core Audio settable state is preserved"
    )
    check(
      access.propertyChecks == [expectedAddress]
        && access.settableReads == [expectedAddress],
      "the settable query uses the lstm global/main address"
    )
  }
}

func testCoreAudioListeningModeWritePreservesRawUInt32AndOSStatus() {
  let deviceID = AudioDeviceID(94)
  let exactSize = UInt32(MemoryLayout<UInt32>.size)
  let access = FakeCoreAudioPropertyAccess()
  let backend = CoreAudioRoutingBackend(propertyAccess: access)
  let rawValues: [UInt32] = [0, 1, 4, UInt32.max]

  for rawValue in rawValues {
    check(
      backend.writeBluetoothListeningMode(rawValue, for: deviceID) == .success,
      "a successful lstm write reports success"
    )
  }
  check(
    access.writes.map { $0.value } == rawValues,
    "lstm writes preserve every raw UInt32 without mapping or narrowing"
  )
  check(
    access.writes.allSatisfy { $0.dataSize == exactSize },
    "every lstm write sends exactly four bytes"
  )
  check(
    access.writes.allSatisfy {
      $0.address.objectID == deviceID
        && $0.address.selector == AudioObjectPropertySelector(0x6C73_746D)
        && $0.address.scope == kAudioObjectPropertyScopeGlobal
        && $0.address.element == kAudioObjectPropertyElementMain
    },
    "every lstm write uses the global/main address"
  )

  access.writeStatus = -7_004
  check(
    backend.writeBluetoothListeningMode(3, for: deviceID) == .failure(-7_004),
    "the lstm write OSStatus is preserved"
  )
}

func testCoreAudioListeningModeWriteHonorsAvailabilityAndSettableState() {
  let deviceID = AudioDeviceID(95)

  let missingAccess = FakeCoreAudioPropertyAccess()
  missingAccess.propertyPresent = false
  let missingBackend = CoreAudioRoutingBackend(propertyAccess: missingAccess)
  check(
    missingBackend.writeBluetoothListeningMode(2, for: deviceID) == .unavailable,
    "a write reports unavailable when lstm is missing"
  )
  check(missingAccess.writes.isEmpty, "a missing property is never written")

  let readOnlyAccess = FakeCoreAudioPropertyAccess()
  readOnlyAccess.propertySettable = false
  let readOnlyBackend = CoreAudioRoutingBackend(propertyAccess: readOnlyAccess)
  check(
    readOnlyBackend.writeBluetoothListeningMode(2, for: deviceID) == .notSettable,
    "a read-only lstm property reports not-settable"
  )
  check(readOnlyAccess.writes.isEmpty, "a read-only property is never written")

  let settableFailureAccess = FakeCoreAudioPropertyAccess()
  settableFailureAccess.settableStatus = -7_005
  let settableFailureBackend = CoreAudioRoutingBackend(
    propertyAccess: settableFailureAccess
  )
  check(
    settableFailureBackend.writeBluetoothListeningMode(2, for: deviceID)
      == .failure(-7_005),
    "a settable-query failure prevents the write and preserves OSStatus"
  )
  check(
    settableFailureAccess.writes.isEmpty,
    "a failed settable query never reaches the write"
  )

  let sizeFailureAccess = FakeCoreAudioPropertyAccess()
  sizeFailureAccess.dataSizeStatus = -7_006
  let sizeFailureBackend = CoreAudioRoutingBackend(
    propertyAccess: sizeFailureAccess
  )
  check(
    sizeFailureBackend.writeBluetoothListeningMode(2, for: deviceID)
      == .failure(-7_006),
    "a write-size query failure prevents the write and preserves OSStatus"
  )
  check(
    sizeFailureAccess.writes.isEmpty,
    "a failed write-size query never reaches the setter"
  )

  let malformedSizeAccess = FakeCoreAudioPropertyAccess()
  malformedSizeAccess.reportedDataSize = 8
  let malformedSizeBackend = CoreAudioRoutingBackend(
    propertyAccess: malformedSizeAccess
  )
  check(
    malformedSizeBackend.writeBluetoothListeningMode(2, for: deviceID)
      == .failure(kAudioHardwareBadPropertySizeError),
    "a malformed lstm write size fails closed"
  )
  check(
    malformedSizeAccess.writes.isEmpty,
    "a malformed lstm write size never reaches the setter"
  )
}

func runCoreAudioListeningModePropertyTests() {
  testCoreAudioListeningModeRawReadsAreRuntimeGatedAndExactlyUInt32()
  testCoreAudioListeningModeRawReadsPreserveSizeAndReadFailures()
  testCoreAudioListeningModeSettableCheckIsTypedAndRuntimeGated()
  testCoreAudioListeningModeWritePreservesRawUInt32AndOSStatus()
  testCoreAudioListeningModeWriteHonorsAvailabilityAndSettableState()
}

private func routingValue<Value>(_ read: AudioRoutingRead<Value>) -> Value? {
  if case let .value(value) = read { return value }
  return nil
}

private func routingFailure<Value>(_ read: AudioRoutingRead<Value>) -> OSStatus? {
  if case let .failure(status) = read { return status }
  return nil
}

private func routingIsUnavailable<Value>(_ read: AudioRoutingRead<Value>) -> Bool {
  if case .unavailable = read { return true }
  return false
}
