import Darwin
import Dispatch
import Foundation

private final class AllowOffCacheTestClock {
  var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func read() -> Date {
    value
  }
}

private enum AllowOffCacheTestError: Error {
  case unavailable
}

private let allowOffCacheTestSalt = Data(0..<32)

private func withTemporaryAllowOffCache(
  _ body: (URL) -> Void
) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "airpods-control-allow-off-cache-tests-\(UUID().uuidString)",
    isDirectory: true
  )
  do {
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
  } catch {
    check(false, "allow-off cache test creates its temporary root")
    return
  }
  defer { try? FileManager.default.removeItem(at: root) }
  body(
    root
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent("allow-off-v1.json", isDirectory: false)
  )
}

private func allowOffRecord(
  from lookup: AllowOffCacheLookup
) -> AllowOffCacheRecord? {
  guard case .hit(let record) = lookup else { return nil }
  return record
}

private func allowOffCacheJSON(
  at fileURL: URL
) -> [String: Any]? {
  guard let data = try? Data(contentsOf: fileURL),
    let value = try? JSONSerialization.jsonObject(with: data),
    let object = value as? [String: Any]
  else { return nil }
  return object
}

private func allowOffCachePermissions(at url: URL) -> Int? {
  guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
    let permissions = attributes[.posixPermissions] as? NSNumber
  else { return nil }
  return permissions.intValue
}

private func withHeldAllowOffCacheFileLock(
  fileURL: URL,
  _ body: () -> Void
) {
  let lockURL = fileURL.deletingLastPathComponent()
    .appendingPathComponent("allow-off-v1.lock")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
  process.arguments = ["-t", "0", lockURL.path, "/bin/sleep", "2"]
  do {
    try process.run()
  } catch {
    check(false, "lock contention test starts a lock holder")
    return
  }
  defer {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
  }

  let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else {
    check(false, "lock contention test opens the cache lock file")
    return
  }
  defer { Darwin.close(descriptor) }

  let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
  while DispatchTime.now().uptimeNanoseconds < deadline {
    if Darwin.lockf(descriptor, F_TLOCK, 0) == -1,
      errno == EACCES || errno == EAGAIN
    {
      body()
      return
    }
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    _ = Darwin.usleep(1_000)
  }
  check(false, "lock contention fixture acquires the cache lock")
}

