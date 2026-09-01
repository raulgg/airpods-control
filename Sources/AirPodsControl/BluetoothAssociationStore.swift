import CryptoKit
import Foundation

enum BluetoothAssociationProvenance: String, Codable {
  case automatic
  case userVerified = "user-verified"
}

struct BluetoothAssociation: Codable, Equatable {
  var associationID: UUID
  var peripheralIdentifier: UUID
  var coreAudioUIDDigests: [String]
  var productID: Int
  var displayName: String
  var provenance: BluetoothAssociationProvenance
}

struct BluetoothAssociationCandidate: Codable, Equatable {
  var peripheralIdentifier: UUID
  var coreAudioUIDDigests: [String]
  var productID: Int
  var displayName: String
  var observedStates: UInt8
  var expiresAt: Date
}

struct BluetoothCorrelationTarget: Equatable {
  let name: String
  let productID: Int
  let coreAudioUIDDigests: [String]
  let placement: DeviceStatusField<BluetoothEarPlacement>
}

enum BluetoothUnenrollResult: Equatable {
  case unenrolled(BluetoothSettingsDocument)
  case notEnrolled
  case ambiguous
}

struct BluetoothSettingsDocument: Codable, Equatable {
  static let currentVersion = 1

  var version: Int = currentVersion
  var enabled: Bool
  var digestSalt: Data
  var associations: [BluetoothAssociation]
  var candidates: [BluetoothAssociationCandidate]

