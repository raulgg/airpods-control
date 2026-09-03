import CoreAudio
import Foundation
import Testing

@testable import AirPodsControlCore

private final class FakeInEarPlacementPropertyAccess: CoreAudioPropertyAccess {
  private enum Property {
    case detection
    case primary
    case placement
  }

  private static let detectionSelector = AudioObjectPropertySelector(0x6965_6465)
  private static let primarySelector = AudioObjectPropertySelector(0x7072_6973)
  private static let placementSelector = AudioObjectPropertySelector(0x6965_7362)

  var detectionValue: UInt32 = 1
  var primaryValues: [UInt32] = [1] {
    didSet { primaryReadIndex = 0 }
  }
  var placementValues: (UInt32, UInt32) = (1, 2)
  var placementPresent = true
  var placementReportedSize = UInt32(2 * MemoryLayout<UInt32>.size)
  var placementReturnedSize: UInt32?
  var placementReadStatus: OSStatus = noErr
  private var primaryReadIndex = 0

  func hasProperty(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress
  ) -> Bool {
    guard let property = property(for: address.mSelector) else { return false }
    return property != .placement || placementPresent
  }

  func readPropertyDataSize(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32
  ) -> OSStatus {
    dataSize = property(for: address.mSelector) == .placement
      ? placementReportedSize
      : UInt32(MemoryLayout<UInt32>.size)
    return noErr
  }

  func readPropertyData(
    _ objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    dataSize: inout UInt32,
    data: UnsafeMutableRawPointer
  ) -> OSStatus {
    guard let property = property(for: address.mSelector) else {
      return kAudioHardwareUnknownPropertyError
    }
    if property == .placement, placementReadStatus != noErr {
      return placementReadStatus
    }
    let propertyBytes: [UInt8]
    switch property {
    case .detection:
      propertyBytes = bytes(detectionValue)
    case .primary:
      let value = primaryValues[min(primaryReadIndex, primaryValues.count - 1)]
      primaryReadIndex += 1
      propertyBytes = bytes(value)
    case .placement:
      propertyBytes = bytes(placementValues.0) + bytes(placementValues.1)
    }
    propertyBytes.withUnsafeBytes { source in
      data.copyMemory(
        from: source.baseAddress!,
        byteCount: min(Int(dataSize), propertyBytes.count)
      )
    }
    if property == .placement {
      dataSize = placementReturnedSize ?? dataSize
    }
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

  private func property(
    for selector: AudioObjectPropertySelector
  ) -> Property? {
    switch selector {
    case Self.detectionSelector: return .detection
    case Self.primarySelector: return .primary
    case Self.placementSelector: return .placement
    default: return nil
    }
  }
}

@Suite("Core Audio in-ear placement properties")
struct CoreAudioInEarPlacementPropertyTests {

  @Test
  func coreAudioInEarPlacementMapsStablePrimaryJourneys() throws {
    let deviceID = AudioDeviceID(121)
    let access = FakeInEarPlacementPropertyAccess()
    access.placementValues = (1, 3)
    let backend = CoreAudioRoutingBackend(propertyAccess: access)

    #expect(
      placementValue(backend.readBluetoothInEarPlacement(for: deviceID))
        == BluetoothEarPlacement(left: .inEar, right: .inCase),
      "a stable left primary maps both placement states to physical ears"
    )

    access.primaryValues = [2]
    access.placementValues = (2, 1)
    #expect(
      placementValue(backend.readBluetoothInEarPlacement(for: deviceID))
        == BluetoothEarPlacement(left: .inEar, right: .outOfEar),
      "a stable right primary reverses the primary and secondary mapping"
    )

    access.primaryValues = [1, 2]
    access.placementValues = (1, 1)
    #expect(
      placementUnknown(backend.readBluetoothInEarPlacement(for: deviceID)),
      "a primary-side change during the read is not misattributed"
    )
  }

  @Test
  func coreAudioInEarPlacementFailsClosedAcrossUnavailableAndMalformedEvidence() throws {
    let deviceID = AudioDeviceID(122)
    let access = FakeInEarPlacementPropertyAccess()
    let backend = CoreAudioRoutingBackend(propertyAccess: access)

    access.detectionValue = 0
    #expect(
      placementUnavailable(backend.readBluetoothInEarPlacement(for: deviceID)),
      "disabled in-ear detection makes placement unavailable"
    )

    access.detectionValue = 2
    #expect(
      placementUnknown(backend.readBluetoothInEarPlacement(for: deviceID)),
      "unrecognized detection evidence remains unknown"
    )

    access.detectionValue = 1
    access.placementValues = (1, 99)
    #expect(
      placementUnknown(backend.readBluetoothInEarPlacement(for: deviceID)),
      "unrecognized placement evidence remains unknown"
    )

    access.placementValues = (1, 2)
    access.placementPresent = false
    #expect(
      placementUnavailable(backend.readBluetoothInEarPlacement(for: deviceID)),
      "a missing placement property remains unavailable"
    )

    access.placementPresent = true
    access.placementReadStatus = -7_102
    #expect(
      placementFailure(backend.readBluetoothInEarPlacement(for: deviceID)) == -7_102,
      "a placement read preserves its Core Audio failure"
    )

    access.placementReadStatus = noErr
    access.placementReportedSize = UInt32(MemoryLayout<UInt32>.size)
    #expect(
      placementFailure(backend.readBluetoothInEarPlacement(for: deviceID))
        == kAudioHardwareBadPropertySizeError,
      "a malformed placement payload is rejected before mapping"
    )

    access.placementReportedSize = UInt32(2 * MemoryLayout<UInt32>.size)
    access.placementReturnedSize = UInt32(MemoryLayout<UInt32>.size)
    #expect(
      placementFailure(backend.readBluetoothInEarPlacement(for: deviceID))
        == kAudioHardwareBadPropertySizeError,
      "a placement payload that changes size during the read is rejected"
    )
  }
}

private func bytes(_ value: UInt32) -> [UInt8] {
  var value = value
  return withUnsafeBytes(of: &value) { Array($0) }
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
