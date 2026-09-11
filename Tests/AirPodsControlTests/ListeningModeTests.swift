import Testing

@testable import AirPodsControlCore

@Suite("Listening modes")
struct ListeningModeTests {
  @Test("Keeps canonical mode order and public token vocabulary")
  func listeningModeVocabulary() {
    #expect(
      ListeningMode.allCases.map(\.rawValue)
        == ["off", "transparency", "adaptive", "noise-cancellation"],
      "listening modes retain canonical order"
    )
    #expect(ListeningMode(token: "off") == .off, "canonical Off token parses")
    #expect(ListeningMode(token: "anc") == .noiseCancellation, "ANC alias parses")
    #expect(ListeningMode(token: "normal") == nil, "private raw names are not public tokens")
  }

  @Test("Shares the canonical Bluetooth listening-mode numeric mapping")
  func bluetoothListeningModeNumericMapping() {
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
      BluetoothListeningModeMapping.rawValueByMode == [
        .off: 1,
        .noiseCancellation: 2,
        .transparency: 3,
        .adaptive: 4,
      ],
      "the reverse mapping is derived from the canonical forward map"
    )

    #expect(BluetoothListeningModeMapping.modeByRawValue[0] == nil, "raw value 0 is unknown")
    #expect(BluetoothListeningModeMapping.modeByRawValue[5] == nil, "raw value 5 is unknown")
    #expect(
      BluetoothListeningModeMapping.modeByRawValue[UInt32.max] == nil,
      "UInt32.max is unknown"
    )
  }

  @Test("Preserves observations when Off fallback cannot be inferred")
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
  }

  @Test(
    "Infers Transparency after accepted Off with mismatching or missing readback",
    arguments: [ListeningMode.noiseCancellation, .adaptive, nil]
  )
  func infersOffFallback(observed: ListeningMode?) {
    let inferred = resolveListeningModeWrite(
      requested: .off,
      setterAccepted: true,
      observed: observed,
      transparencySupported: true
    )
    #expect(!inferred.verified)
    #expect(inferred.state == .transparency)
    #expect(inferred.inferredOffFallback)
  }
}
