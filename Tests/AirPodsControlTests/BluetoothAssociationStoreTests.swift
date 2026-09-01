import Foundation

private func withTemporaryBluetoothStore(
  _ body: (PersistentBluetoothAssociationStore, URL) throws -> Void
) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "airpods-control-bluetooth-tests-\(UUID().uuidString)",
    isDirectory: true
  )
  let file = directory.appendingPathComponent("bluetooth.json")
  defer { try? FileManager.default.removeItem(at: directory) }
  do {
    try body(PersistentBluetoothAssociationStore(fileURL: file), file)
  } catch {
    check(false, "temporary Bluetooth store operation succeeds: \(error)")
  }
}

func testBluetoothAssociationStoreRoundTripAndPermissions() {
  withTemporaryBluetoothStore { store, file in
    var document = BluetoothSettingsDocument.empty(enabled: true)
    document.associations = [
      BluetoothAssociation(
        associationID: UUID(),
        peripheralIdentifier: UUID(),
        coreAudioUIDDigests: [document.digestCoreAudioUID("core-audio-uid")],
        productID: 0x2024,
        displayName: "Test AirPods",
        provenance: .automatic
      ),
    ]
    try store.save(document)
    guard case let .value(loaded) = store.load() else {
      check(false, "saved Bluetooth settings load")
      return
    }
    check(loaded == document, "Bluetooth settings round-trip")

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: file.deletingLastPathComponent().path
    )
    check(
      (fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
      "Bluetooth settings file is owner-only"
    )
    check(
      (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
      "Bluetooth settings directory is owner-only"
    )
  }
}

func testBluetoothAssociationStoreFailsClosed() {
  withTemporaryBluetoothStore { store, file in
    check({
      if case .missing = store.load() { return true }
      return false
    }(), "missing Bluetooth settings stay distinct")

    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{not-json".utf8).write(to: file)
    check({
      if case .invalid = store.load() { return true }
      return false
    }(), "malformed Bluetooth settings fail closed")

    let malformed = BluetoothSettingsDocument(
      version: 99,
      enabled: true,
      digestSalt: Data(repeating: 1, count: 32),
      associations: [],
      candidates: []
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(malformed).write(to: file)
    check({
      if case .invalid = store.load() { return true }
      return false
    }(), "unsupported Bluetooth settings version fails closed")
  }
}

func testBluetoothAssociationStoreRejectsUnsafeEvidence() {
  var document = BluetoothSettingsDocument.empty(enabled: true)
  document.associations = [
    BluetoothAssociation(
      associationID: UUID(),
      peripheralIdentifier: UUID(),
      coreAudioUIDDigests: ["raw-core-audio-uid"],
      productID: 0x2024,
      displayName: "Test AirPods",
      provenance: .automatic
    ),
  ]
  check(!document.validate(), "association store rejects undigested UIDs")

  document.associations = []
  document.candidates = [
    BluetoothAssociationCandidate(
      peripheralIdentifier: UUID(),
      coreAudioUIDDigests: [],
      productID: 0x2024,
      displayName: "Test AirPods",
      observedStates: 0x10,
      expiresAt: Date().addingTimeInterval(3_600)
    ),
  ]
  check(!document.validate(), "association store rejects unknown state bits")
}

func testBluetoothSettingsDocumentIdentity() {
  var document = BluetoothSettingsDocument.empty(enabled: true)
  let firstCandidate = BluetoothAssociationCandidate(
    peripheralIdentifier: UUID(),
    coreAudioUIDDigests: [document.digestCoreAudioUID("uid-a")],
    productID: 0x2024,
    displayName: "Test AirPods",
    observedStates: 0x01,
    expiresAt: Date().addingTimeInterval(3_600)
  )
  var duplicateName = firstCandidate
  duplicateName.peripheralIdentifier = UUID()
  duplicateName.coreAudioUIDDigests = [document.digestCoreAudioUID("uid-b")]
  duplicateName.displayName = "test airpods"
  document.candidates = [firstCandidate, duplicateName]
  check(
    !document.validate(),
    "same product and matching names fail uniqueness"
  )

  duplicateName.productID = 0x200E
  document.candidates = [firstCandidate, duplicateName]
  check(
    document.validate(),
    "matching names with different products stay distinct"
  )
  switch document.unenrolling(name: "TEST AIRPODS") {
  case .ambiguous:
    check(true, "same-name candidates of different products are ambiguous")
  default:
    check(false, "same-name candidates of different products are ambiguous")
  }

  let peripheral = UUID()
  guard let target = document.correlationTarget(
    name: "Studio AirPods",
    productID: 0x2024,
    coreAudioUIDs: ["studio-uid"],
    placement: .unsupported
  ),
    let enrolled = document.recordingVerified(
      target: target,
      peripheralIdentifier: peripheral
    )
  else {
    check(false, "verified enrollment inserts a new association")
    return
  }
  check(
    enrolled.association(matching: target)?.peripheralIdentifier == peripheral,
    "digest overlap finds the verified association"
  )
  check(
    enrolled.recordingVerified(
      target: target,
      peripheralIdentifier: UUID()
    ) == nil,
    "a different identifier cannot replace an association"
  )

  var named = BluetoothSettingsDocument.empty(enabled: true)
  named.associations = [
    BluetoothAssociation(
      associationID: UUID(),
      peripheralIdentifier: peripheral,
      coreAudioUIDDigests: [named.digestCoreAudioUID("old-uid")],
      productID: 0x2024,
      displayName: "studio airpods",
      provenance: .automatic
    ),
  ]
  guard let renamed = named.correlationTarget(
    name: "Studio AirPods",
    productID: 0x2024,
    coreAudioUIDs: ["studio-uid"],
    placement: .unsupported
  ),
    let upgraded = named.recordingVerified(
      target: renamed,
      peripheralIdentifier: peripheral
    )
  else {
    check(false, "name claim upgrades to verified with the same identifier")
    return
  }
  check(
    upgraded.associations.first?.displayName == "Studio AirPods",
    "verified enrollment stores the current display name"
  )
  check(
    upgraded.associations.first?.provenance == .userVerified,
    "name-claim upgrade records user-verified provenance"
  )

  var leftover = enrolled
  leftover.candidates = [
    BluetoothAssociationCandidate(
      peripheralIdentifier: UUID(),
      coreAudioUIDDigests: [leftover.digestCoreAudioUID("candidate-uid")],
      productID: 0x2024,
      displayName: "studio airpods",
      observedStates: 0x01,
      expiresAt: Date().addingTimeInterval(3_600)
    ),
  ]
  switch leftover.unenrolling(name: "Studio AirPods") {
  case let .unenrolled(updated):
    check(
      updated.associations.isEmpty && updated.candidates.isEmpty,
      "unenroll removes one product's association and leftover candidate"
    )
  default:
    check(
      false,
      "unenroll removes one product's association and leftover candidate"
    )
  }
}

func runBluetoothAssociationStoreTests() {
  testBluetoothAssociationStoreRoundTripAndPermissions()
  testBluetoothAssociationStoreFailsClosed()
  testBluetoothAssociationStoreRejectsUnsafeEvidence()
  testBluetoothSettingsDocumentIdentity()
}
