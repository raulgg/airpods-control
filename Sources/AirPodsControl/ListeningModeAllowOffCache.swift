import CryptoKit
import Darwin
import Dispatch
import Foundation
import Security

struct CachedAllowOffEvidence: Equatable {
  let observedAt: Date
  let expiresAt: Date
}

struct AllowOffCacheRecord: Equatable {
  let evidence: CachedAllowOffEvidence
  let key: String
}

enum AllowOffCacheLookup: Equatable {
  case hit(AllowOffCacheRecord)
  case miss
}

enum AllowOffCacheMutation: Equatable {
  case applied
  case unchanged
  case unavailable
}

protocol ListeningModeAllowOffCaching: AnyObject {
  func lookup(rawDeviceUID: String) -> AllowOffCacheLookup
  func storePositiveObservation(rawDeviceUID: String) -> AllowOffCacheMutation
  func removeEvidence(rawDeviceUID: String) -> AllowOffCacheMutation
  func remove(record: AllowOffCacheRecord) -> AllowOffCacheMutation
}

private let allowOffCacheSchemaVersion = 1
private let allowOffCacheSaltByteCount = 32
private let allowOffCacheMaximumByteCount = 1_048_576
private let allowOffCacheMaximumEntryCount = 256
private let allowOffCacheMaximumRawUIDByteCount = 4_096
private let allowOffCacheDirectoryPermissions: mode_t = 0o700
private let allowOffCacheFilePermissions: mode_t = 0o600
private let allowOffCacheProcessMutationLock = NSLock()
private let allowOffCacheLockTimeoutNanoseconds: UInt64 = 250_000_000
private let allowOffCacheLockRetryMicroseconds: useconds_t = 10_000

private struct PersistedAllowOffCache: Codable {
  let schemaVersion: Int
  let salt: Data
  var positiveEvidence: [String: PersistedAllowOffEvidence]
}

private struct PersistedAllowOffEvidence: Codable, Equatable {
  let observedAt: Date
}

private enum PersistedAllowOffCacheRead {
  case value(PersistedAllowOffCache)
  case missing
  case invalid
}

private enum AllowOffCacheStorageError: Error {
  case systemFailure
}

final class PersistentListeningModeAllowOffCache: ListeningModeAllowOffCaching {
  static let defaultTTL: TimeInterval = 7 * 24 * 60 * 60

  let fileURL: URL

  private let ttl: TimeInterval
  private let now: () -> Date
  private let saltGenerator: () throws -> Data
  private let markExcludedFromBackup: (URL) throws -> Void
  private let fileManager: FileManager

  init(
    fileURL: URL,
    ttl: TimeInterval = PersistentListeningModeAllowOffCache.defaultTTL,
    now: @escaping () -> Date = Date.init,
    saltGenerator: @escaping () throws -> Data = secureAllowOffCacheSalt,
    markExcludedFromBackup: @escaping (URL) throws -> Void =
      excludeAllowOffCacheURLFromBackup,
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.ttl = ttl
    self.now = now
    self.saltGenerator = saltGenerator
    self.markExcludedFromBackup = markExcludedFromBackup
    self.fileManager = fileManager
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
    guard validTTL,
      case .value(let document) = readPersistedCache(),
      let key = digestKey(salt: document.salt, rawDeviceUID: rawDeviceUID),
      let entry = document.positiveEvidence[key],
      let evidence = usableEvidence(observedAt: entry.observedAt)
    else { return .miss }
    return .hit(AllowOffCacheRecord(evidence: evidence, key: key))
  }

  func storePositiveObservation(rawDeviceUID: String) -> AllowOffCacheMutation {
    guard validTTL, isValidRawDeviceUID(rawDeviceUID) else { return .unavailable }
    return withExclusiveMutationLock {
      let document: PersistedAllowOffCache
      switch readPersistedCache() {
      case .value(let value):
        document = value
      case .missing:
        guard let created = makeEmptyCache() else { return .unavailable }
        document = created
      case .invalid:
        guard purgeCacheFile() else { return .unavailable }
        guard let created = makeEmptyCache() else { return .unavailable }
        document = created
      }

      let observationTime = now()
      guard observationTime.timeIntervalSince1970.isFinite,
        let key = digestKey(
          salt: document.salt,
          rawDeviceUID: rawDeviceUID
        )
      else { return .unavailable }

      var updated = document
      updated.positiveEvidence[key] = PersistedAllowOffEvidence(
        observedAt: observationTime
      )
      return write(updated) ? .applied : .unavailable
    }
  }

