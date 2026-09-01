import Foundation

private func scannerTestFrame(status: UInt8, productID: Int = 0x2024) -> Data {
  var bytes: [UInt8] = [
    0x4C, 0x00, 0x07, 0x19, 0x01,
    UInt8(productID & 0xFF), UInt8((productID >> 8) & 0xFF),
    status, 0xAA, 0xB5, 0x31, 0x00, 0x00,
  ]
  bytes += [UInt8](repeating: 0, count: 16)
  return Data(bytes)
}

func testAirPodsBLEScanNormalization() {
  let first = UUID()
  let second = UUID()
  let advertisements = [
    BluetoothAdvertisement(
      peripheralIdentifier: first,
      manufacturerData: scannerTestFrame(status: 0x0A)
    ),
    BluetoothAdvertisement(
      peripheralIdentifier: second,
      manufacturerData: scannerTestFrame(status: 0x22)
    ),
    BluetoothAdvertisement(
      peripheralIdentifier: first,
      manufacturerData: scannerTestFrame(status: 0x0A)
    ),
    BluetoothAdvertisement(
      peripheralIdentifier: second,
      manufacturerData: scannerTestFrame(status: 0x22)
    ),
  ]
  let normalized = AirPodsBLEScanNormalizer.normalize(advertisements)
  check(normalized.count == 2, "normalizer keeps two stable peripherals")
  check(
    normalized.first(where: { $0.peripheralIdentifier == first })?.placement
      == BluetoothEarPlacement(left: .inEar, right: .inEar),
    "normalizer returns the agreed placement"
  )
}

func testAirPodsBLEScanRejectsWeakOrConflictingEvidence() {
  let identifier = UUID()
  check(
    AirPodsBLEScanNormalizer.normalize([
      BluetoothAdvertisement(
        peripheralIdentifier: identifier,
        manufacturerData: scannerTestFrame(status: 0x0A)
      ),
    ]).isEmpty,
    "one callback is not enough"
  )
  check(
    AirPodsBLEScanNormalizer.normalize([
      BluetoothAdvertisement(
        peripheralIdentifier: identifier,
        manufacturerData: scannerTestFrame(status: 0x0A)
      ),
      BluetoothAdvertisement(
        peripheralIdentifier: identifier,
        manufacturerData: scannerTestFrame(status: 0x00)
      ),
    ]).isEmpty,
    "conflicting normalized frames are rejected"
  )
  check(
    AirPodsBLEScanNormalizer.normalize([
      BluetoothAdvertisement(
        peripheralIdentifier: identifier,
        manufacturerData: scannerTestFrame(status: 0x0A)
      ),
      BluetoothAdvertisement(
        peripheralIdentifier: identifier,
        manufacturerData: scannerTestFrame(status: 0x0A, productID: 0x200E)
      ),
    ]).isEmpty,
    "a product change within one scan is rejected"
  )
}

func runBluetoothScannerTests() {
  testAirPodsBLEScanNormalization()
  testAirPodsBLEScanRejectsWeakOrConflictingEvidence()
}
