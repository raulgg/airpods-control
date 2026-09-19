import CoreAudio
import Foundation

final class ListeningModeAllowOffAuthorization {
  let cachedEvidence: CachedAllowOffEvidence?

  private let cache: (any ListeningModeAllowOffCaching)?
  private let record: AllowOffCacheRecord?

  private init(
    cachedEvidence: CachedAllowOffEvidence?,
    cache: (any ListeningModeAllowOffCaching)?,
    record: AllowOffCacheRecord?
  ) {
    self.cachedEvidence = cachedEvidence
    self.cache = cache
    self.record = record
  }

  static func live(
    cache: (any ListeningModeAllowOffCaching)?,
    record: AllowOffCacheRecord?
  ) -> ListeningModeAllowOffAuthorization {
    ListeningModeAllowOffAuthorization(
      cachedEvidence: nil,
      cache: cache,
      record: record
    )
  }

  static func cached(
    cache: any ListeningModeAllowOffCaching,
    record: AllowOffCacheRecord
  ) -> ListeningModeAllowOffAuthorization {
    ListeningModeAllowOffAuthorization(
      cachedEvidence: record.evidence,
      cache: cache,
      record: record
    )
  }

  func invalidate() {
    guard let cache, let record else { return }
    _ = cache.remove(record: record)
  }
}

final class ListeningModeAllowOffCorrelation {
  private let targetAudioDeviceID: AudioDeviceID
  private let collisionAudioDeviceIDs: [AudioDeviceID]
  private let backend: any AudioRoutingBackend
  private let cache: any ListeningModeAllowOffCaching
  private let logger: DebugLogger
  private let now: () -> Date

  init(
    targetAudioDeviceID: AudioDeviceID,
    collisionAudioDeviceIDs: [AudioDeviceID],
    backend: any AudioRoutingBackend,
    cache: any ListeningModeAllowOffCaching,
    logger: DebugLogger,
    now: @escaping () -> Date = Date.init
  ) {
    self.targetAudioDeviceID = targetAudioDeviceID
    self.collisionAudioDeviceIDs = Array(Set(collisionAudioDeviceIDs)).sorted()
    self.backend = backend
    self.cache = cache
    self.logger = logger
    self.now = now
  }

  func captureObservationTime() -> Date {
    now()
  }

  func observeAvailability(
    _ observation: ListeningModeAvailabilityObservation,
    observedAt: Date
  ) -> ListeningModeAllowOffAuthorization? {
    switch observation {
    case .unavailable, .readError, .partial:
      return nil
    case .value(let modes) where modes.contains(.off):
      // Fresh AV evidence can authorize this invocation even when the
      // disposable cache cannot be correlated or written.
      guard let rawDeviceUID = unambiguousRawDeviceUID() else {
        return .live(cache: nil, record: nil)
      }
      let mutation = cache.applyObservation(
        rawDeviceUID: rawDeviceUID,
        allowsOff: true,
        observedAt: observedAt
      )
      if case .allowed(let record) = cache.lookup(rawDeviceUID: rawDeviceUID) {
        return .live(cache: cache, record: record)
      }
      if mutation == .unchanged {
        return nil
      }
      return .live(cache: nil, record: nil)
    case .value:
      invalidatePositiveObservation(noNewerThan: observedAt)
      return nil
    }
  }

  func observeCurrentOff(observedAt: Date) {
    guard let rawDeviceUID = unambiguousRawDeviceUID() else { return }
    _ = cache.applyObservation(
      rawDeviceUID: rawDeviceUID,
      allowsOff: true,
      observedAt: observedAt
    )
  }

  func observeDenial(observedAt: Date) {
    guard let rawDeviceUID = unambiguousRawDeviceUID() else { return }
    _ = cache.applyObservation(
      rawDeviceUID: rawDeviceUID,
      allowsOff: false,
      observedAt: observedAt
    )
  }

  func cachedAuthorization() -> ListeningModeAllowOffAuthorization? {
    guard let rawDeviceUID = unambiguousRawDeviceUID(),
          case .allowed(let record) = cache.lookup(rawDeviceUID: rawDeviceUID)
    else {
      logger.debug("allow_off_cache", "miss")
      return nil
    }
    logger.debug("allow_off_cache", "hit")
    logger.debug(
      "allow_off_cache.age_seconds",
      boundedCacheAgeSeconds(for: record.evidence)
    )
    return .cached(cache: cache, record: record)
  }

  func hasCachedDenial() -> Bool {
    guard let rawDeviceUID = unambiguousRawDeviceUID(),
          case .denied = cache.lookup(rawDeviceUID: rawDeviceUID)
    else { return false }
    return true
  }

  private func invalidatePositiveObservation(noNewerThan observedAt: Date) {
    guard let rawDeviceUID = unambiguousRawDeviceUID() else { return }
    _ = cache.invalidatePositiveObservation(
      rawDeviceUID: rawDeviceUID,
      observedAt: observedAt
    )
  }

  private func boundedCacheAgeSeconds(for evidence: CachedAllowOffEvidence) -> Int {
    let age = Int(now().timeIntervalSince(evidence.observedAt))
    let ttl = Int(evidence.expiresAt.timeIntervalSince(evidence.observedAt))
    let cap = ttl > 0 ? ttl : Int(PersistentListeningModeAllowOffCache.defaultTTL)
    return max(0, min(cap, age))
  }

  private func unambiguousRawDeviceUID() -> String? {
    guard collisionAudioDeviceIDs.contains(targetAudioDeviceID),
          !collisionAudioDeviceIDs.isEmpty
    else { return nil }

    var values: [(AudioDeviceID, String)] = []
    for audioDeviceID in collisionAudioDeviceIDs {
      guard case .value(.some(let rawUID)) = backend.readDeviceUID(for: audioDeviceID),
            AllowOffCachePolicy.isValidRawDeviceUID(rawUID)
      else { return nil }
      values.append((audioDeviceID, rawUID))
    }
    guard let targetUID = values.first(where: { $0.0 == targetAudioDeviceID })?.1,
          values.filter({ $0.1 == targetUID }).count == 1
    else { return nil }
    return targetUID
  }
}
