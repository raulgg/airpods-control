import Foundation

struct SupportReportProduct {
  let family: SupportReportDeviceFamily
  let modelName: String?
  let bluetoothProductID: Int?
}

// The known Apple and Beats audio products, plus the Bluetooth model-identifier
// decoding that resolves device metadata against them.
enum AppleAudioProducts {
  private static let appleVendorID = 76
  private static let bluetoothModelIDPrefix = "BTHeadphones"

  // Product IDs and model names from MagicPodsCore's AapModelIds table,
  // cross-checked against AirPodsDesktop's AppleCP.cpp, librepods, and
  // The Apple Wiki. Names follow docs/compatibility.md:
  // https://github.com/steam3d/MagicPodsCore/blob/main/src/sdk/aap/enums/AapModelIds.h
  private static let catalog:
    [Int: (family: SupportReportDeviceFamily, name: String)] = [
      0x2002: (.airPods, "AirPods 1"),
      0x200A: (.airPods, "AirPods Max 1 (Lightning)"),
      0x200E: (.airPods, "AirPods Pro 1"),
      0x200F: (.airPods, "AirPods 2"),
      0x2013: (.airPods, "AirPods 3"),
      0x2014: (.airPods, "AirPods Pro 2 (Lightning)"),
      0x2019: (.airPods, "AirPods 4"),
      0x201B: (.airPods, "AirPods 4 (ANC)"),
      0x201F: (.airPods, "AirPods Max 1 (USB-C)"),
      0x2024: (.airPods, "AirPods Pro 2 (USB-C)"),
      0x2027: (.airPods, "AirPods Pro 3"),
      0x202D: (.airPods, "AirPods Max 2"),
      0x2003: (.beats, "Powerbeats3"),
      0x2005: (.beats, "BeatsX"),
      0x2006: (.beats, "Beats Solo3"),
      0x2009: (.beats, "Beats Studio3 Wireless"),
      0x200B: (.beats, "Powerbeats Pro"),
      0x200C: (.beats, "Beats Solo Pro"),
      0x200D: (.beats, "Powerbeats 4"),
      0x2010: (.beats, "Beats Flex"),
      0x2011: (.beats, "Beats Studio Buds"),
      0x2012: (.beats, "Beats Fit Pro"),
      0x2016: (.beats, "Beats Studio Buds +"),
      0x2017: (.beats, "Beats Studio Pro"),
      0x201D: (.beats, "Powerbeats Pro 2"),
      0x2025: (.beats, "Beats Solo 4"),
      0x2026: (.beats, "Beats Solo Buds"),
      0x202F: (.beats, "Powerbeats Fit"),
    ]

  static func family(for modelIdentifier: String?) -> SupportReportDeviceFamily? {
    product(for: modelIdentifier)?.family
  }

  static func product(for modelIdentifier: String?) -> SupportReportProduct? {
    guard let modelIdentifier else { return nil }
    if let bluetoothIDs = bluetoothIdentifiers(for: modelIdentifier) {
      guard bluetoothIDs.vendorID == appleVendorID else { return nil }
      guard let known = catalog[bluetoothIDs.productID] else {
        return SupportReportProduct(
          family: .unknownApple,
          modelName: nil,
          bluetoothProductID: bluetoothIDs.productID
        )
      }
      return SupportReportProduct(
        family: known.family,
        modelName: known.name,
        bluetoothProductID: bluetoothIDs.productID
      )
    }
    let normalized = modelIdentifier.lowercased()
    if normalized.contains("airpods") {
      return SupportReportProduct(
        family: .airPods, modelName: nil, bluetoothProductID: nil
      )
    }
    if normalized.contains("beats") {
      return SupportReportProduct(
        family: .beats, modelName: nil, bluetoothProductID: nil
      )
    }
    return nil
  }

  static func hexProductID(_ productID: Int) -> String {
    "0x" + String(format: "%04X", productID)
  }

  private static func bluetoothIdentifiers(
    for modelIdentifier: String
  ) -> (vendorID: Int, productID: Int)? {
    let prefix = modelIdentifier.prefix(bluetoothModelIDPrefix.count)
    guard prefix.lowercased() == bluetoothModelIDPrefix.lowercased() else { return nil }
    let fields = modelIdentifier.dropFirst(prefix.count).components(separatedBy: ",")
    guard fields.count == 2,
          let vendorID = decimalIdentifier(fields[0]),
          let productID = decimalIdentifier(fields[1])
    else {
      return nil
    }
    return (vendorID, productID)
  }

  // Bluetooth vendor and product IDs are 16-bit. Larger fields would also
  // truncate in the %04X hex rendering, so reject them outright.
  private static let maximumBluetoothIdentifierValue = 0xFFFF

  private static func decimalIdentifier(_ field: String) -> Int? {
    guard !field.isEmpty,
          field.allSatisfy({ $0.isASCII && $0.isNumber }),
          let value = Int(field),
          value <= maximumBluetoothIdentifierValue
    else {
      return nil
    }
    return value
  }
}
