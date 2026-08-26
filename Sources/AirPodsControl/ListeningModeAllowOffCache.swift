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

private struct AllowOffObservation: Equatable {
  let allowsOff: Bool
  let observedAt: Date
}

private func shouldReplaceAllowOffObservation(
  existing: AllowOffObservation?,
  with candidate: AllowOffObservation
) -> Bool {
  guard let existing else { return true }
  if candidate.observedAt != existing.observedAt {
    return candidate.observedAt > existing.observedAt
  }
  return !candidate.allowsOff && existing.allowsOff
}

protocol ListeningModeAllowOffCaching: AnyObject {
  func lookup(rawDeviceUID: String) -> AllowOffCacheLookup
  func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date
  ) -> AllowOffCacheMutation
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
private let allowOffCacheDenyMarkerPrefix = "allow-off-v1-deny-"
private let allowOffCacheDenyMarkerSuffix = ".jsonl"
private let allowOffCacheDenyMarkerMaximumByteCount = 4_096

private struct PersistedAllowOffCache: Codable {
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
      if shouldReplaceAllowOffObservation(existing: result[key], with: candidate) {
        result[key] = candidate
      }
    }
    return result
  }
}

private struct PersistedAllowOffEvidence: Codable, Equatable {
  let observedAt: Date
}

private struct PersistedAllowOffDenyMarker: Codable, Equatable {
  let observedAt: Date
}

private enum PersistedAllowOffCacheRead {
  case value(PersistedAllowOffCache)
  case missing
  case invalid
}

