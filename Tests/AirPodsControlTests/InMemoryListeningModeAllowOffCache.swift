import CryptoKit
import Foundation

private let testAllowOffCacheSaltByteCount = 32
private let testAllowOffCacheMaximumRawUIDByteCount = 4_096

final class InMemoryListeningModeAllowOffCache: ListeningModeAllowOffCaching {
  private let salt: Data
  private let ttl: TimeInterval
  private let now: () -> Date
  private let lock = NSLock()
  private var positiveEvidence: [String: Date] = [:]
  private var negativeEvidence: [String: Date] = [:]

  init?(
    salt: Data,
    ttl: TimeInterval = PersistentListeningModeAllowOffCache.defaultTTL,
    now: @escaping () -> Date = Date.init
  ) {
    guard salt.count == testAllowOffCacheSaltByteCount, ttl.isFinite, ttl > 0 else {
      return nil
    }
    self.salt = salt
    self.ttl = ttl
    self.now = now
  }

  func lookup(rawDeviceUID: String) -> AllowOffCacheLookup {
    guard let key = testDigestKey(salt: salt, rawDeviceUID: rawDeviceUID) else {
      return .miss
    }
    lock.lock()
    let observedAt = positiveEvidence[key]
    let negativeObservedAt = negativeEvidence[key]
    lock.unlock()
    guard let observedAt,
      negativeObservedAt ?? .distantPast < observedAt,
      let evidence = usableEvidence(observedAt: observedAt)
    else { return .miss }
    return .hit(AllowOffCacheRecord(evidence: evidence, key: key))
  }

  func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    guard let key = testDigestKey(salt: salt, rawDeviceUID: rawDeviceUID) else {
      return .unavailable
    }
    guard observedAt.timeIntervalSince1970.isFinite else { return .unavailable }
    lock.lock()
    defer { lock.unlock() }
    let existingPositive = positiveEvidence[key]
    let existingNegative = negativeEvidence[key]
    if allowsOff {
      guard existingNegative ?? .distantPast < observedAt,
        existingPositive ?? .distantPast <= observedAt
      else { return .unchanged }
      negativeEvidence.removeValue(forKey: key)
      positiveEvidence[key] = observedAt
    } else {
      guard existingPositive ?? .distantPast <= observedAt,
        existingNegative ?? .distantPast < observedAt
      else { return .unchanged }
      positiveEvidence.removeValue(forKey: key)
      negativeEvidence[key] = observedAt
    }
    return .applied
  }

  func remove(record: AllowOffCacheRecord) -> AllowOffCacheMutation {
    lock.lock()
    defer { lock.unlock() }
    guard let observedAt = positiveEvidence[record.key],
      observedAt == record.evidence.observedAt
    else { return .unchanged }
    positiveEvidence.removeValue(forKey: record.key)
    return .applied
  }

  private func usableEvidence(observedAt: Date) -> CachedAllowOffEvidence? {
    let current = now()
    guard current.timeIntervalSince1970.isFinite, current >= observedAt else {
      return nil
    }
    let expiresAt = observedAt.addingTimeInterval(ttl)
    guard expiresAt.timeIntervalSince1970.isFinite, current < expiresAt else {
      return nil
    }
    return CachedAllowOffEvidence(observedAt: observedAt, expiresAt: expiresAt)
  }
}

private func testDigestKey(salt: Data, rawDeviceUID: String) -> String? {
  guard salt.count == testAllowOffCacheSaltByteCount,
    !rawDeviceUID.isEmpty,
    rawDeviceUID.utf8.count <= testAllowOffCacheMaximumRawUIDByteCount
  else { return nil }
  var hasher = SHA256()
  hasher.update(data: salt)
  hasher.update(data: Data(rawDeviceUID.utf8))
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
