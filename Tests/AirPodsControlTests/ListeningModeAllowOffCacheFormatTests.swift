import Foundation
import Testing

@testable import AirPodsControlCore

private let allowOffCacheFormatFixtureSalt = Data(0..<32)
private let allowOffCacheFormatFixturePositiveKey = String(repeating: "1", count: 64)
private let allowOffCacheFormatFixtureNegativeKey = String(repeating: "2", count: 64)

@Suite("Persistent Allow Off cache format")
struct ListeningModeAllowOffCacheFormatTests {
  @Test("Keeps schema 1 encoding stable")
  func schemaV1EncodingRemainsStable() throws {
    let document = PersistedAllowOffCache(
      schemaVersion: 1,
      salt: allowOffCacheFormatFixtureSalt,
      observations: [
        allowOffCacheFormatFixturePositiveKey: AllowOffObservation(
          allowsOff: true,
          observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        allowOffCacheFormatFixtureNegativeKey: AllowOffObservation(
          allowsOff: false,
          observedAt: Date(timeIntervalSince1970: 1_700_000_010)
        ),
      ]
    )
    let encoded = try AllowOffCacheCodec.encoder.encode(document)
    let expected = Data(
      #"{"negativeEvidence":{"2222222222222222222222222222222222222222222222222222222222222222":{"observedAt":1700000010}},"positiveEvidence":{"1111111111111111111111111111111111111111111111111111111111111111":{"observedAt":1700000000}},"salt":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","schemaVersion":1}"#.utf8
    )

    #expect(encoded == expected)
  }

  @Test("Decodes schema 1 documents without negative evidence")
  func schemaV1DecodesLegacyDocumentWithoutNegativeEvidence() throws {
    let legacyDocument = Data(
      #"{"positiveEvidence":{"1111111111111111111111111111111111111111111111111111111111111111":{"observedAt":1700000000}},"salt":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","schemaVersion":1}"#.utf8
    )
    let decoded = try AllowOffCacheCodec.decoder.decode(
      PersistedAllowOffCache.self,
      from: legacyDocument
    )

    #expect(decoded.isValid)
    #expect(decoded.negativeEvidence.isEmpty)
    #expect(
      decoded.observations == [
        allowOffCacheFormatFixturePositiveKey: AllowOffObservation(
          allowsOff: true,
          observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
      ]
    )
  }
}
