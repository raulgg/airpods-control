import CoreAudio
import Foundation

private final class InMemoryBluetoothAssociationStore: BluetoothAssociationStoring {
  var result: BluetoothSettingsLoadResult
  private(set) var saves: [BluetoothSettingsDocument] = []

  init(_ result: BluetoothSettingsLoadResult = .missing) {
    self.result = result
  }

  func load() -> BluetoothSettingsLoadResult { result }

  func save(_ document: BluetoothSettingsDocument) throws {
    saves.append(document)
    result = .value(document)
  }
}

private final class FakeBluetoothScanner: BluetoothScanning {
  var authorizationState: BluetoothAuthorizationState = .authorized
  var results: [BluetoothScanResult] = []
  private(set) var scanDurations: [TimeInterval] = []
  private(set) var permissionRequestCount = 0

  func authorization() -> BluetoothAuthorizationState { authorizationState }

  func radioState() -> BluetoothRadioState? {
    authorizationState == .authorized ? .poweredOn : nil
  }

  func requestAuthorization(timeout: TimeInterval) -> BluetoothScanResult {
    permissionRequestCount += 1
    return BluetoothScanResult(
      authorization: authorizationState,
      radio: authorizationState == .authorized ? .poweredOn : .unauthorized,
      advertisements: []
    )
  }

  func scan(duration: TimeInterval) -> BluetoothScanResult {
    scanDurations.append(duration)
    if !results.isEmpty { return results.removeFirst() }
    return BluetoothScanResult(
      authorization: authorizationState,
      radio: authorizationState == .authorized ? .poweredOn : .unauthorized,
      advertisements: []
    )
  }
}

private func bluetoothCommandOutcome(
  _ arguments: [String],
  store: InMemoryBluetoothAssociationStore,
  scanner: FakeBluetoothScanner,
  resolve: @escaping () -> CoordinatorInventory = { emptyCoordinatorInventory() },
  interactive: Bool = false,
  readResponse: @escaping () -> String? = { nil }
) -> CommandOutcome {
  CommandExecution.executeBluetooth(
    try! parseInvocation(arguments),
    store: store,
    scanner: scanner,
    resolveStatusInventory: {
      let inventory = resolve()
      return (inventory.devices, inventory.correlation)
    },
    interactive: interactive,
    readResponse: readResponse,
    writePrompt: { _ in }
  )
}

func testBluetoothSetupStatusAndDisableCommands() {
  let store = InMemoryBluetoothAssociationStore()
  let scanner = FakeBluetoothScanner()
  let setup = bluetoothCommandOutcome(
    ["bluetooth", "setup"],
    store: store,
    scanner: scanner
  )
  check(setup.exitCode == 0, "bluetooth setup succeeds")
  check(store.saves.last?.enabled == true, "setup enables local integration")
  check(scanner.permissionRequestCount == 1, "only setup requests permission")

  let status = bluetoothCommandOutcome(
    ["bluetooth", "status", "--json"],
    store: store,
    scanner: scanner
  )
  check(status.exitCode == 0, "bluetooth status succeeds")
  check(scanner.scanDurations.isEmpty, "bluetooth status does not scan")
  check(status.payload["enabled"] as? Bool == true, "status reports enablement")

  let disable = bluetoothCommandOutcome(
    ["bluetooth", "disable"],
    store: store,
    scanner: scanner
  )
  check(disable.exitCode == 0, "bluetooth disable succeeds")
  check(store.saves.last?.enabled == false, "disable changes only local enablement")
}

