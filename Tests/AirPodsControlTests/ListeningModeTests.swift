import Testing

@testable import AirPodsControlCore

@Suite("Listening modes")
struct ListeningModeTests {
  @Test("Keeps canonical tokens and the Bluetooth numeric mapping")
  func listeningModeVocabularyAndBluetoothMapping() {
    #expect(
      ListeningMode.allCases.map(\.rawValue)
        == ["off", "transparency", "adaptive", "noise-cancellation"],
      "listening modes retain canonical order"
    )
    #expect(ListeningMode(token: "off") == .off, "canonical Off token parses")
    #expect(ListeningMode(token: "anc") == .noiseCancellation, "ANC alias parses")
    #expect(ListeningMode(token: "normal") == nil, "private raw names are not public tokens")
    #expect(
      BluetoothListeningModeMapping.modeByRawValue == [
        1: .off,
        2: .noiseCancellation,
        3: .transparency,
        4: .adaptive,
      ],
      "literal Bluetooth raw values map to canonical modes"
    )
    #expect(
      BluetoothListeningModeMapping.modeByRawValue[0] == nil
        && BluetoothListeningModeMapping.modeByRawValue[5] == nil,
      "unknown Bluetooth raw values stay unmapped"
    )
  }

  @Test("Resolves Off fallback only after an accepted mismatched or missing readback")
  func offFallbackResolutionSeams() {
    let verified = resolveListeningModeWrite(
      requested: .off,
      setterAccepted: false,
      observed: .off,
      transparencySupported: true
    )
    #expect(!verified.verified, "a rejected setter never verifies from readback alone")
    #expect(verified.state == .off, "rejected matching readback still reports observed Off")
    #expect(!verified.inferredOffFallback, "rejected matching Off is not inferred")

    let rejected = resolveListeningModeWrite(
      requested: .off,
      setterAccepted: false,
      observed: .noiseCancellation,
      transparencySupported: true
    )
    #expect(rejected.state == .noiseCancellation, "rejected Off preserves observed state")
    #expect(!rejected.inferredOffFallback, "rejected Off is not inferred")

    let rejectedUnknown = resolveListeningModeWrite(
      requested: .off,
      setterAccepted: false,
      observed: nil,
      transparencySupported: true
    )
    #expect(rejectedUnknown.state == nil, "rejected Off preserves unknown state as null")

    let unsupported = resolveListeningModeWrite(
      requested: .off,
      setterAccepted: true,
      observed: .noiseCancellation,
      transparencySupported: false
    )
    #expect(unsupported.state == .noiseCancellation, "unsupported fallback preserves state")
    #expect(!unsupported.inferredOffFallback, "unsupported fallback is not inferred")

    let nonOff = resolveListeningModeWrite(
      requested: .adaptive,
      setterAccepted: true,
      observed: .noiseCancellation,
      transparencySupported: true
    )
    #expect(nonOff.state == .noiseCancellation, "non-Off preserves observed state")
    #expect(!nonOff.inferredOffFallback, "non-Off writes never infer Transparency")

    for observed: ListeningMode? in [.noiseCancellation, .adaptive, nil] {
      let inferred = resolveListeningModeWrite(
        requested: .off,
        setterAccepted: true,
        observed: observed,
        transparencySupported: true
      )
      #expect(!inferred.verified, "accepted Off with mismatched readback is unverified")
      #expect(inferred.state == .transparency, "accepted Off infers Transparency")
      #expect(inferred.inferredOffFallback, "accepted Off records the inferred fallback")
    }
  }
}
