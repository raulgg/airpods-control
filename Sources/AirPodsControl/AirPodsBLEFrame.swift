import Foundation

struct AirPodsBLEPlacementFrame: Hashable {
  let productID: Int
  let placement: BluetoothEarPlacement
}

enum AirPodsBLEFrameParser {
  private static let appleCompanyIdentifier: [UInt8] = [0x4C, 0x00]
  private static let proximityType: UInt8 = 0x07
  private static let proximityPayloadLength: UInt8 = 25
  private static let plaintextPrefix: UInt8 = 0x01

  static func parse(manufacturerData: Data) -> AirPodsBLEPlacementFrame? {
    let bytes = [UInt8](manufacturerData)
    guard bytes.count == 29,
          bytes[0] == appleCompanyIdentifier[0],
          bytes[1] == appleCompanyIdentifier[1],
          bytes[2] == proximityType,
          bytes[3] == proximityPayloadLength,
          bytes[4] == plaintextPrefix
    else {
      return nil
    }

    let productID = Int(bytes[5]) | Int(bytes[6]) << 8
    guard AppleAudioProducts.supportsBLEEarPlacement(productID: productID) else {
      return nil
    }

    let status = bytes[7]
    let valuesAreFlipped = status & (1 << 5) == 0
    let podInCaseFlip = status & (1 << 6) != 0
    let useBitThreeForLeft = valuesAreFlipped != podInCaseFlip
    let leftBit: UInt8 = useBitThreeForLeft ? 3 : 1
    let rightBit: UInt8 = useBitThreeForLeft ? 1 : 3

    return AirPodsBLEPlacementFrame(
      productID: productID,
      placement: BluetoothEarPlacement(
        left: status & (1 << leftBit) != 0 ? .inEar : .outOfEar,
        right: status & (1 << rightBit) != 0 ? .inEar : .outOfEar
      )
    )
  }
}
