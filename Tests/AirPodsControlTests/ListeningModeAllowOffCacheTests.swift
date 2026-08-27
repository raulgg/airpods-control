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
private let allowOffCacheLockHolderArgument = "--hold-allow-off-cache-lock"

func runAllowOffCacheLockHolderCommandIfRequested() -> Int32? {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.first == allowOffCacheLockHolderArgument else { return nil }
  guard arguments.count == 3,
    let seconds = TimeInterval(arguments[2]),
    seconds.isFinite,
    seconds > 0
  else {
    fputs("allow-off lock holder: expected <lock-path> <positive-seconds>\n", stderr)
    return 2
  }

  let lockURL = URL(fileURLWithPath: arguments[1])
  let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
    guard let path else { return Int32(-1) }
    return Darwin.open(
      path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600)
    )
  }
  guard descriptor >= 0 else {
    let errorCode = errno
    fputs(
      "allow-off lock holder: open failed: \(String(cString: strerror(errorCode)))\n",
      stderr
    )
    return 1
  }
  defer { Darwin.close(descriptor) }

  guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
    let errorCode = errno
    fputs(
      "allow-off lock holder: lock failed: \(String(cString: strerror(errorCode)))\n",
      stderr
    )
    return 1
  }
  defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }

  var startSignal: UInt8 = 0
  while true {
    let count = Darwin.read(STDIN_FILENO, &startSignal, 1)
    if count == 1 { break }
    if count == -1 && errno == EINTR { continue }
    fputs("allow-off lock holder: parent did not send the start signal\n", stderr)
    return 1
  }

  Thread.sleep(forTimeInterval: seconds)
  return 0
}

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

private func allowOffCacheFileLockIsContended(fileURL: URL) -> Bool {
  let lockURL = fileURL.deletingLastPathComponent()
    .appendingPathComponent("allow-off-v1.lock")
  let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { return false }
  defer { Darwin.close(descriptor) }
  if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 {
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    return false
  }
  return errno == EACCES || errno == EAGAIN
}