private enum AllowOffDenyMarkerRead {
  case value(Date)
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
      let observation = document.observations[key],
      observation.allowsOff,
      let evidence = usableEvidence(observedAt: observation.observedAt)
    else { return .miss }
    guard !denyMarkerBlocks(
      key: key,
      positiveObservedAt: observation.observedAt
    ) else { return .miss }
    return .hit(AllowOffCacheRecord(evidence: evidence, key: key))
  }

  func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    guard validTTL, isValidRawDeviceUID(rawDeviceUID),
      observedAt.timeIntervalSince1970.isFinite
    else { return .unavailable }
    return withExclusiveMutationLock(
      body: {
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

        guard let key = digestKey(
          salt: document.salt,
          rawDeviceUID: rawDeviceUID
        )
        else { return .unavailable }

        let candidate = AllowOffObservation(
          allowsOff: allowsOff,
          observedAt: observedAt
        )
        var observations = document.observations
        let effectiveCandidate = effectiveObservation(
          candidate,
          existing: observations[key]
        )
        if effectiveCandidate.allowsOff {
          switch readDenyMarker(for: key) {
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
        guard shouldReplaceAllowOffObservation(
          existing: observations[key],
          with: effectiveCandidate
        )
        else { return .unchanged }
        observations[key] = effectiveCandidate
        let updated = PersistedAllowOffCache(
          schemaVersion: document.schemaVersion,
          salt: document.salt,
          observations: observations
        )
        guard write(updated) else {
          guard !effectiveCandidate.allowsOff else { return .unavailable }
          return purgeCacheFile() ? .applied : .unavailable
        }
        return .applied
      },
      onLockUnavailable: {
        guard !allowsOff else { return .unavailable }
        return persistDenyMarker(
          rawDeviceUID: rawDeviceUID,
          observedAt: observedAt
        )
      }
    )
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

  private func denyMarkerURL(for key: String) -> URL {
    directoryURL.appendingPathComponent(
      "\(allowOffCacheDenyMarkerPrefix)\(key)\(allowOffCacheDenyMarkerSuffix)",
      isDirectory: false
    )
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
      observations: [:]
    )
  }

  private func effectiveObservation(
    _ candidate: AllowOffObservation,
    existing: AllowOffObservation?
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

  private func persistDenyMarker(
    rawDeviceUID: String,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    guard case .value(let document) = readPersistedCache(),
      let key = digestKey(salt: document.salt, rawDeviceUID: rawDeviceUID)
    else { return .unavailable }
    let candidate = effectiveObservation(
      AllowOffObservation(allowsOff: false, observedAt: observedAt),
      existing: document.observations[key]
    )
    switch readDenyMarker(for: key) {
    case .invalid:
      return .unchanged
    case .value(let existing) where existing >= candidate.observedAt:
      return .unchanged
    case .missing, .value:
      return appendDenyMarker(for: key, observedAt: candidate.observedAt)
        ? .applied
        : .unavailable
    }
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

  private func denyMarkerBlocks(
    key: String,
    positiveObservedAt: Date
  ) -> Bool {
    switch readDenyMarker(for: key) {
    case .missing:
      return false
    case .invalid:
      return true
    case .value(let deniedAt):
      return deniedAt >= positiveObservedAt
    }
  }

  private func readDenyMarker(for key: String) -> AllowOffDenyMarkerRead {
    switch secureRead(denyMarkerURL(for: key)) {
    case .missing:
      return .missing
    case .invalid:
      return .invalid
    case .value(let data):
      var newest: Date?
      for line in data.split(separator: 0x0A) {
        guard let marker = try? decoder.decode(
          PersistedAllowOffDenyMarker.self,
          from: Data(line)
        ),
          marker.observedAt.timeIntervalSince1970.isFinite
        else { return .invalid }
        if newest == nil || marker.observedAt > newest! {
          newest = marker.observedAt
        }
      }
      guard let newest else { return .invalid }
      return .value(newest)
    }
  }

  private func appendDenyMarker(for key: String, observedAt: Date) -> Bool {
    guard let encoded = try? encoder.encode(
      PersistedAllowOffDenyMarker(observedAt: observedAt)
    ) else { return false }
    var line = encoded
    line.append(0x0A)
    guard line.count <= allowOffCacheDenyMarkerMaximumByteCount else {
      return false
    }

    let url = denyMarkerURL(for: key)
    let descriptor = openFile(
      url,
      flags: O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
      permissions: allowOffCacheFilePermissions
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    var value = stat()
    guard fstat(descriptor, &value) == 0,
      isRegularFile(value),
      value.st_uid == geteuid(),
      value.st_nlink == 1,
      value.st_size >= 0,
      UInt64(value.st_size) + UInt64(line.count)
        <= UInt64(allowOffCacheDenyMarkerMaximumByteCount),
      fchmod(descriptor, allowOffCacheFilePermissions) == 0,
      writeAll(line, to: descriptor),
      fsync(descriptor) == 0
    else { return false }
    do {
      try markExcludedFromBackup(url)
      return true
    } catch {
      return false
    }
  }

  private func validate(_ document: PersistedAllowOffCache) -> Bool {
    guard document.schemaVersion == allowOffCacheSchemaVersion,
      document.salt.count == allowOffCacheSaltByteCount,
      Set(document.positiveEvidence.keys)
        .union(document.negativeEvidence.keys)
        .count <= allowOffCacheMaximumEntryCount
    else {
      return false
    }
    return document.positiveEvidence.allSatisfy { key, entry in
      isDigestKey(key) && entry.observedAt.timeIntervalSince1970.isFinite
    } && document.negativeEvidence.allSatisfy { key, entry in
      isDigestKey(key) && entry.observedAt.timeIntervalSince1970.isFinite
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
    body: () -> AllowOffCacheMutation,
    onLockUnavailable: () -> AllowOffCacheMutation = { .unavailable }
  ) -> AllowOffCacheMutation {
    allowOffCacheProcessMutationLock.lock()
    defer { allowOffCacheProcessMutationLock.unlock() }
    guard ensureCacheDirectory(), let descriptor = openLockFile() else {
      return .unavailable
    }
    defer { Darwin.close(descriptor) }
    guard acquireFileLock(descriptor) else { return onLockUnavailable() }
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