  func removeEvidence(rawDeviceUID: String) -> AllowOffCacheMutation {
    guard isValidRawDeviceUID(rawDeviceUID) else { return .unavailable }
    return withExclusiveMutationLock {
      guard case .value(let document) = readPersistedCache() else {
        return purgeInvalidCacheIfNeeded()
      }
      guard
        let key = digestKey(
          salt: document.salt,
          rawDeviceUID: rawDeviceUID
        )
      else { return .unavailable }
      return remove(key: key, observedAt: nil, from: document)
    }
  }

  func remove(record: AllowOffCacheRecord) -> AllowOffCacheMutation {
    withExclusiveMutationLock {
      guard case .value(let document) = readPersistedCache() else {
        return purgeInvalidCacheIfNeeded()
      }
      return remove(
        key: record.key,
        observedAt: record.evidence.observedAt,
        from: document
      )
    }
  }

  private var directoryURL: URL {
    fileURL.deletingLastPathComponent()
  }

  private var lockFileURL: URL {
    directoryURL.appendingPathComponent("allow-off-v1.lock", isDirectory: false)
  }

  private var validTTL: Bool {
    ttl.isFinite && ttl > 0
  }

  private func usableEvidence(observedAt: Date) -> CachedAllowOffEvidence? {
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

  private func makeEmptyCache() -> PersistedAllowOffCache? {
    guard let salt = try? saltGenerator(), salt.count == allowOffCacheSaltByteCount else {
      return nil
    }
    return PersistedAllowOffCache(
      schemaVersion: allowOffCacheSchemaVersion,
      salt: salt,
      positiveEvidence: [:]
    )
  }

  private func readPersistedCache() -> PersistedAllowOffCacheRead {
    switch secureRead(fileURL) {
    case .missing:
      return .missing
    case .invalid:
      return .invalid
    case .value(let data):
      guard let document = try? decoder.decode(PersistedAllowOffCache.self, from: data),
        validate(document)
      else { return .invalid }
      return .value(document)
    }
  }

  private func validate(_ document: PersistedAllowOffCache) -> Bool {
    guard document.schemaVersion == allowOffCacheSchemaVersion,
      document.salt.count == allowOffCacheSaltByteCount,
      document.positiveEvidence.count <= allowOffCacheMaximumEntryCount
    else { return false }
    return document.positiveEvidence.allSatisfy { key, entry in
      isDigestKey(key) && entry.observedAt.timeIntervalSince1970.isFinite
    }
  }

  private func remove(
    key: String,
    observedAt: Date?,
    from document: PersistedAllowOffCache
  ) -> AllowOffCacheMutation {
    guard let existing = document.positiveEvidence[key] else { return .unchanged }
    if let observedAt, existing.observedAt != observedAt { return .unchanged }

    var updated = document
    updated.positiveEvidence.removeValue(forKey: key)
    if write(updated) { return .applied }

    // A failed invalidation must not leave stale positive evidence behind.
    return purgeCacheFile() ? .applied : .unavailable
  }

  private func purgeInvalidCacheIfNeeded() -> AllowOffCacheMutation {
    switch readPersistedCache() {
    case .missing:
      return .unchanged
    case .invalid:
      return purgeCacheFile() ? .applied : .unavailable
    case .value:
      return .unchanged
    }
  }

  private func withExclusiveMutationLock(
    _ body: () -> AllowOffCacheMutation
  ) -> AllowOffCacheMutation {
    allowOffCacheProcessMutationLock.lock()
    defer { allowOffCacheProcessMutationLock.unlock() }
    guard ensureCacheDirectory(), let descriptor = openLockFile() else {
      return .unavailable
    }
    defer { Darwin.close(descriptor) }
    guard acquireFileLock(descriptor) else { return .unavailable }
    defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
    return body()
  }

  private func acquireFileLock(_ descriptor: Int32) -> Bool {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while true {
      if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 { return true }
      guard errno == EACCES || errno == EAGAIN || errno == EINTR else {
        return false
      }

      let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
      guard elapsed < allowOffCacheLockTimeoutNanoseconds else { return false }
      let remainingMicroseconds =
        (allowOffCacheLockTimeoutNanoseconds - elapsed) / 1_000
      _ = Darwin.usleep(
        useconds_t(
          min(UInt64(allowOffCacheLockRetryMicroseconds), remainingMicroseconds)
        )
      )
    }
  }

  private func ensureCacheDirectory() -> Bool {
    let attributes: [FileAttributeKey: Any] = [
      .posixPermissions: NSNumber(value: allowOffCacheDirectoryPermissions)
    ]
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: attributes
      )
      guard let status = status(of: directoryURL),
        isDirectory(status),
        status.st_uid == geteuid(),
        chmodURL(directoryURL, permissions: allowOffCacheDirectoryPermissions)
      else { return false }
      try markExcludedFromBackup(directoryURL)
      return true
    } catch {
      return false
    }
  }

  private func openLockFile() -> Int32? {
    let descriptor = openFile(
      lockFileURL,
      flags: O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      permissions: allowOffCacheFilePermissions
    )
    guard descriptor >= 0 else { return nil }
    var value = stat()
    guard fstat(descriptor, &value) == 0,
      isRegularFile(value),
      value.st_uid == geteuid(),
      value.st_nlink == 1,
      fchmod(descriptor, allowOffCacheFilePermissions) == 0
    else {
      Darwin.close(descriptor)
      return nil
    }
    do {
      try markExcludedFromBackup(lockFileURL)
    } catch {
      Darwin.close(descriptor)
      _ = unlinkURL(lockFileURL)
      return nil
    }
    return descriptor
  }

  private enum SecureDataRead {
    case value(Data)
    case missing
    case invalid
  }

  private func secureRead(_ url: URL) -> SecureDataRead {
    guard let directoryStatus = status(of: directoryURL) else {
      return errno == ENOENT ? .missing : .invalid
    }
    guard isDirectory(directoryStatus),
      directoryStatus.st_uid == geteuid(),
      permissionBits(directoryStatus) == allowOffCacheDirectoryPermissions
    else { return .invalid }

    let descriptor = openFile(url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      return errno == ENOENT ? .missing : .invalid
    }
    defer { Darwin.close(descriptor) }

    var value = stat()
    guard fstat(descriptor, &value) == 0,
      isRegularFile(value),
      value.st_uid == geteuid(),
      value.st_nlink == 1,
      value.st_size >= 0,
      UInt64(value.st_size) <= UInt64(allowOffCacheMaximumByteCount),
      permissionBits(value) == allowOffCacheFilePermissions
    else { return .invalid }

    var data = Data()
    data.reserveCapacity(Int(value.st_size))
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        return .invalid
      }
      guard data.count + count <= allowOffCacheMaximumByteCount else {
        return .invalid
      }
      data.append(buffer, count: count)
    }
    return .value(data)
  }

  private func write(_ document: PersistedAllowOffCache) -> Bool {
    guard validate(document),
      let data = try? encoder.encode(document),
      data.count <= allowOffCacheMaximumByteCount
    else { return false }

    let temporaryURL = directoryURL.appendingPathComponent(
      ".allow-off-v1.\(UUID().uuidString).tmp",
      isDirectory: false
    )
    let descriptor = openFile(
      temporaryURL,
      flags: O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
      permissions: allowOffCacheFilePermissions
    )
    guard descriptor >= 0 else { return false }

    var shouldRemoveTemporary = true
    defer {
      Darwin.close(descriptor)
      if shouldRemoveTemporary { _ = unlinkURL(temporaryURL) }
    }

    guard writeAll(data, to: descriptor),
      fchmod(descriptor, allowOffCacheFilePermissions) == 0,
      fsync(descriptor) == 0
    else { return false }
    do {
      try markExcludedFromBackup(temporaryURL)
      guard renameURL(temporaryURL, to: fileURL) else { return false }
      shouldRemoveTemporary = false
      guard chmodURL(fileURL, permissions: allowOffCacheFilePermissions) else {
        _ = unlinkURL(fileURL)
        return false
      }
      try markExcludedFromBackup(fileURL)
      try markExcludedFromBackup(directoryURL)
      return true
    } catch {
      if !shouldRemoveTemporary { _ = unlinkURL(fileURL) }
      return false
    }
  }

  private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return true }
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: written),
          bytes.count - written
        )
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        guard count > 0 else { return false }
        written += count
      }
      return true
    }
  }

  private func purgeCacheFile() -> Bool {
    if unlinkURL(fileURL) { return true }
    return errno == ENOENT
  }

  private var encoder: JSONEncoder {
    let value = JSONEncoder()
    value.dateEncodingStrategy = .secondsSince1970
    value.outputFormatting = [.sortedKeys]
    return value
  }

  private var decoder: JSONDecoder {
    let value = JSONDecoder()
    value.dateDecodingStrategy = .secondsSince1970
    return value
  }

}

