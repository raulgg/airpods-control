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
    case .unavailable:
      return nil
    case .value(let modes) where modes.contains(.off):
      var storedRecord: AllowOffCacheRecord?
      var mutation: AllowOffCacheMutation = .unavailable
      withUnambiguousRawUID { rawDeviceUID in
        mutation = cache.applyObservation(
          rawDeviceUID: rawDeviceUID,
          allowsOff: true,
          observedAt: observedAt
        )
        if case .hit(let record) = cache.lookup(rawDeviceUID: rawDeviceUID) {
          storedRecord = record
        }
      }
      if mutation == .unchanged, storedRecord == nil {
        return nil
      }
      // Fresh AV evidence can authorize this invocation even when the
      // disposable cache cannot be correlated or written.
      return .live(cache: storedRecord == nil ? nil : cache, record: storedRecord)
    case .value:
      withUnambiguousRawUID { rawDeviceUID in
        _ = cache.applyObservation(
          rawDeviceUID: rawDeviceUID,
          allowsOff: false,
          observedAt: observedAt
        )
      }
      return nil
    }
  }

  func observeCurrentOff(observedAt: Date) {
    withUnambiguousRawUID { rawDeviceUID in
      _ = cache.applyObservation(
        rawDeviceUID: rawDeviceUID,
        allowsOff: true,
        observedAt: observedAt
      )
    }
  }

  func cachedAuthorization() -> ListeningModeAllowOffAuthorization? {
    var record: AllowOffCacheRecord?
    withUnambiguousRawUID { rawDeviceUID in
      if case .hit(let value) = cache.lookup(rawDeviceUID: rawDeviceUID) {
        record = value
      }
    }
    guard let record else {
      logger.debug("allow_off_cache", "miss")
      return nil
    }
    logger.debug("allow_off_cache", "hit")
    let age = max(0, min(604_800, Int(now().timeIntervalSince(record.evidence.observedAt))))
    logger.debug("allow_off_cache.age_seconds", age)
    return .cached(cache: cache, record: record)
  }

  private func withUnambiguousRawUID(_ body: (String) -> Void) {
    guard collisionAudioDeviceIDs.contains(targetAudioDeviceID),
      !collisionAudioDeviceIDs.isEmpty
    else { return }

    var values: [(AudioDeviceID, String)] = []
    for audioDeviceID in collisionAudioDeviceIDs {
      guard case .value(.some(let rawUID)) = backend.readDeviceUID(for: audioDeviceID),
        !rawUID.isEmpty,
        rawUID.utf8.count <= 4_096
      else { return }
      values.append((audioDeviceID, rawUID))
    }
    guard let targetUID = values.first(where: { $0.0 == targetAudioDeviceID })?.1,
      values.filter({ $0.1 == targetUID }).count == 1
    else { return }
    body(targetUID)
  }
}