func runListeningModeAllowOffCacheTests() {
  do {
    let expectedSuffix =
      "/Library/Caches/io.github.raulgg.airpods-control/allow-off-v1.json"
    let defaultURL = try? PersistentListeningModeAllowOffCache.defaultFileURL()
    check(
      defaultURL?.path.hasSuffix(expectedSuffix) == true,
      "allow-off cache uses the versioned user Caches path"
    )
    check(
      PersistentListeningModeAllowOffCache.systemDefault() != nil,
      "allow-off cache has a side-effect-free system-default factory"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { allowOffCacheTestSalt }
    )
    let rawUID = "AppleHDAEngineOutput:AirPods:CaseSensitive-UID"

    check(cache.lookup(rawDeviceUID: rawUID) == .miss, "missing cache is a miss")
    check(
      !FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path),
      "cache lookup does not create its directory"
    )
    check(
      cache.storePositiveObservation(rawDeviceUID: rawUID) == .applied,
      "positive Allow Off evidence is stored"
    )

    guard let original = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
      check(false, "stored Allow Off evidence is returned")
      return
    }
    check(
      original.evidence.observedAt == clock.value,
      "cache preserves the observation timestamp"
    )
    check(
      original.evidence.expiresAt
        == clock.value.addingTimeInterval(PersistentListeningModeAllowOffCache.defaultTTL),
      "cache reports the fixed seven-day expiry"
    )

    clock.value = clock.value.addingTimeInterval(123)
    guard let later = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
      check(false, "unexpired Allow Off evidence remains a hit")
      return
    }
    check(
      later.evidence.observedAt == original.evidence.observedAt
        && later.evidence.expiresAt == original.evidence.expiresAt,
      "cache reads do not refresh TTL"
    )
    clock.value = original.evidence.expiresAt
    check(
      cache.lookup(rawDeviceUID: rawUID) == .miss,
      "Allow Off evidence expires at exactly seven days"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_710_000_000))
    var excludedPaths = Set<String>()
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { allowOffCacheTestSalt },
      markExcludedFromBackup: { excludedPaths.insert($0.path) }
    )
    let rawUID = "UID-secret-material-A"
    check(
      cache.storePositiveObservation(rawDeviceUID: rawUID) == .applied,
      "cache writes a privacy-preserving document"
    )

    let directoryURL = fileURL.deletingLastPathComponent()
    let lockURL = directoryURL.appendingPathComponent("allow-off-v1.lock")
    check(
      allowOffCachePermissions(at: directoryURL) == 0o700,
      "allow-off cache directory is mode 0700"
    )
    check(
      allowOffCachePermissions(at: fileURL) == 0o600,
      "allow-off cache file is mode 0600"
    )
    check(
      allowOffCachePermissions(at: lockURL) == 0o600,
      "allow-off cache lock file is mode 0600"
    )
    check(
      excludedPaths.contains(directoryURL.path),
      "allow-off cache marks its directory as excluded from backup"
    )
    check(
      excludedPaths.contains(fileURL.path),
      "allow-off cache marks its file as excluded from backup"
    )
    check(
      excludedPaths.contains(lockURL.path),
      "allow-off cache marks its lock file as excluded from backup"
    )

    guard let data = try? Data(contentsOf: fileURL),
      let text = String(data: data, encoding: .utf8),
      let object = allowOffCacheJSON(at: fileURL),
      let schemaVersion = object["schemaVersion"] as? NSNumber,
      let salt = object["salt"] as? String,
      let entries = object["positiveEvidence"] as? [String: Any]
    else {
      check(false, "allow-off cache document is readable JSON")
      return
    }
    check(schemaVersion.intValue == 1, "allow-off cache persists schema version 1")
    check(Data(base64Encoded: salt)?.count == 32, "allow-off cache persists a 32-byte salt")
    check(!text.contains(rawUID), "allow-off cache never persists the raw device UID")
    check(entries.count == 1, "allow-off cache stores one positive evidence entry")
    if let key = entries.keys.first {
      check(
        key.utf8.count == 64
          && key.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
          },
        "allow-off cache keys are full lowercase SHA-256 digests"
      )
    }
    let directoryNames =
      (try? FileManager.default.contentsOfDirectory(
        atPath: directoryURL.path
      )) ?? []
    check(
      !directoryNames.contains(where: { $0.hasSuffix(".tmp") }),
      "atomic cache replacement leaves no temporary file"
    )

    let reopened = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { throw AllowOffCacheTestError.unavailable }
    )
    check(
      allowOffRecord(from: reopened.lookup(rawDeviceUID: rawUID)) != nil,
      "persisted salt allows lookup after reopening without regenerating salt"
    )
    check(
      reopened.lookup(rawDeviceUID: rawUID.lowercased()) == .miss,
      "raw device UID hashing is exact and case-sensitive"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_720_000_000))
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { allowOffCacheTestSalt }
    )
    let rawUID = "conditional-eviction-uid"

    _ = cache.storePositiveObservation(rawDeviceUID: rawUID)
    guard let oldRecord = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
      check(false, "conditional eviction obtains its original record")
      return
    }
    clock.value = clock.value.addingTimeInterval(5)
    _ = cache.storePositiveObservation(rawDeviceUID: rawUID)
    guard let refreshedRecord = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
      check(false, "conditional eviction obtains its refreshed record")
      return
    }
    check(
      cache.remove(record: oldRecord) == .unchanged,
      "stale record cannot erase refreshed Allow Off evidence"
    )
    check(
      allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) == refreshedRecord,
      "refreshed Allow Off evidence survives stale eviction"
    )
    check(
      cache.remove(record: refreshedRecord) == .applied,
      "current opaque record evicts its exact evidence"
    )
    check(cache.lookup(rawDeviceUID: rawUID) == .miss, "record eviction removes evidence")

    _ = cache.storePositiveObservation(rawDeviceUID: "first")
    _ = cache.storePositiveObservation(rawDeviceUID: "second")
    check(
      cache.removeEvidence(rawDeviceUID: "first") == .applied,
      "raw UID removal deletes its positive evidence"
    )
    check(cache.lookup(rawDeviceUID: "first") == .miss, "raw UID removal misses afterward")
    check(
      allowOffRecord(from: cache.lookup(rawDeviceUID: "second")) != nil,
      "raw UID removal preserves unrelated evidence"
    )
    check(
      cache.removeEvidence(rawDeviceUID: "missing") == .unchanged,
      "removing absent Allow Off evidence is unchanged"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_730_000_000))
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { allowOffCacheTestSalt }
    )
    let rawUID = "corruption-test-uid"
    _ = cache.storePositiveObservation(rawDeviceUID: rawUID)
    do {
      try Data("{not-json".utf8).write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
      )
    } catch {
      check(false, "corruption test prepares a malformed cache")
      return
    }
    check(cache.lookup(rawDeviceUID: rawUID) == .miss, "malformed cache is a safe miss")
    check(
      cache.storePositiveObservation(rawDeviceUID: rawUID) == .applied,
      "positive observation replaces a malformed disposable cache"
    )
    check(
      allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) != nil,
      "rebuilt cache returns its positive evidence"
    )

    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o644)],
        ofItemAtPath: fileURL.path
      )
    } catch {
      check(false, "permissions test changes the cache mode")
      return
    }
    check(cache.lookup(rawDeviceUID: rawUID) == .miss, "unsafe file mode is a safe miss")
    check(
      cache.removeEvidence(rawDeviceUID: rawUID) == .applied,
      "removal purges an invalid disposable cache"
    )
    check(
      !FileManager.default.fileExists(atPath: fileURL.path),
      "invalid cache purge removes the cache document"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      saltGenerator: { allowOffCacheTestSalt }
    )
    check(
      cache.storePositiveObservation(rawDeviceUID: "") == .unavailable,
      "empty raw device UID is rejected"
    )
    check(
      cache.storePositiveObservation(rawDeviceUID: String(repeating: "x", count: 4_097))
        == .unavailable,
      "oversized raw device UID is rejected"
    )
    check(
      !FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path),
      "invalid raw device UID has no filesystem side effect"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      saltGenerator: { Data(repeating: 0, count: 31) }
    )
    check(
      cache.storePositiveObservation(rawDeviceUID: "uid") == .unavailable,
      "invalid generated salt makes cache storage unavailable"
    )
    check(
      !FileManager.default.fileExists(atPath: fileURL.path),
      "invalid generated salt never writes a cache document"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      saltGenerator: { allowOffCacheTestSalt }
    )
    _ = cache.storePositiveObservation(rawDeviceUID: "existing")

    withHeldAllowOffCacheFileLock(fileURL: fileURL) {
      let startedAt = DispatchTime.now().uptimeNanoseconds
      let result = cache.storePositiveObservation(rawDeviceUID: "contended")
      let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
      check(result == .unavailable, "contended cache mutation fails soft")
      check(
        elapsed < 1_000_000_000,
        "contended cache mutation stops waiting within a bounded time"
      )
    }
    check(
      allowOffRecord(from: cache.lookup(rawDeviceUID: "existing")) != nil,
      "lock contention preserves existing cache evidence"
    )
    check(
      cache.lookup(rawDeviceUID: "contended") == .miss,
      "failed-soft lock contention does not mutate the cache"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_735_000_000))
    let group = DispatchGroup()
    for index in 0..<12 {
      group.enter()
      DispatchQueue.global().async {
        let cache = PersistentListeningModeAllowOffCache(
          fileURL: fileURL,
          now: clock.read,
          saltGenerator: { allowOffCacheTestSalt }
        )
        _ = cache.storePositiveObservation(rawDeviceUID: "concurrent-uid-\(index)")
        group.leave()
      }
    }
    group.wait()

    let reopened = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { throw AllowOffCacheTestError.unavailable }
    )
    for index in 0..<12 {
      check(
        allowOffRecord(
          from: reopened.lookup(rawDeviceUID: "concurrent-uid-\(index)")
        ) != nil,
        "locked atomic mutations preserve concurrent entry \(index)"
      )
    }
  }

  do {
    let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_740_000_000))
    guard
      let cache = InMemoryListeningModeAllowOffCache(
        salt: allowOffCacheTestSalt,
        ttl: 60,
        now: clock.read
      )
    else {
      check(false, "in-memory Allow Off cache accepts a valid salt")
      return
    }
    check(cache.lookup(rawDeviceUID: "uid") == .miss, "in-memory cache starts empty")
    check(
      cache.storePositiveObservation(rawDeviceUID: "uid") == .applied,
      "in-memory cache stores positive evidence"
    )
    guard let record = allowOffRecord(from: cache.lookup(rawDeviceUID: "uid")) else {
      check(false, "in-memory cache returns an opaque record")
      return
    }
    clock.value = clock.value.addingTimeInterval(60)
    check(cache.lookup(rawDeviceUID: "uid") == .miss, "in-memory cache enforces TTL")
    check(
      cache.remove(record: record) == .applied,
      "in-memory cache supports exact record eviction after expiry"
    )
    check(
      InMemoryListeningModeAllowOffCache(salt: Data(repeating: 0, count: 31)) == nil,
      "in-memory cache rejects an invalid salt"
    )
  }
}
