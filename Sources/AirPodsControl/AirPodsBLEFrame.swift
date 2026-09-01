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
          Array(bytes.prefix(2)) == appleCompanyIdentifier
    else {
      return nil
    }
    return parseAppleContinuityData(Data(bytes.dropFirst(2)))
  }

  private static func parseAppleContinuityData(
    _ data: Data
  ) -> AirPodsBLEPlacementFrame? {
    let continuity = [UInt8](data)[...]

    guard continuity.count == 27,
          continuity[continuity.startIndex] == proximityType,
          continuity[continuity.startIndex + 1] == proximityPayloadLength,
          continuity[continuity.startIndex + 2] == plaintextPrefix
    else {
      return nil
    }

    let productID = Int(continuity[continuity.startIndex + 3])
      | Int(continuity[continuity.startIndex + 4]) << 8
    guard AppleAudioProducts.supportsBLEEarPlacement(productID: productID) else {
      return nil
    }

    let status = continuity[continuity.startIndex + 5]
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
