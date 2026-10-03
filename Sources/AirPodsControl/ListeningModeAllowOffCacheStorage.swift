import Darwin
import Dispatch
import Foundation
import Security

private let allowOffCacheDirectoryPermissions: mode_t = 0o700
private let allowOffCacheFilePermissions: mode_t = 0o600
private let allowOffCacheProcessMutationLock = NSLock()
private let allowOffCacheLockTimeoutNanoseconds: UInt64 = 250_000_000
private let allowOffCacheLockRetryMicroseconds: useconds_t = 10_000
let allowOffCacheDirectoryName = "io.github.raulgg.pods-control"
let allowOffCacheLegacyDirectoryName = "io.github.raulgg.airpods-control"
let allowOffCacheFileName = "allow-off-v1.json"
let allowOffCacheLegacyMigrationMarkerName =
  "allow-off-v1.migrated-to-pods-control"
private let allowOffCacheLegacyMigrationMarkerBytes = Data("1\n".utf8)
private let allowOffCacheDenyMarkerPrefix = "allow-off-v1-deny-"
private let allowOffCacheDenyMarkerSuffix = ".jsonl"
private let allowOffCacheDenyMarkerMaximumByteCount = 4_096
private let allowOffCacheReadBufferByteCount = 4_096

private enum AllowOffCacheStorageError: Error {
  case systemFailure
}

final class AllowOffCacheFileStorage {
  private let fileURL: URL
  private let saltGenerator: () throws -> Data
  private let markExcludedFromBackup: (URL) throws -> Void
  private let fileManager: FileManager
  private let lockRetryObserver: () -> Void

  init(
    fileURL: URL,
    saltGenerator: @escaping () throws -> Data,
    markExcludedFromBackup: @escaping (URL) throws -> Void,
    fileManager: FileManager,
    lockRetryObserver: @escaping () -> Void
  ) {
    self.fileURL = fileURL
    self.saltGenerator = saltGenerator
    self.markExcludedFromBackup = markExcludedFromBackup
    self.fileManager = fileManager
    self.lockRetryObserver = lockRetryObserver
  }

  func makeEmptyCache() -> PersistedAllowOffCache? {
    guard let salt = try? saltGenerator(),
          salt.count == AllowOffCachePolicy.saltByteCount
    else { return nil }
    return PersistedAllowOffCache(
      schemaVersion: AllowOffCachePolicy.schemaVersion,
      salt: salt,
      observations: [:]
    )
  }

  func readPersistedCache() -> PersistedAllowOffCacheRead {
    importLegacyAllowOffCacheIfNeeded()
    switch secureRead(fileURL) {
    case .missing:
      return .missing
    case .invalid:
      return .invalid
    case .value(let data):
      guard let document = try? AllowOffCacheCodec.makeDecoder().decode(
        PersistedAllowOffCache.self,
        from: data
      ),
        document.isValid
      else { return .invalid }
      return .value(document)
    }
  }

  func readDenyMarker(for key: String) -> AllowOffDenyMarkerRead {
    switch secureRead(denyMarkerURL(for: key)) {
    case .missing:
      return .missing
    case .invalid:
      return .invalid
    case .value(let data):
      var newest: Date?
      for line in data.split(separator: 0x0A) {
        guard let marker = try? AllowOffCacheCodec.makeDecoder().decode(
          PersistedAllowOffDenyMarker.self,
          from: Data(line)
        ),
          AllowOffCachePolicy.isFiniteObservationTime(marker.observedAt)
        else { return .invalid }
        if newest == nil || marker.observedAt > newest! {
          newest = marker.observedAt
        }
      }
      guard let newest else { return .invalid }
      return .value(newest)
    }
  }

