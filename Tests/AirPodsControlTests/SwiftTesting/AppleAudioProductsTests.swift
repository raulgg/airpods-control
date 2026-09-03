import Testing

@testable import AirPodsControlCore

@Suite("Apple audio products")
struct AppleAudioProductsTests {
  @Test(
    "Identifies product families from Bluetooth and marketing model identifiers",
    arguments: [
      ("BTHeadphones76,8231", SupportReportDeviceFamily.airPods),
      ("btheadphones76,8231", .airPods),
      ("BTHeadphones76,8210", .beats),
      ("BTHeadphones76,60000", .unknownApple),
      ("AirPodsTest1,1", .airPods),
      ("BeatsTest1,1", .beats),
    ]
  )
  func identifiesFamily(
    modelIdentifier: String,
    expected: SupportReportDeviceFamily
  ) {
    #expect(AppleAudioProducts.family(for: modelIdentifier) == expected)
  }

  @Test(
    "Rejects missing, non-Apple, malformed, and oversized identifiers",
    arguments: [
      nil, "BTHeadphones123,456", "BTHeadphones76,8231,0",
      "BTHeadphones76,4294975527", "BTHeadphones76,65536",
    ] as [String?]
  )
  func rejectsInvalidIdentifier(_ modelIdentifier: String?) {
    #expect(AppleAudioProducts.family(for: modelIdentifier) == nil)
    #expect(AppleAudioProducts.product(for: modelIdentifier) == nil)
  }

  @Test("Keeps unknown Apple product IDs available for exploratory reports")
  func preservesUnknownAppleProduct() throws {
    let unknown = try #require(AppleAudioProducts.product(for: "BTHeadphones76,60000"))
    #expect(unknown.family == .unknownApple)
    #expect(unknown.modelName == nil)
    #expect(unknown.bluetoothProductID == 60000)
  }
}