final class InMemoryListeningModeAllowOffCache: ListeningModeAllowOffCaching {
  private let salt: Data
  private let ttl: TimeInterval
  private let now: () -> Date
  private let lock = NSLock()
  private var entries: [String: Date] = [:]

  init?(
    salt: Data,
    ttl: TimeInterval = PersistentListeningModeAllowOffCache.defaultTTL,
    now: @escaping () -> Date = Date.init
  ) {
    guard salt.count == allowOffCacheSaltByteCount, ttl.isFinite, ttl > 0 else {
      return nil
    }
    self.salt = salt
    self.ttl = ttl
    self.now = now
  }

  func lookup(rawDeviceUID: String) -> AllowOffCacheLookup {
    guard let key = digestKey(salt: salt, rawDeviceUID: rawDeviceUID) else {
      return .miss
    }
    lock.lock()
    let observedAt = entries[key]
    lock.unlock()
    guard let observedAt,
      let evidence = usableEvidence(observedAt: observedAt)
    else { return .miss }
    return .hit(AllowOffCacheRecord(evidence: evidence, key: key))
  }

  func storePositiveObservation(rawDeviceUID: String) -> AllowOffCacheMutation {
    guard let key = digestKey(salt: salt, rawDeviceUID: rawDeviceUID) else {
      return .unavailable
    }
    let observationTime = now()
    guard observationTime.timeIntervalSince1970.isFinite else { return .unavailable }
    lock.lock()
    entries[key] = observationTime
    lock.unlock()
    return .applied
  }

