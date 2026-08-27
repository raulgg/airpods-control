func testListeningModeVocabulary() {
  check(
    ListeningMode.allCases.map(\.rawValue)
      == ["off", "transparency", "adaptive", "noise-cancellation"],
    "listening modes retain canonical order"
  )
  check(ListeningMode(token: "off") == .off, "canonical Off token parses")
  check(ListeningMode(token: "anc") == .noiseCancellation, "ANC alias parses")
  check(ListeningMode(token: "normal") == nil, "private raw names are not public tokens")
}

func testOffFallbackResolutionSeams() {
  let inferenceCases: [(String, ListeningMode?)] = [
    ("noise cancellation", .noiseCancellation),
    ("Adaptive", .adaptive),
    ("missing", nil),
  ]

  let verified = resolveListeningModeWrite(
    requested: .off,
    setterAccepted: false,
    observed: .off,
    transparencySupported: true
  )
  check(!verified.verified, "a rejected setter never verifies from readback alone")
  check(verified.state == .off, "rejected matching readback still reports observed Off")
  check(!verified.inferredOffFallback, "rejected matching Off is not inferred")

  for (description, observed) in inferenceCases {
    let inferred = resolveListeningModeWrite(
      requested: .off,
      setterAccepted: true,
      observed: observed,
      transparencySupported: true
    )
    check(!inferred.verified, "accepted Off does not verify \(description)")
    check(inferred.state == .transparency, "accepted Off infers \(description) fallback")
    check(inferred.inferredOffFallback, "accepted Off marks \(description) inference")
  }

  let rejected = resolveListeningModeWrite(
    requested: .off,
    setterAccepted: false,
    observed: .noiseCancellation,
    transparencySupported: true
  )
  check(rejected.state == .noiseCancellation, "rejected Off preserves observed state")
  check(!rejected.inferredOffFallback, "rejected Off is not inferred")

  let rejectedUnknown = resolveListeningModeWrite(
    requested: .off,
    setterAccepted: false,
    observed: nil,
    transparencySupported: true
  )
  check(rejectedUnknown.state == nil, "rejected Off preserves unknown state as null")

  let unsupported = resolveListeningModeWrite(
    requested: .off,
    setterAccepted: true,
    observed: .noiseCancellation,
    transparencySupported: false
  )
  check(unsupported.state == .noiseCancellation, "unsupported fallback preserves state")
  check(!unsupported.inferredOffFallback, "unsupported fallback is not inferred")

  let nonOff = resolveListeningModeWrite(
    requested: .adaptive,
    setterAccepted: true,
    observed: .noiseCancellation,
    transparencySupported: true
  )
  check(nonOff.state == .noiseCancellation, "non-Off preserves observed state")
  check(!nonOff.inferredOffFallback, "non-Off writes never infer Transparency")
}

func runListeningModeTests() {
  testListeningModeVocabulary()
  testOffFallbackResolutionSeams()
}
