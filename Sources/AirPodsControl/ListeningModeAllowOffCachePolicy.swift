import CryptoKit
import Foundation

struct CachedAllowOffEvidence: Equatable {
  let observedAt: Date
  let expiresAt: Date
}

struct AllowOffCacheRecord: Equatable {
  let evidence: CachedAllowOffEvidence
  let key: String
}

enum AllowOffCacheLookup: Equatable {
  case allowed(AllowOffCacheRecord)
  case denied(AllowOffCacheRecord)
  case miss
}

enum AllowOffCacheMutation: Equatable {
  case applied
  case unchanged
  case unavailable
}

struct AllowOffObservation: Equatable {
  let allowsOff: Bool
  let observedAt: Date
}

enum AllowOffCachePolicy {
  static let schemaVersion = 1
  static let saltByteCount = 32
  static let maximumByteCount = 1_048_576
  static let maximumEntryCount = 256
  static let maximumRawUIDByteCount = 4_096

  static func shouldReplaceObservation(
    existing: AllowOffObservation?,
    with candidate: AllowOffObservation
  ) -> Bool {
    guard let existing else { return true }
    if candidate.observedAt != existing.observedAt {
      return candidate.observedAt > existing.observedAt
    }
    return !candidate.allowsOff && existing.allowsOff
  }

  static func isValidTTL(_ ttl: TimeInterval) -> Bool {
    ttl.isFinite && ttl > 0
  }

  static func usableEvidence(
    observedAt: Date,
    ttl: TimeInterval,
    now: () -> Date
  ) -> CachedAllowOffEvidence? {
    let observedSeconds = observedAt.timeIntervalSince1970
    let current = now()
    let currentSeconds = current.timeIntervalSince1970
    guard observedSeconds.isFinite, currentSeconds.isFinite,
          current >= observedAt
    else { return nil }
    let expiresAt = observedAt.addingTimeInterval(ttl)
    guard expiresAt.timeIntervalSince1970.isFinite, current < expiresAt else {
      return nil
    }
    return CachedAllowOffEvidence(observedAt: observedAt, expiresAt: expiresAt)
  }

  static func effectiveObservation(
    _ candidate: AllowOffObservation,
    existing: AllowOffObservation?,
    now: () -> Date
  ) -> AllowOffObservation {
    guard !candidate.allowsOff,
          let existing,
          existing.allowsOff
    else { return candidate }
    let current = now()
    guard current.timeIntervalSince1970.isFinite,
          current >= existing.observedAt
    else {
      return AllowOffObservation(
        allowsOff: false,
        observedAt: existing.observedAt
      )
    }
    return candidate
  }

  static func digestKey(salt: Data, rawDeviceUID: String) -> String? {
    guard salt.count == saltByteCount,
          isValidRawDeviceUID(rawDeviceUID)
    else { return nil }
    var hasher = SHA256()
    hasher.update(data: salt)
    hasher.update(data: Data(rawDeviceUID.utf8))
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func isValidRawDeviceUID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumRawUIDByteCount
  }

  static func isDigestKey(_ value: String) -> Bool {
    value.utf8.count == SHA256.byteCount * 2
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }
}

protocol ListeningModeAllowOffCaching: AnyObject {
  func lookup(rawDeviceUID: String) -> AllowOffCacheLookup
  func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date
  ) -> AllowOffCacheMutation
  func invalidatePositiveObservation(
    rawDeviceUID: String,
    observedAt: Date
  ) -> AllowOffCacheMutation
  func remove(record: AllowOffCacheRecord) -> AllowOffCacheMutation
}

struct PersistedAllowOffCache: Codable {
  let schemaVersion: Int
  let salt: Data
  var positiveEvidence: [String: PersistedAllowOffEvidence]
  var negativeEvidence: [String: PersistedAllowOffEvidence]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case salt
    case positiveEvidence
    case negativeEvidence
  }

  init(
    schemaVersion: Int,
    salt: Data,
    observations: [String: AllowOffObservation]
  ) {
    self.schemaVersion = schemaVersion
    self.salt = salt
    positiveEvidence = observations.compactMapValues { observation in
      observation.allowsOff
        ? PersistedAllowOffEvidence(observedAt: observation.observedAt)
        : nil
    }
    negativeEvidence = observations.compactMapValues { observation in
      observation.allowsOff
        ? nil
        : PersistedAllowOffEvidence(observedAt: observation.observedAt)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    salt = try container.decode(Data.self, forKey: .salt)
    positiveEvidence = try container.decode(
      [String: PersistedAllowOffEvidence].self,
      forKey: .positiveEvidence
    )
    negativeEvidence = try container.decodeIfPresent(
      [String: PersistedAllowOffEvidence].self,
      forKey: .negativeEvidence
    ) ?? [:]
  }

  var observations: [String: AllowOffObservation] {
    var result = positiveEvidence.mapValues {
      AllowOffObservation(allowsOff: true, observedAt: $0.observedAt)
    }
    for (key, evidence) in negativeEvidence {
      let candidate = AllowOffObservation(
        allowsOff: false,
        observedAt: evidence.observedAt
      )
      if AllowOffCachePolicy.shouldReplaceObservation(
        existing: result[key],
        with: candidate
      ) {
        result[key] = candidate
      }
    }
    return result
  }

  var isValid: Bool {
    guard schemaVersion == AllowOffCachePolicy.schemaVersion,
          salt.count == AllowOffCachePolicy.saltByteCount,
          Set(positiveEvidence.keys)
          .union(negativeEvidence.keys)
          .count <= AllowOffCachePolicy.maximumEntryCount
    else {
      return false
    }
    return positiveEvidence.allSatisfy { key, entry in
      AllowOffCachePolicy.isDigestKey(key)
        && entry.observedAt.timeIntervalSince1970.isFinite
    } && negativeEvidence.allSatisfy { key, entry in
      AllowOffCachePolicy.isDigestKey(key)
        && entry.observedAt.timeIntervalSince1970.isFinite
    }
  }
}

struct PersistedAllowOffEvidence: Codable, Equatable {
  let observedAt: Date
}

struct PersistedAllowOffDenyMarker: Codable, Equatable {
  let observedAt: Date
}

enum PersistedAllowOffCacheRead {
  case value(PersistedAllowOffCache)
  case missing
  case invalid
}

enum AllowOffDenyMarkerRead {
  case value(Date)
  case missing
  case invalid
}

// Each caller gets its own coder: JSONEncoder and JSONDecoder are not safe to
// share across the concurrent cache mutation paths.
enum AllowOffCacheCodec {
  static func makeEncoder() -> JSONEncoder {
    let value = JSONEncoder()
    value.dateEncodingStrategy = .secondsSince1970
    value.outputFormatting = [.sortedKeys]
    return value
  }

  static func makeDecoder() -> JSONDecoder {
    let value = JSONDecoder()
    value.dateDecodingStrategy = .secondsSince1970
    return value
  }
}