  func removeEvidence(rawDeviceUID: String) -> AllowOffCacheMutation {
    guard let key = digestKey(salt: salt, rawDeviceUID: rawDeviceUID) else {
      return .unavailable
    }
    lock.lock()
    let removed = entries.removeValue(forKey: key) != nil
    lock.unlock()
    return removed ? .applied : .unchanged
  }

  func remove(record: AllowOffCacheRecord) -> AllowOffCacheMutation {
    lock.lock()
    defer { lock.unlock() }
    guard let observedAt = entries[record.key],
      observedAt == record.evidence.observedAt
    else { return .unchanged }
    entries.removeValue(forKey: record.key)
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

func secureAllowOffCacheSalt() throws -> Data {
  var bytes = [UInt8](repeating: 0, count: allowOffCacheSaltByteCount)
  let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
  guard status == errSecSuccess else { throw AllowOffCacheStorageError.systemFailure }
  return Data(bytes)
}

func excludeAllowOffCacheURLFromBackup(_ url: URL) throws {
  var mutableURL = url
  var values = URLResourceValues()
  values.isExcludedFromBackup = true
  try mutableURL.setResourceValues(values)
}

private func digestKey(salt: Data, rawDeviceUID: String) -> String? {
  guard salt.count == allowOffCacheSaltByteCount,
    isValidRawDeviceUID(rawDeviceUID)
  else { return nil }
  var hasher = SHA256()
  hasher.update(data: salt)
  hasher.update(data: Data(rawDeviceUID.utf8))
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func isValidRawDeviceUID(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= allowOffCacheMaximumRawUIDByteCount
}

private func isDigestKey(_ value: String) -> Bool {
  value.utf8.count == SHA256.byteCount * 2
    && value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
}

private func status(of url: URL) -> stat? {
  var value = stat()
  let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return Int32(-1) }
    return Darwin.lstat(path, &value)
  }
  return result == 0 ? value : nil
}

private func isDirectory(_ value: stat) -> Bool {
  value.st_mode & S_IFMT == S_IFDIR
}

private func isRegularFile(_ value: stat) -> Bool {
  value.st_mode & S_IFMT == S_IFREG
}

private func permissionBits(_ value: stat) -> mode_t {
  value.st_mode & mode_t(0o777)
}

private func openFile(
  _ url: URL,
  flags: Int32,
  permissions: mode_t = 0
) -> Int32 {
  url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return -1 }
    if flags & O_CREAT != 0 {
      return Darwin.open(path, flags, permissions)
    }
    return Darwin.open(path, flags)
  }
}

private func chmodURL(_ url: URL, permissions: mode_t) -> Bool {
  url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return false }
    return Darwin.chmod(path, permissions) == 0
  }
}

private func unlinkURL(_ url: URL) -> Bool {
  url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return false }
    return Darwin.unlink(path) == 0
  }
}

private func renameURL(_ source: URL, to destination: URL) -> Bool {
  source.withUnsafeFileSystemRepresentation { sourcePath in
    destination.withUnsafeFileSystemRepresentation { destinationPath in
      guard let sourcePath, let destinationPath else { return false }
      return Darwin.rename(sourcePath, destinationPath) == 0
    }
  }
}