  func appendDenyMarker(for key: String, observedAt: Date) -> Bool {
    guard let encoded = try? AllowOffCacheCodec.makeEncoder().encode(
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
          isTrustedOwnedUnsharedRegularFile(value),
          value.st_size >= 0,
          UInt64(value.st_size) + UInt64(line.count)
          <= UInt64(allowOffCacheDenyMarkerMaximumByteCount),
          writeAll(line, to: descriptor),
          restrictAndSync(descriptor)
    else { return false }
    do {
      try markExcludedFromBackup(url)
      return true
    } catch {
      return false
    }
  }

  func write(_ document: PersistedAllowOffCache) -> Bool {
    guard let data = encodedDocument(document),
          let temporary = openExclusiveTemporaryFile()
    else { return false }

    var shouldRemoveTemporary = true
    defer {
      Darwin.close(temporary.descriptor)
      if shouldRemoveTemporary { _ = unlinkURL(temporary.url) }
    }

    guard writeAll(data, to: temporary.descriptor),
          restrictAndSync(temporary.descriptor)
    else { return false }
    return commitTemporaryFile(
      temporary.url,
      shouldRemoveTemporary: &shouldRemoveTemporary
    )
  }

  private func encodedDocument(_ document: PersistedAllowOffCache) -> Data? {
    guard document.isValid,
          let data = try? AllowOffCacheCodec.makeEncoder().encode(document),
          data.count <= AllowOffCachePolicy.maximumByteCount
    else { return nil }
    return data
  }

  private func openExclusiveTemporaryFile() -> (url: URL, descriptor: Int32)? {
    let temporaryURL = directoryURL.appendingPathComponent(
      ".allow-off-v1.\(UUID().uuidString).tmp",
      isDirectory: false
    )
    let descriptor = openFile(
      temporaryURL,
      flags: O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
      permissions: allowOffCacheFilePermissions
    )
    guard descriptor >= 0 else { return nil }
    return (temporaryURL, descriptor)
  }

  private func commitTemporaryFile(
    _ temporaryURL: URL,
    shouldRemoveTemporary: inout Bool
  ) -> Bool {
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

  func purgeCacheFile() -> Bool {
    if unlinkURL(fileURL) { return true }
    return errno == ENOENT
  }

  func withExclusiveMutationLock(
    body: () -> AllowOffCacheMutation,
    onLockUnavailable: () -> AllowOffCacheMutation = { .unavailable }
  ) -> AllowOffCacheMutation {
    allowOffCacheProcessMutationLock.lock()
    defer { allowOffCacheProcessMutationLock.unlock() }
    // Import before creating the new directory. Creating it first would make
    // the legacy file look already migrated and drop its evidence.
    importLegacyAllowOffCacheIfNeeded()
    guard ensureCacheDirectory(), let descriptor = openLockFile() else {
      return .unavailable
    }
    defer { Darwin.close(descriptor) }
    guard acquireFileLock(descriptor) else { return onLockUnavailable() }
    defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
    return body()
  }

  private var directoryURL: URL {
    fileURL.deletingLastPathComponent()
  }

  private var legacyDirectoryURL: URL {
    directoryURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        allowOffCacheLegacyDirectoryName,
        isDirectory: true
      )
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

  private func acquireFileLock(_ descriptor: Int32) -> Bool {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while true {
      if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 { return true }
      guard errno == EACCES || errno == EAGAIN || errno == EINTR else {
        return false
      }

      lockRetryObserver()
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
            isTrustedOwnedDirectory(status),
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
          isTrustedOwnedUnsharedRegularFile(value),
          restrictAndSync(descriptor)
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
    if let failure = trustedDirectory() {
      return failure
    }
    return trustedFileContents(url)
  }

  private func trustedDirectory() -> SecureDataRead? {
    guard let directoryStatus = status(of: directoryURL) else {
      return errno == ENOENT ? .missing : .invalid
    }
    guard isTrustedOwnedDirectory(directoryStatus),
          permissionBits(directoryStatus) == allowOffCacheDirectoryPermissions
    else { return .invalid }
    return nil
  }

  private func trustedFileContents(_ url: URL) -> SecureDataRead {
    let descriptor = openFile(url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      return errno == ENOENT ? .missing : .invalid
    }
    defer { Darwin.close(descriptor) }

    var value = stat()
    guard fstat(descriptor, &value) == 0,
          isTrustedOwnedUnsharedRegularFile(value),
          value.st_size >= 0,
          UInt64(value.st_size) <= UInt64(AllowOffCachePolicy.maximumByteCount),
          permissionBits(value) == allowOffCacheFilePermissions
    else { return .invalid }
    return boundedContents(from: descriptor, size: value.st_size)
  }

  private func boundedContents(
    from descriptor: Int32,
    size: off_t
  ) -> SecureDataRead {
    var data = Data()
    data.reserveCapacity(Int(size))
    var buffer = [UInt8](repeating: 0, count: allowOffCacheReadBufferByteCount)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        return .invalid
      }
      guard data.count + count <= AllowOffCachePolicy.maximumByteCount else {
        return .invalid
      }
      data.append(buffer, count: count)
    }
    return .value(data)
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

  // Copies a trusted legacy cache once. A file the reader would reject
  // stays where it is, and a path this call did not create is never chmod'd.
  // After the new directory or the legacy migration marker exists, a missing
  // file stays missing so a purge or deletion cannot restore stale evidence.
  private func importLegacyAllowOffCacheIfNeeded() {
    guard directoryURL.lastPathComponent == allowOffCacheDirectoryName,
          fileURL.lastPathComponent == allowOffCacheFileName
    else { return }
    let legacyDirectory = openTrustedDirectory(legacyDirectoryURL)
    defer {
      if let legacyDirectory {
        Darwin.close(legacyDirectory)
      }
    }
    if let legacyDirectory,
       legacyMigrationMarkerIsPresent(dirfd: legacyDirectory) {
      return
    }
    if !pathIsAbsent(directoryURL) {
      if let legacyDirectory,
         let currentDirectory = openTrustedDirectory(directoryURL) {
        Darwin.close(currentDirectory)
        recordLegacyMigrationMarker(dirfd: legacyDirectory)
      }
      return
    }
    guard let legacyDirectory,
          let legacy = readTrustedLegacyCache(dirfd: legacyDirectory)
    else { return }
    guard let opened = openNewCacheDirectory() else { return }
    let destination = opened.descriptor
    let creation = opened.creation
    var committed = false
    defer {
      Darwin.close(destination)
      if !committed {
        removeEmptyDirectoryIfCreated(creation)
      }
    }

    var created: [CreatedAllowOffCacheFile] = []
    switch installExclusiveSibling(
      dirfd: destination,
      parentURL: directoryURL,
      name: allowOffCacheFileName,
      bytes: legacy.document,
      maximumByteCount: AllowOffCachePolicy.maximumByteCount
    ) {
    case .failed:
      return
    case .adopted:
      break
    case .created(let identity):
      created.append(
        CreatedAllowOffCacheFile(name: allowOffCacheFileName, identity: identity)
      )
    }
    for marker in legacy.markers {
      switch installExclusiveSibling(
        dirfd: destination,
        parentURL: directoryURL,
        name: marker.name,
        bytes: marker.bytes,
        maximumByteCount: allowOffCacheDenyMarkerMaximumByteCount
      ) {
      case .failed:
        removeCreatedFiles(dirfd: destination, created)
        return
      case .adopted:
        break
      case .created(let identity):
        created.append(
          CreatedAllowOffCacheFile(name: marker.name, identity: identity)
        )
      }
    }
    guard excludeVerifiedDirectoryFromBackup(dirfd: destination) else {
      removeCreatedFiles(dirfd: destination, created)
      return
    }
    recordLegacyMigrationMarker(dirfd: legacyDirectory)
    committed = true
  }

  private func legacyMigrationMarkerIsPresent(dirfd: Int32) -> Bool {
    switch readSibling(
      dirfd: dirfd,
      name: allowOffCacheLegacyMigrationMarkerName,
      maximumByteCount: allowOffCacheLegacyMigrationMarkerBytes.count
    ) {
    case .absent:
      return false
    case .rejected, .value:
      return true
    }
  }

  private func recordLegacyMigrationMarker(dirfd: Int32) {
    _ = installExclusiveSibling(
      dirfd: dirfd,
      parentURL: legacyDirectoryURL,
      name: allowOffCacheLegacyMigrationMarkerName,
      bytes: allowOffCacheLegacyMigrationMarkerBytes,
      maximumByteCount: allowOffCacheLegacyMigrationMarkerBytes.count
    )
  }

  private struct AllowOffCacheFileIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
  }

  private struct LegacyDenyMarker {
    var name: String
    var bytes: Data
  }

  private struct LegacyAllowOffCacheSnapshot {
    var document: Data
    var markers: [LegacyDenyMarker]
  }

  private struct CreatedAllowOffCacheFile {
    var name: String
    var identity: AllowOffCacheFileIdentity
  }

  private enum SiblingBytes {
    case absent
    case rejected
    case value(Data, AllowOffCacheFileIdentity)
  }

  private enum ExclusiveInstall {
    case created(AllowOffCacheFileIdentity)
    case adopted(AllowOffCacheFileIdentity)
    case failed
  }

  private enum DirectoryCreation {
    case created
    case exists
    case failed
  }

  private func readTrustedLegacyCache(
    dirfd: Int32
  ) -> LegacyAllowOffCacheSnapshot? {
    guard case .value(let document, _) = readSibling(
      dirfd: dirfd,
      name: allowOffCacheFileName,
      maximumByteCount: AllowOffCachePolicy.maximumByteCount
    ) else { return nil }
    guard let names = directoryEntryNames(dirfd: dirfd) else { return nil }
    var markers: [LegacyDenyMarker] = []
    for name in names where isLegacyDenyMarkerName(name) {
      guard case .value(let bytes, _) = readSibling(
        dirfd: dirfd,
        name: name,
        maximumByteCount: allowOffCacheDenyMarkerMaximumByteCount
      ) else { return nil }
      markers.append(LegacyDenyMarker(name: name, bytes: bytes))
    }
    return LegacyAllowOffCacheSnapshot(document: document, markers: markers)
  }

  private func isLegacyDenyMarkerName(_ name: String) -> Bool {
    guard name.hasPrefix(allowOffCacheDenyMarkerPrefix),
          name.hasSuffix(allowOffCacheDenyMarkerSuffix)
    else { return false }
    return name.count
      > allowOffCacheDenyMarkerPrefix.count + allowOffCacheDenyMarkerSuffix.count
  }

  private func openNewCacheDirectory() -> (
    descriptor: Int32,
    creation: DirectoryCreation
  )? {
    let creation = makeCacheDirectory()
    guard creation != .failed else { return nil }
    let descriptor = openFile(
      directoryURL,
      flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      removeEmptyDirectoryIfCreated(creation)
      return nil
    }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedDirectory(value)
    else {
      Darwin.close(descriptor)
      removeEmptyDirectoryIfCreated(creation)
      return nil
    }
    if creation == .created {
      guard Darwin.fchmod(descriptor, allowOffCacheDirectoryPermissions) == 0 else {
        Darwin.close(descriptor)
        removeEmptyDirectoryIfCreated(creation)
        return nil
      }
    } else if permissionBits(value) != allowOffCacheDirectoryPermissions {
      Darwin.close(descriptor)
      return nil
    }
    return (descriptor, creation)
  }

  private func makeCacheDirectory() -> DirectoryCreation {
    var error = Int32(0)
    let created = directoryURL.withUnsafeFileSystemRepresentation { path -> Bool in
      guard let path else {
        error = EINVAL
        return false
      }
      if Darwin.mkdir(path, allowOffCacheDirectoryPermissions) == 0 {
        return true
      }
      error = errno
      return false
    }
    if created { return .created }
    return error == EEXIST ? .exists : .failed
  }

  private func installExclusiveSibling(
    dirfd: Int32,
    parentURL: URL,
    name: String,
    bytes: Data,
    maximumByteCount: Int
  ) -> ExclusiveInstall {
    switch readSibling(
      dirfd: dirfd,
      name: name,
      maximumByteCount: maximumByteCount
    ) {
    case .rejected:
      return .failed
    case .value(let existing, let identity):
      return existing == bytes ? .adopted(identity) : .failed
    case .absent:
      break
    }

    let temporaryName = ".allow-off-v1.\(UUID().uuidString).tmp"
    let descriptor = temporaryName.withCString { temporary in
      Darwin.openat(
        dirfd,
        temporary,
        O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
        allowOffCacheFilePermissions
      )
    }
    guard descriptor >= 0 else { return .failed }
    guard writeAll(bytes, to: descriptor), restrictAndSync(descriptor) else {
      Darwin.close(descriptor)
      unlinkSibling(dirfd: dirfd, name: temporaryName)
      return .failed
    }
    var written = stat()
    guard Darwin.fstat(descriptor, &written) == 0 else {
      Darwin.close(descriptor)
      unlinkSibling(dirfd: dirfd, name: temporaryName)
      return .failed
    }
    let identity = AllowOffCacheFileIdentity(
      device: written.st_dev,
      inode: written.st_ino
    )
    Darwin.close(descriptor)

    var renameError = Int32(0)
    let renamed = temporaryName.withCString { temporary in
      name.withCString { final -> Bool in
        if Darwin.renameatx_np(
          dirfd,
          temporary,
          dirfd,
          final,
          UInt32(RENAME_EXCL)
        ) == 0 { return true }
        renameError = errno
        return false
      }
    }
    if !renamed {
      unlinkSibling(dirfd: dirfd, name: temporaryName)
      guard renameError == EEXIST,
            case .value(let existing, let existingIdentity) = readSibling(
              dirfd: dirfd,
              name: name,
              maximumByteCount: maximumByteCount
            ),
            existing == bytes
      else { return .failed }
      return .adopted(existingIdentity)
    }

    guard case .value(let installed, let installedIdentity) = readSibling(
      dirfd: dirfd,
      name: name,
      maximumByteCount: maximumByteCount
    ),
      installed == bytes,
      installedIdentity == identity,
      excludeBackupIfUnchanged(
        parentURL.appendingPathComponent(name, isDirectory: false),
        dirfd: dirfd,
        name: name,
        identity: identity
      )
    else {
      removeIfIdentityMatches(dirfd: dirfd, name: name, identity: identity)
      return .failed
    }
    return .created(identity)
  }

  private func readSibling(
    dirfd: Int32,
    name: String,
    maximumByteCount: Int
  ) -> SiblingBytes {
    var openError = Int32(0)
    let descriptor = name.withCString { cName -> Int32 in
      let opened = Darwin.openat(
        dirfd,
        cName,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
      )
      if opened < 0 { openError = errno }
      return opened
    }
    if descriptor < 0 {
      return openError == ENOENT ? .absent : .rejected
    }
    defer { Darwin.close(descriptor) }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedUnsharedRegularFile(value),
          value.st_size >= 0,
          value.st_size <= off_t(maximumByteCount),
          permissionBits(value) == allowOffCacheFilePermissions,
          let bytes = readExact(descriptor: descriptor, size: Int(value.st_size))
    else { return .rejected }
    return .value(
      bytes,
      AllowOffCacheFileIdentity(device: value.st_dev, inode: value.st_ino)
    )
  }

  private func excludeBackupIfUnchanged(
    _ url: URL,
    dirfd: Int32,
    name: String,
    identity: AllowOffCacheFileIdentity
  ) -> Bool {
    guard siblingIdentity(dirfd: dirfd, name: name) == identity else {
      return false
    }
    do {
      try markExcludedFromBackup(url)
      return true
    } catch {
      return false
    }
  }

  private func excludeVerifiedDirectoryFromBackup(dirfd: Int32) -> Bool {
    var descriptorStatus = stat()
    guard Darwin.fstat(dirfd, &descriptorStatus) == 0,
          let pathStatus = status(of: directoryURL),
          pathStatus.st_dev == descriptorStatus.st_dev,
          pathStatus.st_ino == descriptorStatus.st_ino,
          isTrustedOwnedDirectory(pathStatus),
          permissionBits(pathStatus) == allowOffCacheDirectoryPermissions
    else { return false }
    do {
      try markExcludedFromBackup(directoryURL)
      return true
    } catch {
      return false
    }
  }

  private func siblingIdentity(
    dirfd: Int32,
    name: String
  ) -> AllowOffCacheFileIdentity? {
    let descriptor = name.withCString { cName in
      Darwin.openat(dirfd, cName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedUnsharedRegularFile(value)
    else { return nil }
    return AllowOffCacheFileIdentity(device: value.st_dev, inode: value.st_ino)
  }

  private func removeCreatedFiles(
    dirfd: Int32,
    _ files: [CreatedAllowOffCacheFile]
  ) {
    for file in files {
      removeIfIdentityMatches(
        dirfd: dirfd,
        name: file.name,
        identity: file.identity
      )
    }
  }

  private func removeIfIdentityMatches(
    dirfd: Int32,
    name: String,
    identity: AllowOffCacheFileIdentity
  ) {
    guard siblingIdentity(dirfd: dirfd, name: name) == identity else { return }
    unlinkSibling(dirfd: dirfd, name: name)
  }

  private func unlinkSibling(dirfd: Int32, name: String) {
    _ = name.withCString { cName in
      Darwin.unlinkat(dirfd, cName, 0)
    }
  }

  private func openTrustedDirectory(_ url: URL) -> Int32? {
    let descriptor = openFile(
      url,
      flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return nil }
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0,
          isTrustedOwnedDirectory(value),
          permissionBits(value) == allowOffCacheDirectoryPermissions
    else {
      Darwin.close(descriptor)
      return nil
    }
    return descriptor
  }

  private func removeEmptyDirectoryIfCreated(_ creation: DirectoryCreation) {
    guard creation == .created else { return }
    directoryURL.withUnsafeFileSystemRepresentation { path in
      guard let path else { return }
      _ = Darwin.rmdir(path)
    }
  }

  private func pathIsAbsent(_ url: URL) -> Bool {
    var absent = false
    url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return }
      var value = stat()
      absent = Darwin.lstat(path, &value) != 0 && errno == ENOENT
    }
    return absent
  }
}

func secureAllowOffCacheSalt() throws -> Data {
  var bytes = [UInt8](repeating: 0, count: AllowOffCachePolicy.saltByteCount)
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

private func directoryEntryNames(dirfd: Int32) -> [String]? {
  let duplicate = Darwin.dup(dirfd)
  guard duplicate >= 0 else { return nil }
  guard let directory = Darwin.fdopendir(duplicate) else {
    Darwin.close(duplicate)
    return nil
  }
  defer { Darwin.closedir(directory) }
  var names: [String] = []
  while true {
    errno = 0
    guard let entry = Darwin.readdir(directory) else {
      return errno == 0 ? names : nil
    }
    let name = directoryEntryName(entry)
    if name != "." && name != ".." {
      names.append(name)
    }
  }
}

private func directoryEntryName(
  _ entry: UnsafeMutablePointer<dirent>
) -> String {
  let length = Int(entry.pointee.d_namlen)
  return withUnsafeBytes(of: entry.pointee.d_name) { bytes in
    let end = min(max(length, 0), bytes.count)
    return String(decoding: bytes.prefix(end), as: UTF8.self)
  }
}

private func readExact(descriptor: Int32, size: Int) -> Data? {
  guard size >= 0 else { return nil }
  var data = Data()
  data.reserveCapacity(size)
  var remaining = size
  var buffer = [UInt8](
    repeating: 0,
    count: min(max(size, 1), allowOffCacheReadBufferByteCount)
  )
  while remaining > 0 {
    let count = buffer.withUnsafeMutableBytes { bytes in
      Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
    }
    if count < 0 {
      if errno == EINTR { continue }
      return nil
    }
    if count == 0 { return nil }
    data.append(buffer, count: count)
    remaining -= count
  }
  return data
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

private func isTrustedOwnedDirectory(_ value: stat) -> Bool {
  isDirectory(value) && value.st_uid == geteuid()
}

private func isTrustedOwnedUnsharedRegularFile(_ value: stat) -> Bool {
  isRegularFile(value) && value.st_uid == geteuid() && value.st_nlink == 1
}

private func restrictAndSync(_ descriptor: Int32) -> Bool {
  fchmod(descriptor, allowOffCacheFilePermissions) == 0
    && fsync(descriptor) == 0
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
