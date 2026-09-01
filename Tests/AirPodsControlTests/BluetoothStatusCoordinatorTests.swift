import CoreAudio
import Foundation

private func coordinatorAdvertisements(
  identifier: UUID,
  status: UInt8,
  productID: Int = 0x2024
) -> [BluetoothAdvertisement] {
  var bytes: [UInt8] = [
    0x4C, 0x00, 0x07, 0x19, 0x01,
    UInt8(productID & 0xFF), UInt8((productID >> 8) & 0xFF),
    status, 0xAA, 0xB5, 0x31, 0x00, 0x00,
  ]
  bytes += [UInt8](repeating: 0, count: 16)
  let advertisement = BluetoothAdvertisement(
    peripheralIdentifier: identifier,
    manufacturerData: Data(bytes)
  )
  return [advertisement, advertisement]
}

struct CoordinatorInventory {
  let devices: [IOBluetoothStatusDevice]
  let correlation: (IOBluetoothStatusDevice) -> BluetoothEndpointCorrelation?

  func session(
    document: BluetoothSettingsDocument?,
    scanResult: BluetoothScanResult,
    bluetoothUsable: Bool? = nil
  ) -> StatusSession {
    let advertisements = scanResult.radio == .poweredOn
      ? scanResult.advertisements
      : []
    let usable = bluetoothUsable ?? (
      scanResult.authorization == .authorized && document?.enabled == true
    )
    return StatusSession(
      hal: devices.map { device in
        StatusHALRecord(
          device: device,
          target: document?.target(
            name: device.name,
            correlation: correlation(device),
            placement: device.readInEarPlacementStatus()
          )
        )
      },
      document: document,
      observations: AirPodsBLEScanNormalizer.normalize(advertisements),
      bluetoothUsable: usable
    )
  }

  func statusOutcome(
    document: BluetoothSettingsDocument?,
    scanResult: BluetoothScanResult,
    named: String? = nil,
    bluetoothUsable: Bool? = nil
  ) -> CommandOutcome {
    StatusCommand.outcome(
      session: session(
        document: document,
        scanResult: scanResult,
        bluetoothUsable: bluetoothUsable
      ),
      named: named,
      logger: DebugLogger(enabled: false)
    )
  }

  func learn(
    document: BluetoothSettingsDocument,
    scanResult: BluetoothScanResult,
    now: Date = Date()
  ) -> BluetoothSettingsDocument {
    let advertisements = scanResult.radio == .poweredOn
      ? scanResult.advertisements
      : []
    return BluetoothLearning.learn(
      document: document,
      targets: devices.compactMap { device in
        document.target(
          name: device.name,
          correlation: correlation(device),
          placement: device.readInEarPlacementStatus()
        )
      },
      observations: AirPodsBLEScanNormalizer.normalize(advertisements),
      conflictingProductIDs: BluetoothLearning.conflictingProductIDs(
        advertisements
      ),
      now: now
    )
  }
}

func coordinatorInventory(
  placement: BluetoothEarPlacementRead,
  coreAudioUID: String = "core-audio-uid",
  includeCorrelationMetadata: Bool = true
) -> CoordinatorInventory {
  let object = EqualBluetoothObject(identity: 44)
  let endpoint = FakeInventoryEndpoint(
    audioDeviceID: AudioDeviceID(44),
    bluetoothDevice: object,
    name: .value("Test AirPods"),
    inEarPlacement: placement,
    deviceUID: .value(coreAudioUID),
    modelUID: .value("BTHeadphones76,8228")
  )
  let (controller, _) = makeBluetoothController(
    inventory: [endpoint],
    readBluetoothCorrelationMetadata: includeCorrelationMetadata
  )
  return CoordinatorInventory(
    devices: controller.statusDevices(),
    correlation: { controller.bluetoothCorrelation(for: $0) }
  )
}

func emptyCoordinatorInventory() -> CoordinatorInventory {
  CoordinatorInventory(devices: [], correlation: { _ in nil })
}

func authorizedScan(
  identifier: UUID,
  status: UInt8
) -> BluetoothScanResult {
  BluetoothScanResult(
    authorization: .authorized,
    radio: .poweredOn,
    advertisements: coordinatorAdvertisements(identifier: identifier, status: status)
  )
}

func associatedDocument(identifier: UUID) -> BluetoothSettingsDocument {
  var document = BluetoothSettingsDocument.empty(enabled: true)
  document.associations = [
    BluetoothAssociation(
      associationID: UUID(),
      peripheralIdentifier: identifier,
      coreAudioUIDDigests: [document.digestCoreAudioUID("core-audio-uid")],
      productID: 0x2024,
      displayName: "Test AirPods",
      provenance: .automatic
    ),
  ]
  return document
}