  static func empty(enabled: Bool) -> BluetoothSettingsDocument {
    BluetoothSettingsDocument(
      enabled: enabled,
      digestSalt: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }),
      associations: [],
      candidates: []
    )
  }

  static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
    DeviceDisplayName.matches(lhs, rhs)
  }

  func validate() -> Bool {
    guard version == Self.currentVersion, digestSalt.count == 32 else {
      return false
    }
    guard associations.allSatisfy({ association in
      Self.validIdentity(
        displayName: association.displayName,
        productID: association.productID,
        digests: association.coreAudioUIDDigests
      )
    }) else {
      return false
    }
    guard candidates.allSatisfy({ candidate in
      Self.validIdentity(
        displayName: candidate.displayName,
        productID: candidate.productID,
        digests: candidate.coreAudioUIDDigests
      )
        && candidate.observedStates != 0
        && candidate.observedStates & ~0x0F == 0
    }) else {
      return false
    }
    let associationDigests = associations.flatMap(\.coreAudioUIDDigests)
    let allDigests = associationDigests
      + candidates.flatMap(\.coreAudioUIDDigests)
    return Self.allUnique(associations.map(\.associationID))
      && Self.allUnique(associations.map(\.peripheralIdentifier))
      && Self.allUnique(associationDigests)
      && Self.allUnique(allDigests)
      && Self.allUnique(candidates.map(\.peripheralIdentifier))
      && Self.uniqueProductNames(
        candidates.map { ($0.productID, $0.displayName) }
      )
  }

  func digestCoreAudioUID(_ uid: String) -> String {
    var input = digestSalt
    input.append(Data(uid.utf8))
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
  }

  func correlationTarget(
    name: String,
    productID: Int,
    coreAudioUIDs: [String],
    placement: DeviceStatusField<BluetoothEarPlacement>
  ) -> BluetoothCorrelationTarget? {
    guard AppleAudioProducts.supportsBLEEarPlacement(productID: productID),
          !name.isEmpty,
          !coreAudioUIDs.isEmpty
    else {
      return nil
    }
    return BluetoothCorrelationTarget(
      name: name,
      productID: productID,
      coreAudioUIDDigests: Array(
        Set(coreAudioUIDs.map(digestCoreAudioUID))
      ).sorted(),
      placement: placement
    )
  }

  func target(
    name: String?,
    correlation: BluetoothEndpointCorrelation?,
    placement: DeviceStatusField<BluetoothEarPlacement>
  ) -> BluetoothCorrelationTarget? {
    guard let name, let correlation else { return nil }
    return correlationTarget(
      name: name,
      productID: correlation.productID,
      coreAudioUIDs: correlation.coreAudioUIDs,
      placement: placement
    )
  }

  func association(
    matchingProductID productID: Int,
    digests: [String]
  ) -> BluetoothAssociation? {
    associations.first { association in
      association.productID == productID
        && !Set(association.coreAudioUIDDigests).isDisjoint(with: digests)
    }
  }

  func association(
    matching target: BluetoothCorrelationTarget
  ) -> BluetoothAssociation? {
    association(
      matchingProductID: target.productID,
      digests: target.coreAudioUIDDigests
    )
  }

  func hasClaim(productID: Int, name: String) -> Bool {
    associations.contains {
      $0.productID == productID && Self.namesMatch($0.displayName, name)
    }
  }

  func hasAssociation(for target: BluetoothCorrelationTarget) -> Bool {
    association(matching: target) != nil
      || hasClaim(productID: target.productID, name: target.name)
  }

  func recordingVerified(
    target: BluetoothCorrelationTarget,
    peripheralIdentifier: UUID
  ) -> BluetoothSettingsDocument? {
    var document = self
    let uidMatches = document.associations.indices.filter { index in
      let association = document.associations[index]
      return association.productID == target.productID
        && !Set(association.coreAudioUIDDigests)
          .isDisjoint(with: target.coreAudioUIDDigests)
    }
    if let index = uidMatches.first {
      guard uidMatches.count == 1,
            document.associations[index].peripheralIdentifier
              == peripheralIdentifier
      else {
        return nil
      }
      document.associations[index].provenance = .userVerified
      document.associations[index].displayName = target.name
      return document
    }

    let nameMatches = document.associations.indices.filter { index in
      document.associations[index].productID == target.productID
        && Self.namesMatch(
          document.associations[index].displayName,
          target.name
        )
    }
    if let index = nameMatches.first {
      guard nameMatches.count == 1,
            document.associations[index].peripheralIdentifier
              == peripheralIdentifier
      else {
        return nil
      }
      document.associations[index].coreAudioUIDDigests =
        target.coreAudioUIDDigests
      document.associations[index].provenance = .userVerified
      document.associations[index].displayName = target.name
      return document
    }

    guard !document.associations.contains(where: {
      $0.peripheralIdentifier == peripheralIdentifier
    }) else {
      return nil
    }
    document.associations.append(
      BluetoothAssociation(
        associationID: UUID(),
        peripheralIdentifier: peripheralIdentifier,
        coreAudioUIDDigests: target.coreAudioUIDDigests,
        productID: target.productID,
        displayName: target.name,
        provenance: .userVerified
      )
    )
    return document
  }

  func unenrolling(name: String) -> BluetoothUnenrollResult {
    let associationMatches = associations.filter {
      Self.namesMatch($0.displayName, name)
    }
    let candidateMatches = candidates.filter {
      Self.namesMatch($0.displayName, name)
    }
    guard !associationMatches.isEmpty || !candidateMatches.isEmpty else {
      return .notEnrolled
    }
    let productIDs = Set(
      associationMatches.map(\.productID) + candidateMatches.map(\.productID)
    )
    guard productIDs.count == 1, associationMatches.count <= 1 else {
      return .ambiguous
    }
    var document = self
    document.associations.removeAll {
      Self.namesMatch($0.displayName, name)
    }
    document.candidates.removeAll {
      Self.namesMatch($0.displayName, name)
    }
    return .unenrolled(document)
  }

  private static func validIdentity(
    displayName: String,
    productID: Int,
    digests: [String]
  ) -> Bool {
    !displayName.isEmpty
      && displayName.unicodeScalars.count <= 512
      && AppleAudioProducts.supportsBLEEarPlacement(productID: productID)
      && !digests.isEmpty
      && allUnique(digests)
      && digests.allSatisfy(validDigest)
  }

  private static func allUnique<T: Hashable>(_ items: [T]) -> Bool {
    Set(items).count == items.count
  }

  private static func uniqueProductNames(
    _ items: [(Int, String)]
  ) -> Bool {
    for i in items.indices {
      for j in items.indices where j > i {
        if items[i].0 == items[j].0, namesMatch(items[i].1, items[j].1) {
          return false
        }
      }
    }
    return true
  }

  private static func validDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      48 ... 57 ~= $0 || 97 ... 102 ~= $0
    }
  }
}

enum BluetoothSettingsLoadResult {
  case missing
  case value(BluetoothSettingsDocument)
  case invalid
}

protocol BluetoothAssociationStoring {
  func load() -> BluetoothSettingsLoadResult
  func save(_ document: BluetoothSettingsDocument) throws
}

enum BluetoothAssociationStoreError: Error {
  case invalidDocument
}

final class PersistentBluetoothAssociationStore: BluetoothAssociationStoring {
  private let fileURL: URL
  private let fileManager: FileManager

  init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  static func systemDefault() -> PersistentBluetoothAssociationStore? {
    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      return nil
    }
    return PersistentBluetoothAssociationStore(
      fileURL: applicationSupport
        .appendingPathComponent("io.github.raulgg.airpods-control", isDirectory: true)
        .appendingPathComponent("bluetooth.json")
    )
  }

  func load() -> BluetoothSettingsLoadResult {
    guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
    do {
      let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      let document = try decoder.decode(BluetoothSettingsDocument.self, from: data)
      return document.validate() ? .value(document) : .invalid
    } catch {
      return .invalid
    }
  }

  func save(_ document: BluetoothSettingsDocument) throws {
    guard document.validate() else {
      throw BluetoothAssociationStoreError.invalidDocument
    }
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
    let data = try encoder.encode(document)
    try data.write(to: fileURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