private func withHeldAllowOffCacheFileLock(
  fileURL: URL,
  holdFor seconds: String = "2",
  _ body: () -> Void
) {
  let lockURL = fileURL.deletingLastPathComponent()
    .appendingPathComponent("allow-off-v1.lock")
  guard let executableURL = Bundle.main.executableURL else {
    check(false, "lock contention test resolves the swift-tests executable")
    return
  }

  let process = Process()
  let startPipe = Pipe()
  process.executableURL = executableURL
  process.arguments = [allowOffCacheLockHolderArgument, lockURL.path, seconds]
  process.standardInput = startPipe
  do {
    try process.run()
  } catch {
    check(false, "lock contention test starts a lock holder: \(error)")
    return
  }
  defer {
    try? startPipe.fileHandleForWriting.close()
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
      do {
        try startPipe.fileHandleForWriting.write(contentsOf: Data([1]))
        try startPipe.fileHandleForWriting.close()
      } catch {
        check(false, "lock contention test signals the lock holder: \(error)")
        return
      }
      body()
      return
    }
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    if !process.isRunning {
      process.waitUntilExit()
      check(
        false,
        "lock contention holder exited before acquiring the lock (status \(process.terminationStatus))"
      )
      return
    }
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
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: clock.value
      ) == .applied,
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
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: clock.value
      ) == .applied,
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

    _ = cache.applyObservation(
      rawDeviceUID: rawUID,
      allowsOff: true,
      observedAt: clock.value
    )
    guard let oldRecord = allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) else {
      check(false, "conditional eviction obtains its original record")
      return
    }
    clock.value = clock.value.addingTimeInterval(5)
    _ = cache.applyObservation(
      rawDeviceUID: rawUID,
      allowsOff: true,
      observedAt: clock.value
    )
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

    _ = cache.applyObservation(
      rawDeviceUID: "first",
      allowsOff: true,
      observedAt: clock.value
    )
    _ = cache.applyObservation(
      rawDeviceUID: "second",
      allowsOff: true,
      observedAt: clock.value
    )
    check(
      cache.applyObservation(
        rawDeviceUID: "first",
        allowsOff: false,
        observedAt: clock.value
      ) == .applied,
      "raw UID removal deletes its positive evidence"
    )
    check(cache.lookup(rawDeviceUID: "first") == .miss, "raw UID removal misses afterward")
    check(
      allowOffRecord(from: cache.lookup(rawDeviceUID: "second")) != nil,
      "raw UID removal preserves unrelated evidence"
    )
    check(
      cache.applyObservation(
        rawDeviceUID: "missing",
        allowsOff: false,
        observedAt: clock.value
      ) == .applied,
      "negative observations retain a tombstone even without positive evidence"
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
    _ = cache.applyObservation(
      rawDeviceUID: rawUID,
      allowsOff: true,
      observedAt: clock.value
    )
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
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: clock.value
      ) == .applied,
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
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: false,
        observedAt: clock.value
      ) == .applied,
      "negative observation replaces a malformed disposable cache"
    )
    check(
      cache.lookup(rawDeviceUID: rawUID) == .miss,
      "negative observation leaves no positive evidence"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let clock = AllowOffCacheTestClock(Date(timeIntervalSince1970: 1_731_000_000))
    var failTemporaryBackup = false
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { allowOffCacheTestSalt },
      markExcludedFromBackup: { url in
        if failTemporaryBackup && url.pathExtension == "tmp" {
          throw AllowOffCacheTestError.unavailable
        }
      }
    )
    let rawUID = "failed-negative-write-uid"
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: clock.value
      ) == .applied,
      "failed negative write test seeds positive evidence"
    )
    failTemporaryBackup = true
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: false,
        observedAt: clock.value
      ) == .applied,
      "failed negative persistence purges stale positive evidence"
    )
    check(
      cache.lookup(rawDeviceUID: rawUID) == .miss,
      "failed negative persistence cannot leave a reusable positive"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let observedAt = Date(timeIntervalSince1970: 1_732_000_000)
    let clock = AllowOffCacheTestClock(observedAt)
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { allowOffCacheTestSalt }
    )
    let rawUID = "contended-negative-uid"
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: observedAt
      ) == .applied,
      "lock-timeout test seeds positive evidence"
    )
    let negativeObservedAt = observedAt.addingTimeInterval(1)
    withHeldAllowOffCacheFileLock(fileURL: fileURL) {
      check(
        cache.applyObservation(
          rawDeviceUID: rawUID,
          allowsOff: false,
          observedAt: negativeObservedAt
        ) == .applied,
        "negative lock timeout writes a deny marker"
      )
    }
    clock.value = negativeObservedAt
    check(
      cache.lookup(rawDeviceUID: rawUID) == .miss,
      "a deny marker blocks stale positive evidence after lock contention"
    )
    clock.value = negativeObservedAt.addingTimeInterval(1)
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: clock.value
      ) == .applied,
      "newer positive evidence can supersede a deny marker"
    )
    check(
      allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID)) != nil,
      "newer positive evidence remains usable after a denied write"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      saltGenerator: { allowOffCacheTestSalt }
    )
    check(
      cache.applyObservation(
        rawDeviceUID: "",
        allowsOff: true,
        observedAt: Date()
      ) == .unavailable,
      "empty raw device UID is rejected"
    )
    check(
      cache.applyObservation(
        rawDeviceUID: String(repeating: "x", count: 4_097),
        allowsOff: true,
        observedAt: Date()
      ) == .unavailable,
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
      cache.applyObservation(
        rawDeviceUID: "uid",
        allowsOff: true,
        observedAt: Date()
      ) == .unavailable,
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
    _ = cache.applyObservation(
      rawDeviceUID: "existing",
      allowsOff: true,
      observedAt: Date()
    )

    withHeldAllowOffCacheFileLock(fileURL: fileURL) {
      let startedAt = DispatchTime.now().uptimeNanoseconds
      let result = cache.applyObservation(
        rawDeviceUID: "contended",
        allowsOff: true,
        observedAt: Date()
      )
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
    let observedAt = Date(timeIntervalSince1970: 1_734_000_000)
    let afterContention = observedAt.addingTimeInterval(10)
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: {
        allowOffCacheFileLockIsContended(fileURL: fileURL)
          ? observedAt
          : afterContention
      },
      saltGenerator: { allowOffCacheTestSalt }
    )
    _ = cache.applyObservation(
      rawDeviceUID: "seed",
      allowsOff: true,
      observedAt: observedAt
    )

    withHeldAllowOffCacheFileLock(fileURL: fileURL, holdFor: "0.15") {
      check(
        cache.applyObservation(
          rawDeviceUID: "delayed",
          allowsOff: true,
          observedAt: observedAt
        ) == .applied,
        "positive observation waits for brief lock contention"
      )
    }
    check(
      allowOffRecord(from: cache.lookup(rawDeviceUID: "delayed"))?.evidence.observedAt
        == observedAt,
      "positive observation keeps the time captured before lock contention"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let current = Date(timeIntervalSince1970: 1_736_000_020)
    let clock = AllowOffCacheTestClock(current)
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { allowOffCacheTestSalt }
    )
    let rawUID = "ordered-observation-uid"
    let older = current.addingTimeInterval(-20)
    let newer = current.addingTimeInterval(-10)

    clock.value = newer
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: newer
      ) == .applied,
      "newer positive observation is stored"
    )
    clock.value = current
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: older
      ) == .unchanged,
      "older positive observation cannot replace newer evidence"
    )
    clock.value = current
    check(
      allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID))?.evidence.observedAt
        == newer,
      "newer evidence survives a delayed older positive observation"
    )
    clock.value = current
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: false,
        observedAt: older
      ) == .unchanged,
      "older negative observation cannot remove newer evidence"
    )
    clock.value = current
    check(
      allowOffRecord(from: cache.lookup(rawDeviceUID: rawUID))?.evidence.observedAt
        == newer,
      "newer evidence survives a delayed older negative observation"
    )
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: false,
        observedAt: current
      ) == .applied,
      "newer negative observation removes older evidence"
    )

    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: current
      ) == .unchanged,
      "equal positive and negative observations fail closed"
    )
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: older
      ) == .unchanged,
      "an older positive observation cannot replace a newer negative tombstone"
    )
  }

  withTemporaryAllowOffCache { fileURL in
    let positiveObservedAt = Date(timeIntervalSince1970: 1_737_000_000)
    let clock = AllowOffCacheTestClock(positiveObservedAt)
    let cache = PersistentListeningModeAllowOffCache(
      fileURL: fileURL,
      now: clock.read,
      saltGenerator: { allowOffCacheTestSalt }
    )
    let rawUID = "clock-rollback-uid"
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: true,
        observedAt: positiveObservedAt
      ) == .applied,
      "clock rollback test seeds positive evidence"
    )
    let rolledBack = positiveObservedAt.addingTimeInterval(-60)
    clock.value = rolledBack
    check(
      cache.applyObservation(
        rawDeviceUID: rawUID,
        allowsOff: false,
        observedAt: rolledBack
      ) == .applied,
      "a fresh negative during clock rollback is recorded at the future positive time"
    )
    clock.value = positiveObservedAt
    check(
      cache.lookup(rawDeviceUID: rawUID) == .miss,
      "clock rollback cannot resurrect superseded positive evidence"
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
        _ = cache.applyObservation(
          rawDeviceUID: "concurrent-uid-\(index)",
          allowsOff: true,
          observedAt: clock.value
        )
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
      cache.applyObservation(
        rawDeviceUID: "uid",
        allowsOff: true,
        observedAt: clock.value
      ) == .applied,
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
