import CryptoKit
import Foundation

@testable import AirPodsControlCore

private let testAllowOffCacheSaltByteCount = 32
private let testAllowOffCacheMaximumRawUIDByteCount = 4_096

final class InMemoryListeningModeAllowOffCache: ListeningModeAllowOffCaching {
  private let salt: Data
  private let ttl: TimeInterval
  private let now: () -> Date
  private let lock = NSLock()
  private var positiveEvidence: [String: Date] = [:]
  private var negativeEvidence: [String: Date] = [:]
  private var denialEvidence: [String: Date] = [:]

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
    let deniedAt = denialEvidence[key]
    lock.unlock()
    if let negativeObservedAt,
      negativeObservedAt >= observedAt ?? .distantPast,
      let deniedAt,
      deniedAt >= negativeObservedAt,
      let evidence = usableEvidence(observedAt: deniedAt)
    {
      return .denied(AllowOffCacheRecord(evidence: evidence, key: key))
    }
    guard let observedAt, let evidence = usableEvidence(observedAt: observedAt) else {
      return .miss
    }
    return .allowed(AllowOffCacheRecord(evidence: evidence, key: key))
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
      guard denialEvidence[key] ?? .distantPast < observedAt else {
        return .unchanged
      }
      guard existingNegative ?? .distantPast < observedAt,
        existingPositive ?? .distantPast < observedAt
      else { return .unchanged }
      negativeEvidence.removeValue(forKey: key)
      positiveEvidence[key] = observedAt
    } else {
      let effectiveObservedAt = effectiveNegativeObservedAt(
        observedAt: observedAt,
        existingPositive: existingPositive
      )
      guard existingPositive ?? .distantPast <= effectiveObservedAt,
        existingNegative ?? .distantPast < effectiveObservedAt
      else {
        guard existingNegative != nil,
          denialEvidence[key] ?? .distantPast < effectiveObservedAt
        else {
          return .unchanged
        }
        denialEvidence[key] = effectiveObservedAt
        return .applied
      }
      positiveEvidence.removeValue(forKey: key)
      negativeEvidence[key] = effectiveObservedAt
      denialEvidence[key] = effectiveObservedAt
    }
    return .applied
  }

  func invalidatePositiveObservation(
    rawDeviceUID: String,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    guard let key = testDigestKey(salt: salt, rawDeviceUID: rawDeviceUID) else {
      return .unavailable
    }
    guard observedAt.timeIntervalSince1970.isFinite else { return .unavailable }
    lock.lock()
    defer { lock.unlock() }
    let effectiveObservedAt = effectiveNegativeObservedAt(
      observedAt: observedAt,
      existingPositive: positiveEvidence[key]
    )
    if let deniedAt = denialEvidence[key],
      usableEvidence(observedAt: deniedAt) != nil,
      positiveEvidence[key] ?? .distantPast <= deniedAt
    {
      return .unchanged
    }
    guard positiveEvidence[key] ?? .distantPast <= effectiveObservedAt,
      negativeEvidence[key] ?? .distantPast < effectiveObservedAt
    else { return .unchanged }
    positiveEvidence.removeValue(forKey: key)
    negativeEvidence[key] = effectiveObservedAt
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

  private func effectiveNegativeObservedAt(
    observedAt: Date,
    existingPositive: Date?
  ) -> Date {
    guard let existingPositive else { return observedAt }
    let current = now()
    guard current.timeIntervalSince1970.isFinite,
      current >= existingPositive
    else {
      return existingPositive
    }
    return observedAt
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