func testBluetoothStatusSourcePrecedence() {
  let identifier = UUID()
  let document = associatedDocument(identifier: identifier)
  let scan = authorizedScan(identifier: identifier, status: 0x0A)
  let halPlacement = BluetoothEarPlacement(left: .outOfEar, right: .inEar)

  let hal = coordinatorInventory(placement: .value(halPlacement)).statusOutcome(
    document: document,
    scanResult: scan
  )
  check(
    statusRecords(hal)?.first?["leftEarPlacement"] as? String == "out-of-ear",
    "valid HAL placement wins over BLE"
  )
  check(
    statusRecords(hal)?.first?["rightEarPlacement"] as? String == "in-ear",
    "valid HAL placement keeps the HAL right bud"
  )

  let fallback = coordinatorInventory(placement: .unavailable).statusOutcome(
    document: document,
    scanResult: scan
  )
  check(
    statusRecords(fallback)?.first?["leftEarPlacement"] as? String == "in-ear",
    "BLE fills unsupported HAL placement"
  )
  check(
    statusRecords(fallback)?.first?["rightEarPlacement"] as? String == "in-ear",
    "BLE fills both unsupported HAL buds"
  )

  let blocked = coordinatorInventory(placement: .unknown).statusOutcome(
    document: document,
    scanResult: scan
  )
  check(
    statusRecords(blocked)?.first?["leftEarPlacement"] is NSNull,
    "unknown HAL evidence blocks BLE fallback"
  )
}

func testBluetoothStatusRequiresFreshStableObservation() {
  let identifier = UUID()
  let document = associatedDocument(identifier: identifier)
  let inventory = coordinatorInventory(placement: .unavailable)
  let oneFrame = inventory.statusOutcome(
    document: document,
    scanResult: BluetoothScanResult(
      authorization: .authorized,
      radio: .poweredOn,
      advertisements: Array(
        coordinatorAdvertisements(identifier: identifier, status: 0x0A).prefix(1)
      )
    )
  )
  check(
    statusRecords(oneFrame)?.first?["leftEarPlacement"] is NSNull,
    "one BLE callback becomes unknown"
  )

  let denied = inventory.statusOutcome(
    document: document,
    scanResult: BluetoothScanResult(
      authorization: .denied,
      radio: .unauthorized,
      advertisements: []
    )
  )
  check(
    statusRecords(denied)?.first?["leftEarPlacement"] == nil,
    "missing permission preserves existing HAL behavior"
  )

  let poweredOff = inventory.statusOutcome(
    document: document,
    scanResult: BluetoothScanResult(
      authorization: .authorized,
      radio: .poweredOff,
      advertisements: []
    )
  )
  check(
    statusRecords(poweredOff)?.first?["leftEarPlacement"] is NSNull,
    "authorized radio-off silence is unknown for an enrollment"
  )
}

func testBluetoothStatusChangedUIDFailsClosed() {
  let identifier = UUID()
  let document = associatedDocument(identifier: identifier)
  let scan = authorizedScan(identifier: identifier, status: 0x0A)
  let inventory = coordinatorInventory(
    placement: .unavailable,
    coreAudioUID: "changed-core-audio-uid"
  )
  let result = inventory.statusOutcome(document: document, scanResult: scan)
  let records = statusRecords(result) ?? []
  check(records.count == 2, "changed UID keeps HAL and BLE-only records")
  check(
    records.contains { $0["leftEarPlacement"] == nil },
    "HAL without digest match omits BLE placement"
  )
  check(
    records.contains { $0["leftEarPlacement"] as? String == "in-ear" },
    "enrolled ads still create a BLE-only record"
  )
  let named = inventory.statusOutcome(
    document: document,
    scanResult: scan,
    named: "Test AirPods"
  )
  check(
    named.terminalReason == .ambiguousDevice,
    "same heading on HAL and BLE-only is ambiguous"
  )
  check(
    inventory.learn(document: document, scanResult: scan).candidates.isEmpty,
    "identity conflict blocks relearning"
  )
}

func testBluetoothStatusMissingIdentityFailsClosed() {
  let identifier = UUID()
  let result = coordinatorInventory(
    placement: .unavailable,
    includeCorrelationMetadata: false
  ).statusOutcome(
    document: associatedDocument(identifier: identifier),
    scanResult: authorizedScan(identifier: identifier, status: 0x0A)
  )
  let records = statusRecords(result) ?? []
  check(records.count == 2, "missing correlation keeps HAL and BLE-only records")
  check(
    records.contains { $0["leftEarPlacement"] == nil },
    "HAL without correlation omits BLE placement"
  )
  check(
    records.contains { $0["leftEarPlacement"] as? String == "in-ear" },
    "enrolled ads still create a BLE-only record"
  )
}