func testBluetoothUnenrollCommand() {
  let identifier = UUID()
  let store = InMemoryBluetoothAssociationStore(
    .value(associatedDocument(identifier: identifier))
  )
  let scanner = FakeBluetoothScanner()
  let outcome = bluetoothCommandOutcome(
    ["bluetooth", "unenroll", "--device", "test airpods"],
    store: store,
    scanner: scanner
  )
  check(outcome.plain == "unenrolled", "unenroll uses the accepted verb")
  check(store.saves.last?.associations.isEmpty == true, "unenroll deletes evidence")
  check(store.saves.last?.enabled == true, "unenroll keeps integration enabled")
  check(scanner.scanDurations.isEmpty, "unenroll does not scan")

  var document = BluetoothSettingsDocument.empty(enabled: true)
  document.candidates = [
    BluetoothAssociationCandidate(
      peripheralIdentifier: UUID(),
      coreAudioUIDDigests: [document.digestCoreAudioUID("uid-a")],
      productID: 0x2024,
      displayName: "Test AirPods",
      observedStates: 0x01,
      expiresAt: Date().addingTimeInterval(3_600)
    ),
    BluetoothAssociationCandidate(
      peripheralIdentifier: UUID(),
      coreAudioUIDDigests: [document.digestCoreAudioUID("uid-b")],
      productID: 0x200E,
      displayName: "test airpods",
      observedStates: 0x01,
      expiresAt: Date().addingTimeInterval(3_600)
    ),
  ]
  let ambiguousStore = InMemoryBluetoothAssociationStore(.value(document))
  let ambiguous = bluetoothCommandOutcome(
    ["bluetooth", "unenroll", "--device", "Test AirPods"],
    store: ambiguousStore,
    scanner: scanner
  )
  check(
    ambiguous.plain == "ambiguous-device",
    "same-name candidates of different products stay ambiguous"
  )
  check(ambiguousStore.saves.isEmpty, "ambiguous unenroll does not write")
}

func testBluetoothCommandMalformedSettingsFailClosed() {
  let store = InMemoryBluetoothAssociationStore(.invalid)
  let scanner = FakeBluetoothScanner()
  for arguments in [
    ["bluetooth", "status"],
    ["bluetooth", "disable"],
    ["bluetooth", "unenroll", "--device", "Test AirPods"],
  ] {
    let outcome = bluetoothCommandOutcome(
      arguments,
      store: store,
      scanner: scanner
    )
    check(outcome.exitCode != 0, "malformed settings fail management command")
  }
  check(store.saves.isEmpty, "malformed settings are never overwritten")
}

func testBluetoothEnrollDeniedPermissionIsSafe() {
  let store = InMemoryBluetoothAssociationStore(
    .value(.empty(enabled: true))
  )
  let scanner = FakeBluetoothScanner()
  scanner.authorizationState = .denied
  var resolvedDevices = false
  let outcome = bluetoothCommandOutcome(
    ["bluetooth", "enroll", "--device", "Test AirPods"],
    store: store,
    scanner: scanner,
    resolve: {
      resolvedDevices = true
      return emptyCoordinatorInventory()
    },
    interactive: true
  )
  check(outcome.exitCode == 6, "denied enrollment returns unavailable")
  check(!resolvedDevices, "denied enrollment does not touch Core Audio identity")
  check(scanner.scanDurations.isEmpty, "denied enrollment does not scan")
}

func testBluetoothManualEnrollment() {
  let identifier = UUID()
  let store = InMemoryBluetoothAssociationStore(
    .value(.empty(enabled: true))
  )
  let scanner = FakeBluetoothScanner()
  scanner.results = [
    authorizedScan(identifier: identifier, status: 0x0A),
    authorizedScan(identifier: identifier, status: 0x22),
  ]
  let inventories = [
    coordinatorInventory(
      placement: .value(BluetoothEarPlacement(left: .inEar, right: .inEar))
    ),
    coordinatorInventory(
      placement: .value(BluetoothEarPlacement(left: .inEar, right: .outOfEar))
    ),
  ]
  var deviceIndex = 0
  let outcome = bluetoothCommandOutcome(
    ["bluetooth", "enroll", "--device", "Test AirPods"],
    store: store,
    scanner: scanner,
    resolve: {
      guard deviceIndex < inventories.count else {
        return emptyCoordinatorInventory()
      }
      defer { deviceIndex += 1 }
      return inventories[deviceIndex]
    },
    interactive: true,
    readResponse: { "" }
  )
  check(outcome.plain == "enrolled", "manual enrollment verifies two states")
  check(
    store.saves.last?.associations.first?.provenance == .userVerified,
    "manual enrollment records user-verified provenance"
  )
}

func runBluetoothCommandTests() {
  testBluetoothSetupStatusAndDisableCommands()
  testBluetoothUnenrollCommand()
  testBluetoothCommandMalformedSettingsFailClosed()
  testBluetoothEnrollDeniedPermissionIsSafe()
  testBluetoothManualEnrollment()
}
