import Foundation

final class PersistentListeningModeAllowOffCache: ListeningModeAllowOffCaching {
  static let defaultTTL: TimeInterval = 7 * 24 * 60 * 60

  let fileURL: URL

  private let ttl: TimeInterval
  private let now: () -> Date
  private let storage: AllowOffCacheFileStorage

  init(
    fileURL: URL,
    ttl: TimeInterval = PersistentListeningModeAllowOffCache.defaultTTL,
    now: @escaping () -> Date = Date.init,
    saltGenerator: @escaping () throws -> Data = secureAllowOffCacheSalt,
    markExcludedFromBackup: @escaping (URL) throws -> Void =
      excludeAllowOffCacheURLFromBackup,
    fileManager: FileManager = .default,
    lockRetryObserver: @escaping () -> Void = {}
  ) {
    self.fileURL = fileURL
    self.ttl = ttl
    self.now = now
    self.storage = AllowOffCacheFileStorage(
      fileURL: fileURL,
      saltGenerator: saltGenerator,
      markExcludedFromBackup: markExcludedFromBackup,
      fileManager: fileManager,
      lockRetryObserver: lockRetryObserver
    )
  }

  static func defaultFileURL(
    fileManager: FileManager = .default
  ) throws -> URL {
    try fileManager.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    )
    .appendingPathComponent("io.github.raulgg.airpods-control", isDirectory: true)
    .appendingPathComponent("allow-off-v1.json", isDirectory: false)
  }

  static func systemDefault(
    fileManager: FileManager = .default
  ) -> PersistentListeningModeAllowOffCache? {
    guard let fileURL = try? defaultFileURL(fileManager: fileManager) else {
      return nil
    }
    return PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      fileManager: fileManager
    )
  }

  func lookup(rawDeviceUID: String) -> AllowOffCacheLookup {
    guard AllowOffCachePolicy.isValidTTL(ttl),
          case .value(let document) = storage.readPersistedCache(),
          let key = AllowOffCachePolicy.digestKey(
            salt: document.salt,
            rawDeviceUID: rawDeviceUID
          ),
          let observation = document.observations[key]
    else { return .miss }
    switch storage.readDenyMarker(for: key) {
    case let .value(deniedAt) where deniedAt >= observation.observedAt:
      guard let deniedEvidence = AllowOffCachePolicy.usableEvidence(
        observedAt: deniedAt,
        ttl: ttl,
        now: now
      ) else {
        return .miss
      }
      return .denied(AllowOffCacheRecord(evidence: deniedEvidence, key: key))
    case .missing, .value:
      guard observation.allowsOff,
            let evidence = AllowOffCachePolicy.usableEvidence(
              observedAt: observation.observedAt,
              ttl: ttl,
              now: now
            )
      else { return .miss }
      let record = AllowOffCacheRecord(evidence: evidence, key: key)
      return .allowed(record)
    case .invalid:
      return .miss
    }
  }

  func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    applyObservation(
      rawDeviceUID: rawDeviceUID,
      allowsOff: allowsOff,
      observedAt: observedAt,
      recordsDenial: !allowsOff
    )
  }

  func invalidatePositiveObservation(
    rawDeviceUID: String,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    applyObservation(
      rawDeviceUID: rawDeviceUID,
      allowsOff: false,
      observedAt: observedAt,
      recordsDenial: false
    )
  }

  private func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date,
    recordsDenial: Bool
  ) -> AllowOffCacheMutation {
    guard AllowOffCachePolicy.isValidTTL(ttl),
          AllowOffCachePolicy.isValidRawDeviceUID(rawDeviceUID),
          observedAt.timeIntervalSince1970.isFinite
    else { return .unavailable }
    return storage.withExclusiveMutationLock(
      body: {
        let document: PersistedAllowOffCache
        switch storage.readPersistedCache() {
        case .value(let value):
          document = value
        case .missing:
          guard let created = storage.makeEmptyCache() else { return .unavailable }
          document = created
        case .invalid:
          guard storage.purgeCacheFile() else { return .unavailable }
          guard let created = storage.makeEmptyCache() else { return .unavailable }
          document = created
        }

        guard let key = AllowOffCachePolicy.digestKey(
          salt: document.salt,
          rawDeviceUID: rawDeviceUID
        )
        else { return .unavailable }

        let candidate = AllowOffObservation(
          allowsOff: allowsOff,
          observedAt: observedAt
        )
        var observations = document.observations
        let effectiveCandidate = AllowOffCachePolicy.effectiveObservation(
          candidate,
          existing: observations[key],
          now: now
        )
        if !recordsDenial, !allowsOff {
          switch storage.readDenyMarker(for: key) {
          case .missing:
            break
          case .invalid:
            return .unavailable
          case .value(let deniedAt):
            guard AllowOffCachePolicy.usableEvidence(
              observedAt: deniedAt,
              ttl: ttl,
              now: now
            ) == nil else {
              guard let existing = observations[key],
                    existing.allowsOff,
                    existing.observedAt > deniedAt
              else {
                return .unchanged
              }
              break
            }
          }
        }
        if effectiveCandidate.allowsOff {
          switch storage.readDenyMarker(for: key) {
          case .missing:
            break
          case .invalid:
            return .unavailable
          case .value(let deniedAt):
            guard effectiveCandidate.observedAt > deniedAt else {
              return .unchanged
            }
          }
        }
        guard AllowOffCachePolicy.shouldReplaceObservation(
          existing: observations[key],
          with: effectiveCandidate
        ) else {
          guard recordsDenial, !effectiveCandidate.allowsOff,
                observations[key]?.allowsOff == false
          else {
            return .unchanged
          }
          switch storage.readDenyMarker(for: key) {
          case .value(let deniedAt) where deniedAt >= effectiveCandidate.observedAt:
            return .unchanged
          case .missing, .value:
            return storage.appendDenyMarker(
              for: key,
              observedAt: effectiveCandidate.observedAt
            ) ? .applied : .unavailable
          case .invalid:
            return .unavailable
          }
        }
        observations[key] = effectiveCandidate
        let updated = PersistedAllowOffCache(
          schemaVersion: document.schemaVersion,
          salt: document.salt,
          observations: observations
        )
        guard storage.write(updated) else {
          guard !effectiveCandidate.allowsOff else { return .unavailable }
          return storage.purgeCacheFile() ? .applied : .unavailable
        }
        if recordsDenial {
          guard !allowsOff,
                storage.appendDenyMarker(
                  for: key,
                  observedAt: effectiveCandidate.observedAt
                )
          else { return .unavailable }
        }
        return .applied
      },
      onLockUnavailable: {
        guard recordsDenial, !allowsOff else { return .unavailable }
        return persistDenyMarker(
          rawDeviceUID: rawDeviceUID,
          observedAt: observedAt
        )
      }
    )
  }

  func remove(record: AllowOffCacheRecord) -> AllowOffCacheMutation {
    storage.withExclusiveMutationLock {
      guard case .value(let document) = storage.readPersistedCache() else {
        return purgeInvalidCacheIfNeeded()
      }
      return remove(
        key: record.key,
        observedAt: record.evidence.observedAt,
        from: document
      )
    }
  }

  private func persistDenyMarker(
    rawDeviceUID: String,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    guard case .value(let document) = storage.readPersistedCache(),
          let key = AllowOffCachePolicy.digestKey(
            salt: document.salt,
            rawDeviceUID: rawDeviceUID
          )
    else { return .unavailable }
    let candidate = AllowOffCachePolicy.effectiveObservation(
      AllowOffObservation(allowsOff: false, observedAt: observedAt),
      existing: document.observations[key],
      now: now
    )
    switch storage.readDenyMarker(for: key) {
    case .invalid:
      return .unchanged
    case .value(let existing) where existing >= candidate.observedAt:
      return .unchanged
    case .missing, .value:
      return storage.appendDenyMarker(for: key, observedAt: candidate.observedAt)
        ? .applied
        : .unavailable
    }
  }

  private func remove(
    key: String,
    observedAt: Date,
    from document: PersistedAllowOffCache
  ) -> AllowOffCacheMutation {
    guard let existing = document.observations[key],
          existing.allowsOff,
          existing.observedAt == observedAt
    else { return .unchanged }

    var observations = document.observations
    observations.removeValue(forKey: key)
    let updated = PersistedAllowOffCache(
      schemaVersion: document.schemaVersion,
      salt: document.salt,
      observations: observations
    )
    if storage.write(updated) { return .applied }

    // A failed invalidation must not leave stale positive evidence behind.
    return storage.purgeCacheFile() ? .applied : .unavailable
  }

  private func purgeInvalidCacheIfNeeded() -> AllowOffCacheMutation {
    switch storage.readPersistedCache() {
    case .missing:
      return .unchanged
    case .invalid:
      return storage.purgeCacheFile() ? .applied : .unavailable
    case .value:
      return .unchanged
    }
  }

}