func testBluetoothStatusAutomaticLearning() {
  let identifier = UUID()
  let now = Date(timeIntervalSince1970: 2_000_000)
  let bothIn = coordinatorInventory(
    placement: .value(BluetoothEarPlacement(left: .inEar, right: .inEar))
  )
  let scan = authorizedScan(identifier: identifier, status: 0x0A)
  let first = bothIn.learn(
    document: .empty(enabled: true),
    scanResult: scan,
    now: now
  )
  check(first.associations.isEmpty, "one learned state does not enroll")
  check(first.candidates.count == 1, "first agreement is provisional")

  let repeated = bothIn.learn(
    document: first,
    scanResult: scan,
    now: now.addingTimeInterval(23 * 60 * 60)
  )
  check(
    repeated.candidates.first?.expiresAt == first.candidates.first?.expiresAt,
    "repeating one state does not extend the learning window"
  )
  check(repeated == first, "unchanged learning does not rewrite the document")

  let second = coordinatorInventory(
    placement: .value(BluetoothEarPlacement(left: .inEar, right: .outOfEar))
  ).learn(
    document: first,
    scanResult: authorizedScan(identifier: identifier, status: 0x22),
    now: now.addingTimeInterval(60)
  )
  check(second.associations.count == 1, "two states enroll automatically")
  check(
    second.associations.first?.provenance == .automatic,
    "learned association records automatic provenance"
  )
  check(second.candidates.isEmpty, "promotion clears provisional evidence")
}

func testBluetoothStatusConflictResetsLearning() {
  let identifier = UUID()
  let inventory = coordinatorInventory(
    placement: .value(BluetoothEarPlacement(left: .inEar, right: .inEar))
  )
  let first = inventory.learn(
    document: .empty(enabled: true),
    scanResult: authorizedScan(identifier: identifier, status: 0x0A)
  )
  let conflicting = BluetoothScanResult(
    authorization: .authorized,
    radio: .poweredOn,
    advertisements: [
      coordinatorAdvertisements(identifier: identifier, status: 0x0A)[0],
      coordinatorAdvertisements(identifier: identifier, status: 0x00)[0],
    ]
  )
  let result = inventory.learn(document: first, scanResult: conflicting)
  check(result.candidates.isEmpty, "conflicting frames reset learning")

  let disagreement = inventory.learn(
    document: first,
    scanResult: authorizedScan(identifier: identifier, status: 0x00)
  )
  check(
    disagreement.candidates.isEmpty,
    "HAL and BLE disagreement resets learning"
  )
}

func testBluetoothStatusCreatesBLEOnlyRecord() {
  let identifier = UUID()
  let document = associatedDocument(identifier: identifier)
  let silent = emptyCoordinatorInventory().statusOutcome(
    document: document,
    scanResult: BluetoothScanResult(
      authorization: .authorized,
      radio: .poweredOn,
      advertisements: []
    )
  )
  check(silent.terminalReason == .noDevice, "silence does not create a BLE-only record")

  let result = emptyCoordinatorInventory().statusOutcome(
    document: document,
    scanResult: authorizedScan(identifier: identifier, status: 0x0A)
  )
  check(
    statusRecords(result)?.count == 1,
    "current enrolled BLE creates a status record"
  )
  check(
    statusRecords(result)?.first?["device"] as? String == "Test AirPods",
    "BLE-only record uses stored name"
  )
  check(
    statusRecords(result)?.first?["listeningMode"] is NSNull,
    "BLE-only listening mode is unresolved"
  )
  check(
    statusRecords(result)?.first?["isSelectedAudioOutput"] is NSNull,
    "BLE-only route selection is unresolved"
  )

  let named = emptyCoordinatorInventory().statusOutcome(
    document: document,
    scanResult: authorizedScan(identifier: identifier, status: 0x0A),
    named: "test airpods"
  )
  check(
    statusRecords(named)?.first?["device"] as? String == "Test AirPods",
    "named status can select a BLE-only record"
  )
}

func runBluetoothStatusCoordinatorTests() {
  testBluetoothStatusSourcePrecedence()
  testBluetoothStatusRequiresFreshStableObservation()
  testBluetoothStatusChangedUIDFailsClosed()
  testBluetoothStatusMissingIdentityFailsClosed()
  testBluetoothStatusAutomaticLearning()
  testBluetoothStatusConflictResetsLearning()
  testBluetoothStatusCreatesBLEOnlyRecord()
}
