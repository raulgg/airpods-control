import Foundation

private func proximityFrame(
  productID: Int = 0x200E,
  status: UInt8,
  includeCompanyIdentifier: Bool = true
) -> Data {
  var bytes: [UInt8] = includeCompanyIdentifier ? [0x4C, 0x00] : []
  bytes += [
    0x07, 0x19, 0x01,
    UInt8(productID & 0xFF), UInt8((productID >> 8) & 0xFF),
    status, 0xAA, 0xB5, 0x31, 0x00, 0x00,
  ]
  bytes += [UInt8](repeating: 0, count: 16)
  return Data(bytes)
}

func testAirPodsBLEFrameParserOrientation() {
  let cases: [(UInt8, BluetoothEarPlacement, String)] = [
    (
      0x22,
      BluetoothEarPlacement(left: .inEar, right: .outOfEar),
      "left primary, left in ear"
    ),
    (
      0x29,
      BluetoothEarPlacement(left: .outOfEar, right: .inEar),
      "left primary, right in ear"
    ),
    (
      0x09,
      BluetoothEarPlacement(left: .inEar, right: .outOfEar),
      "right primary, left in ear"
    ),
    (
      0x03,
      BluetoothEarPlacement(left: .outOfEar, right: .inEar),
      "right primary, right in ear"
    ),
    (
      0x00,
      BluetoothEarPlacement(left: .outOfEar, right: .outOfEar),
      "both out of ear"
    ),
    (
      0x0A,
      BluetoothEarPlacement(left: .inEar, right: .inEar),
      "both in ear"
    ),
    (
      0x49,
      BluetoothEarPlacement(left: .outOfEar, right: .inEar),
      "in-case orientation flip"
    ),
  ]

  for (status, expected, label) in cases {
    let parsed = AirPodsBLEFrameParser.parse(
      manufacturerData: proximityFrame(status: status)
    )
    check(parsed?.productID == 0x200E, "parser reads little-endian product ID")
    check(parsed?.placement == expected, "parser maps physical sides for \(label)")
  }
}

func testAirPodsBLEFrameParserValidation() {
  let supportedProductIDs = [
    0x2002, 0x200E, 0x200F, 0x2013, 0x2014, 0x2019, 0x201B, 0x2024, 0x2027,
  ]
  for productID in supportedProductIDs {
    check(
      AirPodsBLEFrameParser.parse(
        manufacturerData: proximityFrame(productID: productID, status: 0x0A)
      ) != nil,
      "parser accepts verified AirPods product \(productID)"
    )
  }

  check(
    AirPodsBLEFrameParser.parse(
      manufacturerData: proximityFrame(
        status: 0x0A,
        includeCompanyIdentifier: false
      )
    ) == nil,
    "CoreBluetooth parser requires Apple's company identifier"
  )

  var wrongCompany = proximityFrame(status: 0x0A)
  wrongCompany[0] = 0x01
  check(
    AirPodsBLEFrameParser.parse(manufacturerData: wrongCompany) == nil,
    "parser rejects another company identifier"
  )

  var wrongType = proximityFrame(status: 0x0A)
  wrongType[2] = 0x08
  check(
    AirPodsBLEFrameParser.parse(manufacturerData: wrongType) == nil,
    "parser rejects another Continuity message type"
  )

  var wrongLength = proximityFrame(status: 0x0A)
  wrongLength[3] = 0x18
  check(
    AirPodsBLEFrameParser.parse(manufacturerData: wrongLength) == nil,
    "parser rejects another declared payload length"
  )

  var encrypted = proximityFrame(status: 0x0A)
  encrypted[4] = 0x07
  check(
    AirPodsBLEFrameParser.parse(manufacturerData: encrypted) == nil,
    "parser rejects a non-plaintext prefix"
  )

  check(
    AirPodsBLEFrameParser.parse(
      manufacturerData: proximityFrame(productID: 0x200A, status: 0x0A)
    ) == nil,
    "parser excludes AirPods Max"
  )
  check(
    AirPodsBLEFrameParser.parse(
      manufacturerData: proximityFrame(productID: 0x201C, status: 0x0A)
    ) == nil,
    "parser excludes catalog-only product variants"
  )
  check(
    AirPodsBLEFrameParser.parse(
      manufacturerData: proximityFrame(productID: 0x2012, status: 0x0A)
    ) == nil,
    "parser excludes Beats products"
  )
  check(
    AirPodsBLEFrameParser.parse(
      manufacturerData: proximityFrame(productID: 0xFFFF, status: 0x0A)
    ) == nil,
    "parser excludes unknown products"
  )
  check(
    AirPodsBLEFrameParser.parse(manufacturerData: Data([0x4C, 0x00])) == nil,
    "parser rejects truncated frames"
  )
}

func runAirPodsBLEFrameTests() {
  testAirPodsBLEFrameParserOrientation()
  testAirPodsBLEFrameParserValidation()
}
