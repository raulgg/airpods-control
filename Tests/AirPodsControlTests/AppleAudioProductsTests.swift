func testAppleAudioProductsFamilyFromModelIdentifier() {
  check(
    AppleAudioProducts.family(for: "BTHeadphones76,8231") == .airPods,
    "the Bluetooth model identifier of AirPods Pro 3 resolves to AirPods"
  )
  check(
    AppleAudioProducts.family(for: "btheadphones76,8231") == .airPods,
    "the Bluetooth model identifier prefix is matched case-insensitively"
  )
  check(
    AppleAudioProducts.family(for: "BTHeadphones76,8210") == .beats,
    "a known Beats product ID resolves to the exploratory Beats family"
  )
  check(
    AppleAudioProducts.family(for: "BTHeadphones76,60000") == .unknownApple,
    "an unlisted Apple product ID still produces an exploratory report"
  )
  check(
    AppleAudioProducts.family(for: "BTHeadphones123,456") == nil,
    "a non-Apple vendor ID stays unidentifiable"
  )
  check(
    AppleAudioProducts.family(for: "BTHeadphones76,8231,0") == nil,
    "a malformed Bluetooth model identifier stays unidentifiable"
  )
  check(
    AppleAudioProducts.family(for: "AirPodsTest1,1") == .airPods,
    "a marketing-style model identifier still matches by name"
  )
  check(
    AppleAudioProducts.family(for: "BeatsTest1,1") == .beats,
    "a marketing-style Beats identifier still matches by name"
  )
  check(
    AppleAudioProducts.family(for: nil) == nil,
    "missing model metadata is unidentifiable"
  )

  let pro3 = AppleAudioProducts.product(for: "BTHeadphones76,8231")
  check(pro3?.modelName == "AirPods Pro 3", "product ID 0x2027 resolves to AirPods Pro 3")
  check(pro3?.bluetoothProductID == 0x2027, "the decimal product field decodes to hex")

  let pro2Lightning = AppleAudioProducts.product(for: "BTHeadphones76,8212")
  check(
    pro2Lightning?.family == .airPods,
    "product ID 0x2014 resolves to AirPods"
  )
  check(
    pro2Lightning?.modelName == "AirPods Pro 2 (Lightning)",
    "product ID 0x2014 resolves to AirPods Pro 2 (Lightning)"
  )
  check(
    pro2Lightning?.bluetoothProductID == 0x2014,
    "AirPods Pro 2 (Lightning) product ID is decoded"
  )

  let fitPro = AppleAudioProducts.product(for: "BTHeadphones76,8210")
  check(
    fitPro?.modelName == "Beats Fit Pro",
    "product ID 0x2012 resolves to Beats Fit Pro"
  )

  let unknown = AppleAudioProducts.product(for: "BTHeadphones76,60000")
  check(unknown?.family == .unknownApple, "an unlisted Apple product ID stays exploratory")
  check(unknown?.modelName == nil, "an unlisted Apple product ID has no model name")
  check(
    unknown?.bluetoothProductID == 60000,
    "an unlisted Apple product ID is still decoded for the report"
  )

  let marketing = AppleAudioProducts.product(for: "AirPodsTest1,1")
  check(
    marketing?.modelName == nil && marketing?.bluetoothProductID == nil,
    "a marketing-style identifier resolves a family without inventing a product"
  )

  check(AppleAudioProducts.hexProductID(0x2F) == "0x002F", "hex product IDs are zero-padded")
  check(AppleAudioProducts.hexProductID(60000) == "0xEA60", "hex product IDs use uppercase hex")

  check(
    AppleAudioProducts.family(for: "BTHeadphones76,4294975527") == nil,
    "an oversized product field is rejected instead of truncated to 32 bits"
  )
  check(
    AppleAudioProducts.product(for: "BTHeadphones76,65536") == nil,
    "product fields above 0xFFFF are rejected"
  )
  check(
    AppleAudioProducts.product(for: "BTHeadphones76,65535")?.family == .unknownApple,
    "the 16-bit boundary product ID is still decoded"
  )
}

func runAppleAudioProductsTests() {
  testAppleAudioProductsFamilyFromModelIdentifier()
}
