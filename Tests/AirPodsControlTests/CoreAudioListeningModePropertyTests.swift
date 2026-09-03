import CoreAudio
import Foundation
import Testing

@testable import AirPodsControlCore

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

@Suite("Core Audio listening mode properties")
struct CoreAudioListeningModePropertyTests {
  
  @Test
  func coreAudioListeningModeRawReadsAreRuntimeGatedAndExactlyUInt32() throws {
    let deviceID = AudioDeviceID(91)
    let listeningModeSelector = AudioObjectPropertySelector(0x6C73_746D) // lstm
    let listeningModeSupportSelector = AudioObjectPropertySelector(0x6C73_6D73) // lsms
  
    let missingAccess = FakeCoreAudioPropertyAccess()
    missingAccess.propertyPresent = false
    let missingBackend = CoreAudioRoutingBackend(propertyAccess: missingAccess)
    #expect(
      routingIsUnavailable(missingBackend.readBluetoothListeningMode(for: deviceID)),
      "a missing lstm property is unavailable"
    )
    #expect(
      !missingBackend.hasBluetoothListeningMode(for: deviceID),
      "a missing lstm property is absent from control discovery"
    )
    #expect(
      missingAccess.sizeReads.isEmpty && missingAccess.valueReads.isEmpty,
      "a missing property is never sized or read"
    )
  
    let access = FakeCoreAudioPropertyAccess()
    let backend = CoreAudioRoutingBackend(propertyAccess: access)
    #expect(
      backend.hasBluetoothListeningMode(for: deviceID),
      "an lstm property is present for control discovery without reading its value"
    )
    access.readValue = 0x1234_5678
    #expect(
      routingValue(backend.readBluetoothListeningMode(for: deviceID)) == 0x1234_5678,
      "lstm exposes the exact raw UInt32 value"
    )
    access.readValue = 0xA5A5_5A5A
    #expect(
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
    #expect(
      access.propertyChecks == [listeningModeAddress] + expectedReadAddresses,
      "presence, lstm, and lsms are runtime-gated at global/main"
    )
    #expect(
      access.sizeReads == expectedReadAddresses && access.valueReads == expectedReadAddresses,
      "both raw properties are sized before their exact reads"
    )
  }
  
  @Test
  func coreAudioListeningModeRawReadsPreserveSizeAndReadFailures() throws {
    let deviceID = AudioDeviceID(92)
    let sizeFailure: OSStatus = -7_001
    let readFailure: OSStatus = -7_002
  
    let sizeFailureAccess = FakeCoreAudioPropertyAccess()
    sizeFailureAccess.dataSizeStatus = sizeFailure
    let sizeFailureBackend = CoreAudioRoutingBackend(propertyAccess: sizeFailureAccess)
    #expect(
      routingFailure(sizeFailureBackend.readBluetoothListeningMode(for: deviceID))
        == sizeFailure,
      "a lstm size-query OSStatus is preserved"
    )
    #expect(
      sizeFailureAccess.valueReads.isEmpty,
      "a failed size query prevents a value read"
    )
  
    for malformedSize in [UInt32(0), UInt32(3), UInt32(8)] {
      let malformedAccess = FakeCoreAudioPropertyAccess()
      malformedAccess.reportedDataSize = malformedSize
      let malformedBackend = CoreAudioRoutingBackend(propertyAccess: malformedAccess)
      #expect(
        routingFailure(malformedBackend.readBluetoothListeningModeSupport(for: deviceID))
          == kAudioHardwareBadPropertySizeError,
        "lsms rejects a reported \(malformedSize)-byte payload"
      )
      #expect(
        malformedAccess.valueReads.isEmpty,
        "a malformed lsms size is rejected before reading"
      )
    }
  
    let readFailureAccess = FakeCoreAudioPropertyAccess()
    readFailureAccess.readStatus = readFailure
    let readFailureBackend = CoreAudioRoutingBackend(propertyAccess: readFailureAccess)
    #expect(
      routingFailure(readFailureBackend.readBluetoothListeningMode(for: deviceID))
        == readFailure,
      "a lstm read OSStatus is preserved"
    )
  
    let changedSizeAccess = FakeCoreAudioPropertyAccess()
    changedSizeAccess.returnedDataSize = 2
    let changedSizeBackend = CoreAudioRoutingBackend(propertyAccess: changedSizeAccess)
    #expect(
      routingFailure(changedSizeBackend.readBluetoothListeningMode(for: deviceID))
        == kAudioHardwareBadPropertySizeError,
      "lstm rejects a read that changes the returned payload size"
    )
  }
  
  @Test
  func coreAudioListeningModeSettableCheckIsTypedAndRuntimeGated() throws {
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
    #expect(
      routingIsUnavailable(missingBackend.isBluetoothListeningModeSettable(for: deviceID)),
      "settable is unavailable when lstm is missing"
    )
    #expect(
      missingAccess.settableReads.isEmpty,
      "a missing lstm property is not queried for settable state"
    )
  
    let failureAccess = FakeCoreAudioPropertyAccess()
    failureAccess.settableStatus = -7_003
    let failureBackend = CoreAudioRoutingBackend(propertyAccess: failureAccess)
    #expect(
      routingFailure(failureBackend.isBluetoothListeningModeSettable(for: deviceID))
        == -7_003,
      "the settable-query OSStatus is preserved"
    )
  
    for expected in [false, true] {
      let access = FakeCoreAudioPropertyAccess()
      access.propertySettable = expected
      let backend = CoreAudioRoutingBackend(propertyAccess: access)
      #expect(
        routingValue(backend.isBluetoothListeningModeSettable(for: deviceID)) == expected,
        "the raw Core Audio settable state is preserved"
      )
      #expect(
        access.propertyChecks == [expectedAddress]
          && access.settableReads == [expectedAddress],
        "the settable query uses the lstm global/main address"
      )
    }
  }
  
  @Test
  func coreAudioListeningModeWritePreservesRawUInt32AndOSStatus() throws {
    let deviceID = AudioDeviceID(94)
    let exactSize = UInt32(MemoryLayout<UInt32>.size)
    let access = FakeCoreAudioPropertyAccess()
    let backend = CoreAudioRoutingBackend(propertyAccess: access)
    let rawValues: [UInt32] = [0, 1, 4, UInt32.max]
  
    for rawValue in rawValues {
      #expect(
        backend.writeBluetoothListeningMode(rawValue, for: deviceID) == .success,
        "a successful lstm write reports success"
      )
    }
    #expect(
      access.writes.map { $0.value } == rawValues,
      "lstm writes preserve every raw UInt32 without mapping or narrowing"
    )
    #expect(
      access.writes.allSatisfy { $0.dataSize == exactSize },
      "every lstm write sends exactly four bytes"
    )
    #expect(
      access.writes.allSatisfy {
        $0.address.objectID == deviceID
          && $0.address.selector == AudioObjectPropertySelector(0x6C73_746D)
          && $0.address.scope == kAudioObjectPropertyScopeGlobal
          && $0.address.element == kAudioObjectPropertyElementMain
      },
      "every lstm write uses the global/main address"
    )
  
    access.writeStatus = -7_004
    #expect(
      backend.writeBluetoothListeningMode(3, for: deviceID) == .failure(-7_004),
      "the lstm write OSStatus is preserved"
    )
  }
  
  @Test
  func coreAudioListeningModeWriteHonorsAvailabilityAndSettableState() throws {
    let deviceID = AudioDeviceID(95)
  
    let missingAccess = FakeCoreAudioPropertyAccess()
    missingAccess.propertyPresent = false
    let missingBackend = CoreAudioRoutingBackend(propertyAccess: missingAccess)
    #expect(
      missingBackend.writeBluetoothListeningMode(2, for: deviceID) == .unavailable,
      "a write reports unavailable when lstm is missing"
    )
    #expect(missingAccess.writes.isEmpty, "a missing property is never written")
  
    let readOnlyAccess = FakeCoreAudioPropertyAccess()
    readOnlyAccess.propertySettable = false
    let readOnlyBackend = CoreAudioRoutingBackend(propertyAccess: readOnlyAccess)
    #expect(
      readOnlyBackend.writeBluetoothListeningMode(2, for: deviceID) == .notSettable,
      "a read-only lstm property reports not-settable"
    )
    #expect(readOnlyAccess.writes.isEmpty, "a read-only property is never written")
  
    let settableFailureAccess = FakeCoreAudioPropertyAccess()
    settableFailureAccess.settableStatus = -7_005
    let settableFailureBackend = CoreAudioRoutingBackend(
      propertyAccess: settableFailureAccess
    )
    #expect(
      settableFailureBackend.writeBluetoothListeningMode(2, for: deviceID)
        == .failure(-7_005),
      "a settable-query failure prevents the write and preserves OSStatus"
    )
    #expect(
      settableFailureAccess.writes.isEmpty,
      "a failed settable query never reaches the write"
    )
  
    let sizeFailureAccess = FakeCoreAudioPropertyAccess()
    sizeFailureAccess.dataSizeStatus = -7_006
    let sizeFailureBackend = CoreAudioRoutingBackend(
      propertyAccess: sizeFailureAccess
    )
    #expect(
      sizeFailureBackend.writeBluetoothListeningMode(2, for: deviceID)
        == .failure(-7_006),
      "a write-size query failure prevents the write and preserves OSStatus"
    )
    #expect(
      sizeFailureAccess.writes.isEmpty,
      "a failed write-size query never reaches the setter"
    )
  
    let malformedSizeAccess = FakeCoreAudioPropertyAccess()
    malformedSizeAccess.reportedDataSize = 8
    let malformedSizeBackend = CoreAudioRoutingBackend(
      propertyAccess: malformedSizeAccess
    )
    #expect(
      malformedSizeBackend.writeBluetoothListeningMode(2, for: deviceID)
        == .failure(kAudioHardwareBadPropertySizeError),
      "a malformed lstm write size fails closed"
    )
    #expect(
      malformedSizeAccess.writes.isEmpty,
      "a malformed lstm write size never reaches the setter"
    )
  }
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

