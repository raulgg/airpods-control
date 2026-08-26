import CoreAudio
import Dispatch
import Foundation

private final class FakeListeningModeTransport: ListeningModeAllowOffTransport {
  let name: String?
  let listeningModeTransportKind: ListeningModeTransportKind
  var modes: [ListeningMode]
  var current: ListeningMode?
  var settable: Bool
  var appliesWrites: Bool
  var availabilityObservation: ListeningModeAvailabilityObservation?
  var onAvailabilityRead: (() -> Void)?
  var dropsWriteReadback = false
  private(set) var readModesCount = 0
  private(set) var readCurrentCount = 0
  private(set) var canSetCount = 0
  private(set) var setterTargets: [ListeningMode] = []
  private(set) var allowOffWrites: [Bool] = []

  init(
    name: String,
    kind: ListeningModeTransportKind,
    modes: [ListeningMode] = ListeningMode.allCases,
    current: ListeningMode? = .transparency,
    settable: Bool = true,
    appliesWrites: Bool = true
  ) {
    self.name = name
    listeningModeTransportKind = kind
    self.modes = modes
    self.current = current
    self.settable = settable
    self.appliesWrites = appliesWrites
  }

  func availableListeningModes() -> [ListeningMode] {
    readModesCount += 1
    return modes
  }

  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation {
    readModesCount += 1
    onAvailabilityRead?()
    return availabilityObservation ?? .value(modes)
  }

  func currentListeningMode() -> ListeningMode? {
    readCurrentCount += 1
    return current
  }

  func canSetListeningMode() -> Bool {
    canSetCount += 1
    return settable
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    allowOffWrites.append(false)
    return applyWrite(target)
  }

  func setListeningModeAndReadBackAllowingOff(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    allowOffWrites.append(true)
    return applyWrite(target)
  }

  private func applyWrite(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    setterTargets.append(target)
    if appliesWrites { current = target }
    return DeviceWriteObservation(
      setterAccepted: settable,
      observed: dropsWriteReadback ? nil : current
    )
  }

  func settle(for interval: TimeInterval) {}
}

private final class OrdinaryHALListeningModeTransport: ListeningModeTransport {
  private let wrapped: FakeListeningModeTransport

  init(wrapped: FakeListeningModeTransport) {
    self.wrapped = wrapped
  }

  var name: String? { wrapped.name }
  var listeningModeTransportKind: ListeningModeTransportKind {
    wrapped.listeningModeTransportKind
  }

  func availableListeningModes() -> [ListeningMode] {
    wrapped.availableListeningModes()
  }

  func listeningModeAvailabilityObservation() -> ListeningModeAvailabilityObservation {
    wrapped.listeningModeAvailabilityObservation()
  }

  func currentListeningMode() -> ListeningMode? {
    wrapped.currentListeningMode()
  }

  func canSetListeningMode() -> Bool {
    wrapped.canSetListeningMode()
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    wrapped.setListeningModeAndReadBack(target)
  }

  func settle(for interval: TimeInterval) {
    wrapped.settle(for: interval)
  }
}

private final class FakeHALRoutingBackend: AudioRoutingBackend {
  var rawModeRead: AudioRoutingRead<UInt32> = .value(3)
  var supportRead: AudioRoutingRead<UInt32> = .value(0b111)
  var settableRead: AudioRoutingRead<Bool> = .value(true)
  var writeResult: AudioRoutingWrite = .success
  var appliesWrite = true
  var deviceUIDs: [AudioDeviceID: AudioRoutingRead<String?>] = [:]
  var onDeviceUIDRead: (() -> Void)?
  private(set) var writtenValues: [UInt32] = []
  private(set) var deviceUIDReads: [AudioDeviceID] = []

  func readAudioDevices() -> AudioRoutingRead<[AudioDeviceID]> { .unavailable }
  func readDefaultDevice(
    for direction: AudioRoutingDirection
  ) -> AudioRoutingRead<AudioDeviceID?> { .unavailable }
  func isAggregateDevice(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    .unavailable
  }
  func readTransportType(for deviceID: AudioDeviceID) -> AudioRoutingRead<UInt32> {
    .unavailable
  }
  func readDeviceIsAlive(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    .unavailable
  }
  func readHasStreams(
    for deviceID: AudioDeviceID,
    direction: AudioRoutingDirection
  ) -> AudioRoutingRead<Bool> { .unavailable }
  func readManufacturer(for deviceID: AudioDeviceID) -> AudioRoutingRead<String?> {
    .unavailable
  }
  func readName(for deviceID: AudioDeviceID) -> AudioRoutingRead<String?> {
    .unavailable
  }
  func readDeviceUID(for deviceID: AudioDeviceID) -> AudioRoutingRead<String?> {
    deviceUIDReads.append(deviceID)
    onDeviceUIDRead?()
    return deviceUIDs[deviceID] ?? .unavailable
  }
  func readIsAppleAudioDevice(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    .unavailable
  }
  func readBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> { rawModeRead }
  func hasBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> Bool { true }
  func readBluetoothListeningModeSupport(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> { supportRead }
  func isBluetoothListeningModeSettable(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<Bool> { settableRead }
  func writeBluetoothListeningMode(
    _ rawValue: UInt32,
    for deviceID: AudioDeviceID
  ) -> AudioRoutingWrite {
    writtenValues.append(rawValue)
    if appliesWrite, writeResult == .success {
      rawModeRead = .value(rawValue)
    }
    return writeResult
  }

  func resetWrites() {
    writtenValues.removeAll()
  }
}

private final class FailingRemovalAllowOffCache: ListeningModeAllowOffCaching {
  let wrapped: InMemoryListeningModeAllowOffCache

  init(wrapped: InMemoryListeningModeAllowOffCache) {
    self.wrapped = wrapped
  }

  func lookup(rawDeviceUID: String) -> AllowOffCacheLookup {
    wrapped.lookup(rawDeviceUID: rawDeviceUID)
  }

  func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    guard allowsOff else { return .unavailable }
    return wrapped.applyObservation(
      rawDeviceUID: rawDeviceUID,
      allowsOff: true,
      observedAt: observedAt
    )
  }

  func remove(record: AllowOffCacheRecord) -> AllowOffCacheMutation {
    wrapped.remove(record: record)
  }
}

private final class StalePositiveAllowOffCache: ListeningModeAllowOffCaching {
  func lookup(rawDeviceUID: String) -> AllowOffCacheLookup {
    .miss
  }

  func applyObservation(
    rawDeviceUID: String,
    allowsOff: Bool,
    observedAt: Date
  ) -> AllowOffCacheMutation {
    allowsOff ? .unchanged : .unavailable
  }

  func remove(record: AllowOffCacheRecord) -> AllowOffCacheMutation {
    .unchanged
  }
}

private func coordinatorOutcome(
  _ arguments: [String],
  candidates: [ListeningModeCandidate],
  choice: ListeningModeAmbiguousChoice = .unavailable
) -> CommandOutcome {
  let invocation = try! parseInvocation(arguments)
  let coordinator = ListeningModeCoordinator(
    candidates: candidates,
    logger: DebugLogger(enabled: false)
  )
  return CommandExecution.executeListeningMode(
    invocation,
    resolveSession: { command, name, _ in
      coordinator.resolve(
        command: command,
        named: name,
        chooseAmbiguous: { _ in choice }
      )
    }
  )
}

private func candidate(
  name: String = "Desk AirPods",
  av: FakeListeningModeTransport? = nil,
  hal: FakeListeningModeTransport? = nil,
  route: ListeningModeCandidateRoute,
  allowOffCorrelation: ListeningModeAllowOffCorrelation? = nil
) -> ListeningModeCandidate {
  ListeningModeCandidate(
    displayName: name,
    selectableNames: [name],
    avTransport: av,
    halTransport: hal,
    route: route,
    allowOffCorrelation: allowOffCorrelation
  )
}

func testListeningModeCoordinatorRouteAndPreflightSelection() {
  let selectedAV = FakeListeningModeTransport(
    name: "Desk AirPods",
    kind: .av,
    current: .transparency
  )
  let selectedHAL = FakeListeningModeTransport(
    name: "Desk AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .transparency
  )
  let selectedOutcome = coordinatorOutcome(
    ["lm", "set", "adaptive"],
    candidates: [candidate(av: selectedAV, hal: selectedHAL, route: .selected)]
  )
  check(selectedOutcome.plain == "ok", "selected output uses its ready AV transport")
  check(selectedAV.setterTargets == [.adaptive], "selected AV receives the setter")
  check(selectedHAL.setterTargets.isEmpty, "selected HAL remains untouched")
  check(
    selectedHAL.readModesCount == 0
      && selectedHAL.readCurrentCount == 0
      && selectedHAL.canSetCount == 0,
    "a command-ready AV preflight never consults HAL"
  )

  let unselectedAV = FakeListeningModeTransport(name: "Travel AirPods", kind: .av)
  let unselectedHAL = FakeListeningModeTransport(
    name: "Travel AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation]
  )
  _ = coordinatorOutcome(
    ["lm", "set", "adaptive"],
    candidates: [
      candidate(
        name: "Travel AirPods",
        av: unselectedAV,
        hal: unselectedHAL,
        route: .notSelected
      )
    ]
  )
  check(unselectedAV.readCurrentCount == 0, "proven unselected route does not preflight AV")
  check(unselectedAV.setterTargets.isEmpty, "proven unselected route never writes through AV")
  check(unselectedHAL.setterTargets == [.adaptive], "proven unselected route writes through HAL")

  let incompleteAV = FakeListeningModeTransport(
    name: "Fallback AirPods",
    kind: .av,
    modes: [.transparency],
    current: .transparency
  )
  let fallbackHAL = FakeListeningModeTransport(
    name: "Fallback AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .transparency
  )
  let fallbackOutcome = coordinatorOutcome(
    ["lm", "set", "adaptive"],
    candidates: [
      candidate(
        name: "Fallback AirPods",
        av: incompleteAV,
        hal: fallbackHAL,
        route: .unknown
      )
    ]
  )
  check(fallbackOutcome.plain == "ok", "unknown route falls back after AV preflight")
  check(incompleteAV.setterTargets.isEmpty, "failed AV preflight performs no setter")
  check(fallbackHAL.setterTargets == [.adaptive], "HAL handles the preflight fallback")
}

func testListeningModeCoordinatorPreservesAVUnknownStateWrites() {
  let setAV = FakeListeningModeTransport(
    name: "Unknown AV AirPods",
    kind: .av,
    current: nil
  )
  let setOutcome = coordinatorOutcome(
    ["lm", "set", "adaptive"],
    candidates: [candidate(av: setAV, route: .unknown)]
  )
  check(setOutcome.plain == "ok", "AV set preserves its unknown-current behavior")
  check(setAV.setterTargets == [.adaptive], "AV set with unknown current writes once")

  let cycleAV = FakeListeningModeTransport(
    name: "Unknown Cycle AirPods",
    kind: .av,
    current: nil
  )
  let cycleOutcome = coordinatorOutcome(
    ["lm", "cycle"],
    candidates: [candidate(av: cycleAV, route: .unknown)]
  )
  check(
    cycleOutcome.plain == "transparency",
    "AV cycle with unknown current starts at the first default mode"
  )
  check(cycleAV.setterTargets == [.transparency], "unknown AV cycle writes its first target")
}

func testListeningModeCoordinatorReadsOnlyCommandRequirements() {
  let getTransport = FakeListeningModeTransport(
    name: "Get AirPods",
    kind: .hal,
    current: .adaptive
  )
  let getOutcome = coordinatorOutcome(
    ["lm", "get"],
    candidates: [candidate(name: "Get AirPods", hal: getTransport, route: .notSelected)]
  )
  check(getOutcome.plain == "adaptive", "get reads the current provider state")
  check(getTransport.readCurrentCount == 1, "get reads current exactly once")
  check(getTransport.readModesCount == 0, "get does not read mode inventory")
  check(getTransport.canSetCount == 0, "get does not inspect setter writability")

  let listTransport = FakeListeningModeTransport(
    name: "List AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive],
    current: .transparency
  )
  let listOutcome = coordinatorOutcome(
    ["lm", "list"],
    candidates: [candidate(name: "List AirPods", hal: listTransport, route: .notSelected)]
  )
  check(listOutcome.plain == "transparency,adaptive", "list reads current inventory")
  check(listTransport.readCurrentCount == 1, "list reads current exactly once")
  check(listTransport.readModesCount == 1, "list reads inventory exactly once")
  check(listTransport.canSetCount == 0, "list does not inspect setter writability")
}

func testListeningModeCoordinatorNeverFallsBackAfterASetter() {
  let av = FakeListeningModeTransport(
    name: "Sticky AirPods",
    kind: .av,
    current: .transparency,
    appliesWrites: false
  )
  let hal = FakeListeningModeTransport(
    name: "Sticky AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .transparency
  )
  let outcome = coordinatorOutcome(
    ["lm", "set", "adaptive"],
    candidates: [candidate(name: "Sticky AirPods", av: av, hal: hal, route: .selected)]
  )
  check(outcome.plain == "no-op", "nonmatching selected-provider readback is a no-op")
  check(av.setterTargets == [.adaptive], "selected provider performs exactly one setter")
  check(hal.setterTargets.isEmpty, "a post-setter failure never falls through to HAL")
}

func testListeningModeCoordinatorAmbiguityAndCancellation() {
  let first = FakeListeningModeTransport(name: "Desk AirPods", kind: .hal)
  let second = FakeListeningModeTransport(name: "Travel AirPods", kind: .hal)
  let candidates = [
    candidate(name: "Desk AirPods", hal: first, route: .notSelected),
    candidate(name: "Travel AirPods", hal: second, route: .notSelected),
  ]

  let ambiguous = coordinatorOutcome(["lm", "get", "--json"], candidates: candidates)
  check(ambiguous.plain == "ambiguous-device", "noninteractive ambiguity is specific")
  check(ambiguous.exitCode == 1, "ambiguous device exits one")
  check(
    ambiguous.payload["error"] as? String == "ambiguous-device",
    "ambiguous JSON has its specific error"
  )
  check(ambiguous.payload["listeningMode"] is NSNull, "ambiguous state is JSON null")

  let chosen = coordinatorOutcome(
    ["lm", "get"],
    candidates: candidates,
    choice: .selected(index: 1)
  )
  check(chosen.payload["device"] as? String == "Travel AirPods", "chooser index selects target")

  let cancelled = coordinatorOutcome(
    ["lm", "get"],
    candidates: candidates,
    choice: .cancelled
  )
  check(cancelled.plain == "cancelled", "interactive cancellation has stable plain output")
  check(cancelled.exitCode == 1, "interactive cancellation exits one")

  let duplicateNameCandidates = [
    candidate(name: "Same AirPods", hal: first, route: .notSelected),
    candidate(name: "Same AirPods", hal: second, route: .notSelected),
  ]
  let duplicate = coordinatorOutcome(
    ["--device", "same airpods", "lm", "get"],
    candidates: duplicateNameCandidates,
    choice: .selected(index: 0)
  )
  check(duplicate.plain == "ambiguous-device", "duplicate exact names never prompt or select")
}

func testListeningModeCoordinatorPrefersSelectedAVOverSoleInactiveHAL() {
  let selectedAV = FakeListeningModeTransport(name: "Selected AirPods", kind: .av)
  let inactiveHAL = FakeListeningModeTransport(name: "Inactive AirPods", kind: .hal)
  let candidates = [
    candidate(name: "Selected AirPods", av: selectedAV, route: .selected),
    candidate(name: "Inactive AirPods", hal: inactiveHAL, route: .notSelected),
  ]

  let outcome = coordinatorOutcome(
    ["lm", "set", "adaptive"],
    candidates: candidates
  )

  check(outcome.plain == "ok", "the selected AV target resolves")
  check(selectedAV.setterTargets == [.adaptive], "the selected AV target receives the setter")
  check(inactiveHAL.setterTargets.isEmpty, "the inactive HAL target remains untouched")

  let otherSelectedAV = FakeListeningModeTransport(name: "Other AirPods", kind: .av)
  let ambiguousOutcome = coordinatorOutcome(
    ["lm", "set", "adaptive"],
    candidates: candidates + [
      candidate(name: "Other AirPods", av: otherSelectedAV, route: .selected)
    ]
  )

  check(ambiguousOutcome.plain == "ambiguous-device", "multiple selected AV targets fail closed")
  check(selectedAV.setterTargets == [.adaptive], "ambiguous resolution does not write again")
  check(otherSelectedAV.setterTargets.isEmpty, "an ambiguous selected AV target is not written")
  check(inactiveHAL.setterTargets.isEmpty, "ambiguous resolution does not write the HAL target")
}

func testListeningModeCoordinatorKeepsHALIdentitySeparateFromAVNames() {
  let logger = DebugLogger(enabled: false)
  let activeRaw = FakeRawDevice(name: "Desk AirPods")
  let activeAV = PrivateAudioDevice.compatible(
    object: activeRaw,
    sources: [.contextSingular],
    index: 0,
    logger: logger
  )!
  let selectedHAL = FakeListeningModeTransport(name: "Desk AirPods", kind: .hal)
  let selectedCandidate = candidate(
    name: "Desk AirPods",
    hal: selectedHAL,
    route: .selected
  )
  let selectedCoordinator = ListeningModeCoordinator(
    avDevices: [activeAV],
    halCandidates: [selectedCandidate],
    logger: logger
  )
  let unnamedSelected = selectedCoordinator.resolve(
    command: .get,
    named: nil,
    chooseAmbiguous: { _ in .unavailable }
  )
  if case .session(let session) = unnamedSelected {
    check(
      session.transport.listeningModeTransportKind == .av,
      "a unique selected HAL target pairs with the unique active AV endpoint"
    )
  } else {
    check(false, "a unique selected pair must resolve without ambiguity")
  }
  let namedSelected = selectedCoordinator.resolve(
    command: .get,
    named: "desk airpods",
    chooseAmbiguous: { _ in .unavailable }
  )
  if case .session(let session) = namedSelected {
    check(
      session.transport.listeningModeTransportKind == .av,
      "an exact HAL name still pairs the unique selected AV endpoint"
    )
  } else {
    check(false, "a shared AV/HAL name identifies one selected logical target")
  }

  let pluralRaw = FakeRawDevice(name: "Nearby AirPods")
  let pluralAV = PrivateAudioDevice.compatible(
    object: pluralRaw,
    sources: [.contextPlural],
    index: 1,
    logger: logger
  )!
  let unselectedHAL = FakeListeningModeTransport(name: "Desk AirPods", kind: .hal)
  let unselectedCoordinator = ListeningModeCoordinator(
    avDevices: [pluralAV],
    halCandidates: [
      candidate(name: "Desk AirPods", hal: unselectedHAL, route: .notSelected)
    ],
    logger: logger
  )
  let namedUnselected = unselectedCoordinator.resolve(
    command: .get,
    named: "Desk AirPods",
    chooseAmbiguous: { _ in .unavailable }
  )
  if case .session(let session) = namedUnselected {
    check(
      session.transport.listeningModeTransportKind == .hal,
      "an unselected HAL target remains reachable beside a differently named AV target"
    )
  } else {
    check(false, "the unique unselected HAL name resolves without ambiguity")
  }

  let independentAV = FakeListeningModeTransport(
    name: "Desk AirPods",
    kind: .av
  )
  let sameName = coordinatorOutcome(
    ["--device", "Desk AirPods", "lm", "set", "adaptive"],
    candidates: [
      candidate(name: "Desk AirPods", av: independentAV, route: .unknown),
      candidate(name: "Desk AirPods", hal: unselectedHAL, route: .notSelected),
    ]
  )
  check(
    sameName.plain == "ambiguous-device",
    "independent AV and HAL targets with the same name stay ambiguous"
  )
  check(independentAV.setterTargets.isEmpty, "ambiguous AV target is not written")
  check(unselectedHAL.setterTargets.isEmpty, "ambiguous HAL target is not written")

  let otherRaw = FakeRawDevice(name: "Travel AirPods")
  let otherAV = PrivateAudioDevice.compatible(
    object: otherRaw,
    sources: [.contextPlural],
    index: 2,
    logger: logger
  )!
  let mixedCoordinator = ListeningModeCoordinator(
    avDevices: [otherAV],
    halCandidates: [
      candidate(name: "Desk AirPods", hal: unselectedHAL, route: .notSelected)
    ],
    logger: logger
  )
  let namedOther = mixedCoordinator.resolve(
    command: .get,
    named: "Travel AirPods",
    chooseAmbiguous: { _ in .unavailable }
  )
  if case .session(let session) = namedOther {
    check(
      session.transport.listeningModeTransportKind == .av,
      "a named AV-only sibling remains reachable when HAL exists"
    )
  } else {
    check(false, "a unique AV-only name remains reachable")
  }

  var chooserCalled = false
  let unnamedMixed = mixedCoordinator.resolve(
    command: .get,
    named: nil,
    chooseAmbiguous: { _ in
      chooserCalled = true
      return .unavailable
    }
  )
  if case .session(let session) = unnamedMixed {
    check(
      session.transport.listeningModeTransportKind == .hal,
      "unnamed selection ignores leftover AV rows when HAL exists"
    )
  } else {
    check(false, "one HAL target remains uniquely selectable")
  }
  check(!chooserCalled, "leftover AV rows never enter the HAL chooser")

  let avOnlyCoordinator = ListeningModeCoordinator(
    avDevices: [pluralAV, otherAV],
    halCandidates: [],
    logger: logger
  )
  let avOnly = avOnlyCoordinator.resolve(
    command: .get,
    named: nil,
    chooseAmbiguous: { _ in .unavailable }
  )
  if case .session(let session) = avOnly {
    check(session.name == "Nearby AirPods", "HAL absence preserves first-AV selection")
  } else {
    check(false, "HAL absence keeps legacy AV-only selection")
  }
}

func testHALListeningModeTranslationAndOffLimitation() {
  let backend = FakeHALRoutingBackend()
  backend.rawModeRead = .value(1)
  backend.supportRead = .value(0b111 | 0x80)
  let transport = HALListeningModeTransport(
    name: "HAL AirPods",
    audioDeviceID: 42,
    bluetoothDevice: NSObject(),
    backend: backend,
    logger: DebugLogger(enabled: false)
  )

  check(transport.currentListeningMode() == .off, "HAL translates raw current Off")
  check(
    transport.availableListeningModes()
      == [.transparency, .adaptive, .noiseCancellation],
    "HAL retains known lsms bits, ignores unknown bits, and omits Off"
  )
  let changed = transport.setListeningModeAndReadBack(.adaptive)
  check(changed.setterAccepted, "HAL accepts a mask-proven non-Off target")
  check(changed.observed == .adaptive, "HAL reads back the requested normalized state")
  check(backend.writtenValues == [4], "HAL writes the exact Adaptive UInt32")

  backend.rawModeRead = .value(1)
  let off = transport.setListeningModeAndReadBack(.off)
  check(!off.setterAccepted, "HAL production transport rejects Off pending discovery")
  check(off.observed == .off, "rejected HAL Off retains the observed current state")
  check(backend.writtenValues == [4], "HAL Off rejection performs no setter")

  backend.rawModeRead = .value(99)
  check(transport.currentListeningMode() == nil, "unknown HAL current raw value fails closed")
  let writeCountBeforeUnknown = backend.writtenValues.count
  let unknownCurrentOutcome = coordinatorOutcome(
    ["lm", "set", "adaptive"],
    candidates: [
      ListeningModeCandidate(
        displayName: "HAL AirPods",
        selectableNames: ["HAL AirPods"],
        avTransport: nil,
        halTransport: transport,
        route: .notSelected
      )
    ]
  )
  check(unknownCurrentOutcome.plain == "unsupported", "unknown HAL state blocks a write")
  check(
    backend.writtenValues.count == writeCountBeforeUnknown,
    "unknown HAL state never reaches the setter"
  )
  backend.supportRead = .failure(-50)
  check(transport.availableListeningModes().isEmpty, "failed HAL support read is unavailable")
}

private func allowOffCacheFixture(
  backend: FakeHALRoutingBackend,
  now: @escaping () -> Date,
  targetID: AudioDeviceID = 42,
  collisionIDs: [AudioDeviceID] = [42]
) -> (
  cache: InMemoryListeningModeAllowOffCache,
  correlation: ListeningModeAllowOffCorrelation,
  transport: HALListeningModeTransport
) {
  let cache = InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xA5, count: 32),
    now: now
  )!
  backend.deviceUIDs[targetID] = .value("uid-\(targetID)")
  let correlation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: targetID,
    collisionAudioDeviceIDs: collisionIDs,
    backend: backend,
    cache: cache,
    logger: DebugLogger(enabled: false),
    now: now
  )
  let transport = HALListeningModeTransport(
    name: "Cached AirPods",
    audioDeviceID: targetID,
    bluetoothDevice: NSObject(),
    backend: backend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  return (cache, correlation, transport)
}

func testListeningModeAllowOffCacheConsumptionAndPrivacyMetadata() {
  var clock = Date(timeIntervalSince1970: 2_000_000_000)
  let backend = FakeHALRoutingBackend()
  backend.rawModeRead = .value(2)
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )

  let listOutcome = coordinatorOutcome(
    ["lm", "list", "--json"],
    candidates: [
      candidate(
        name: "Cached AirPods",
        hal: nil,
        route: .notSelected,
        allowOffCorrelation: fixture.correlation
      )
    ]
  )
  // A correlation without a HAL provider cannot affect selection or output.
  check(listOutcome.plain == "no-device", "cache evidence never creates a device")

  let halCandidate = ListeningModeCandidate(
    displayName: "Cached AirPods",
    selectableNames: ["Cached AirPods"],
    avTransport: nil,
    halTransport: fixture.transport,
    route: .notSelected,
    allowOffCorrelation: fixture.correlation
  )
  let cachedList = coordinatorOutcome(
    ["lm", "list", "--json"],
    candidates: [halCandidate]
  )
  check(
    cachedList.plain == "off,transparency,adaptive,noise-cancellation",
    "a HAL list consumes positive evidence and adds Off"
  )
  let metadata = cachedList.payload["allowOffAvailability"] as? [String: Any]
  check(
    metadata?["source"] as? String == "cached-av-observation",
    "cached HAL output identifies only its safe provenance"
  )
  check(
    metadata?["observedAt"] as? String == "2033-05-18T03:33:20.000Z"
      && metadata?["expiresAt"] as? String == "2033-05-25T03:33:20.000Z",
    "cached HAL output reports the observation and fixed expiry timestamps"
  )
  let serialized = String(
    data: try! JSONSerialization.data(withJSONObject: cachedList.payload),
    encoding: .utf8
  )!
  check(!serialized.contains("uid-42"), "cache JSON never includes the Core Audio UID")
  check(!serialized.contains("a5a5"), "cache JSON never includes cache key material")

  let debugCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 42,
    collisionAudioDeviceIDs: [42],
    backend: backend,
    cache: fixture.cache,
    logger: DebugLogger(enabled: true),
    now: { clock }
  )
  let debugOutput = capturingStandardError {
    _ = debugCorrelation.cachedAuthorization()
  }
  check(
    debugOutput?.contains("debug: allow_off_cache=\"hit\"") == true
      && debugOutput?.contains("debug: allow_off_cache.age_seconds=0") == true,
    "cache debug output is limited to hit and bounded age"
  )
  check(
    debugOutput?.contains("uid-42") == false
      && debugOutput?.contains("a5a5") == false,
    "cache debug output never contains correlation material"
  )

  let uidReadsAfterList = backend.deviceUIDReads.count
  let getOutcome = coordinatorOutcome(["lm", "get"], candidates: [halCandidate])
  check(getOutcome.plain == "noise-cancellation", "HAL get retains current-mode behavior")
  check(
    backend.deviceUIDReads.count == uidReadsAfterList,
    "HAL get never consumes cached Allow Off evidence"
  )
  check(
    getOutcome.payload["allowOffAvailability"] == nil,
    "HAL get has no cache provenance even when current state is Off-capable"
  )

  clock.addTimeInterval(PersistentListeningModeAllowOffCache.defaultTTL)
  let expired = coordinatorOutcome(["lm", "list"], candidates: [halCandidate])
  check(
    expired.plain == "transparency,adaptive,noise-cancellation",
    "evidence expires after a non-sliding seven-day TTL"
  )
}

func testListeningModeAllowOffCacheAuthorizesExplicitHALWritesOnly() {
  let clock = Date(timeIntervalSince1970: 2_000_000_100)
  let backend = FakeHALRoutingBackend()
  backend.rawModeRead = .value(2)
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )
  let halCandidate = ListeningModeCandidate(
    displayName: "Cached AirPods",
    selectableNames: ["Cached AirPods"],
    avTransport: nil,
    halTransport: fixture.transport,
    route: .notSelected,
    allowOffCorrelation: fixture.correlation
  )

  let setOff = coordinatorOutcome(["lm", "set", "off", "--json"], candidates: [halCandidate])
  check(setOff.plain == "ok", "cached AV evidence authorizes an explicit HAL Off write")
  check(backend.writtenValues == [1], "cache-authorized Off writes exact raw mode one")
  check(setOff.payload["listeningMode"] as? String == "off", "HAL reads Off back")
  check(
    setOff.payload["allowOffAvailability"] != nil,
    "cache-authorized Off write includes additive provenance"
  )

  backend.rawModeRead = .value(2)
  backend.resetWrites()
  let defaultCycle = coordinatorOutcome(["lm", "cycle"], candidates: [halCandidate])
  check(defaultCycle.plain == "transparency", "default cycle remains non-Off")
  check(backend.writtenValues == [3], "default cycle never targets cached Off")

  backend.rawModeRead = .value(2)
  backend.resetWrites()
  let explicitCycle = coordinatorOutcome(
    ["lm", "cycle", "--modes", "off,noise-cancellation"],
    candidates: [halCandidate]
  )
  check(explicitCycle.plain == "off", "an explicit Off cycle consumes the cache")
  check(backend.writtenValues == [1], "explicit Off cycle writes raw mode one")
}

func testListeningModeWritePlanOwnsHALAllowOffPolicy() {
  let clock = Date(timeIntervalSince1970: 2_000_000_150)
  let backend = FakeHALRoutingBackend()
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )
  let hal = FakeListeningModeTransport(
    name: "Planned AirPods",
    kind: .hal,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .noiseCancellation
  )
  let halCandidate = candidate(
    name: "Planned AirPods",
    hal: hal,
    route: .notSelected,
    allowOffCorrelation: fixture.correlation
  )

  let accepted = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [halCandidate]
  )
  check(accepted.plain == "ok", "the write plan authorizes HAL Off")
  check(
    hal.allowOffWrites == [true],
    "HAL authorization reaches a non-concrete transport without an executor cast"
  )

  hal.current = .noiseCancellation
  hal.appliesWrites = false
  hal.dropsWriteReadback = true
  let unknownReadback = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [halCandidate]
  )
  check(unknownReadback.plain == "no-op", "authorized HAL Off needs a verified readback")
  check(
    unknownReadback.payload["listeningMode"] is NSNull,
    "authorized HAL Off never invents a Transparency fallback"
  )

  let av = FakeListeningModeTransport(
    name: "Planned AirPods",
    kind: .av,
    current: .noiseCancellation
  )
  let avOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [candidate(name: "Planned AirPods", av: av, route: .selected)]
  )
  check(avOutcome.plain == "ok", "live AV Off remains writable")
  check(av.allowOffWrites == [false], "AV writes do not consume HAL authorization")

  let ordinaryHAL = OrdinaryHALListeningModeTransport(
    wrapped: FakeListeningModeTransport(
      name: "Ordinary HAL AirPods",
      kind: .hal,
      modes: [.off],
      current: .noiseCancellation
    )
  )
  let ordinaryPlan = ListeningModeWritePlan(
    transport: ordinaryHAL,
    availableModes: [.off],
    allowOffAuthorization: .live(cache: nil, record: nil)
  )
  check(
    !ordinaryPlan.canWrite(.off),
    "a HAL write plan requires the explicit Allow Off capability"
  )
}

func testListeningModeAllowOffHALMismatchEvictsOnlyAcceptedEvidence() {
  let clock = Date(timeIntervalSince1970: 2_000_000_200)
  let backend = FakeHALRoutingBackend()
  backend.rawModeRead = .value(2)
  backend.appliesWrite = false
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )
  let halCandidate = ListeningModeCandidate(
    displayName: "Cached AirPods",
    selectableNames: ["Cached AirPods"],
    avTransport: nil,
    halTransport: fixture.transport,
    route: .notSelected,
    allowOffCorrelation: fixture.correlation
  )

  let mismatch = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [halCandidate]
  )
  check(mismatch.plain == "no-op", "definitive non-Off HAL readback is a no-op")
  check(mismatch.exitCode == 3, "definitive HAL mismatch exits three")
  check(
    mismatch.payload["listeningMode"] as? String == "noise-cancellation",
    "cache-authorized mismatch reports the actual final mode"
  )
  check(
    mismatch.payload["allowOffAvailability"] != nil,
    "mismatch reports the cached evidence consumed by that invocation"
  )
  if case .miss = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "accepted definitive mismatch evicts the positive evidence")
  } else {
    check(false, "accepted definitive mismatch evicts the positive evidence")
  }

  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )
  backend.writeResult = .notSettable
  let rejected = coordinatorOutcome(["lm", "set", "off"], candidates: [halCandidate])
  check(rejected.plain == "no-op", "a provider rejection remains a no-op")
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "setter rejection leaves positive evidence unchanged")
  } else {
    check(false, "setter rejection leaves positive evidence unchanged")
  }

  let av = FakeListeningModeTransport(
    name: "Cached AirPods",
    kind: .av,
    current: .noiseCancellation,
    appliesWrites: false
  )
  let avMismatch = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [
      candidate(
        name: "Cached AirPods",
        av: av,
        route: .selected,
        allowOffCorrelation: fixture.correlation
      )
    ]
  )
  check(avMismatch.plain == "no-op", "a definitive non-Off AV readback is a no-op")
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "an AV mismatch preserves its fresh availability evidence")
  } else {
    check(false, "an AV mismatch preserves its fresh availability evidence")
  }
}

func testListeningModeAllowOffAVEvidenceLifecycleAndSilentAmbiguity() {
  var clock = Date(timeIntervalSince1970: 2_000_000_300)
  let backend = FakeHALRoutingBackend()
  backend.rawModeRead = .value(2)
  let fixture = allowOffCacheFixture(backend: backend, now: { clock })
  let firstObservationTime = clock
  backend.onDeviceUIDRead = { clock.addTimeInterval(1) }
  let av = FakeListeningModeTransport(
    name: "Cached AirPods",
    kind: .av,
    modes: ListeningMode.allCases,
    current: .transparency
  )
  let joined = candidate(
    name: "Cached AirPods",
    av: av,
    route: .selected,
    allowOffCorrelation: fixture.correlation
  )
  _ = coordinatorOutcome(["lm", "list"], candidates: [joined])
  backend.onDeviceUIDRead = nil
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "successful AV availability with Off refreshes positive evidence")
    if case .hit(let record) = fixture.cache.lookup(rawDeviceUID: "uid-42") {
      check(
        record.evidence.observedAt == firstObservationTime,
        "AV observation time is captured before UID correlation"
      )
    }
  } else {
    check(false, "successful AV availability with Off refreshes positive evidence")
  }

  av.modes = [.transparency, .adaptive, .noiseCancellation]
  _ = coordinatorOutcome(["lm", "list"], candidates: [joined])
  if case .miss = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "successful AV availability without Off deletes evidence")
  } else {
    check(false, "successful AV availability without Off deletes evidence")
  }

  clock.addTimeInterval(1)
  av.current = .off
  let readsBeforeGet = av.readModesCount
  _ = coordinatorOutcome(["lm", "get"], candidates: [joined])
  check(av.readModesCount == readsBeforeGet, "AV get does not add an availability read")
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "a live AV get that returns Off refreshes positive evidence")
  } else {
    check(false, "a live AV get that returns Off refreshes positive evidence")
  }

  av.availabilityObservation = .unavailable
  _ = coordinatorOutcome(["lm", "list"], candidates: [joined])
  if case .hit = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "AV selector/read failure leaves evidence unchanged")
  } else {
    check(false, "AV selector/read failure leaves evidence unchanged")
  }

  _ = fixture.cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: false,
    observedAt: clock
  )
  av.availabilityObservation = nil
  av.current = .off
  _ = coordinatorOutcome(["lm", "set", "adaptive"], candidates: [joined])
  if case .miss = fixture.cache.lookup(rawDeviceUID: "uid-42") {
    check(true, "a non-Off operation does not warm evidence from incidental reads")
  } else {
    check(false, "a non-Off operation does not warm evidence from incidental reads")
  }

  let ambiguousBackend = FakeHALRoutingBackend()
  ambiguousBackend.rawModeRead = .value(2)
  ambiguousBackend.deviceUIDs[42] = .value("same-uid")
  ambiguousBackend.deviceUIDs[43] = .value("same-uid")
  let ambiguousCache = InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xB6, count: 32),
    now: { clock }
  )!
  _ = ambiguousCache.applyObservation(
    rawDeviceUID: "same-uid",
    allowsOff: true,
    observedAt: clock
  )
  let ambiguousCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 42,
    collisionAudioDeviceIDs: [42, 43],
    backend: ambiguousBackend,
    cache: ambiguousCache,
    logger: DebugLogger(enabled: false),
    now: { clock }
  )
  let ambiguousTransport = HALListeningModeTransport(
    name: "Ambiguous AirPods",
    audioDeviceID: 42,
    bluetoothDevice: NSObject(),
    backend: ambiguousBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let ambiguousOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Ambiguous AirPods",
        selectableNames: ["Ambiguous AirPods"],
        avTransport: nil,
        halTransport: ambiguousTransport,
        route: .notSelected,
        allowOffCorrelation: ambiguousCorrelation
      )
    ]
  )
  check(ambiguousOutcome.plain == "unsupported", "ambiguous UID correlation is a silent miss")
  check(
    ambiguousBackend.writtenValues.isEmpty,
    "ambiguous cache correlation never authorizes a write"
  )

  let liveBackend = FakeHALRoutingBackend()
  liveBackend.rawModeRead = .value(2)
  let liveHAL = HALListeningModeTransport(
    name: "Live Evidence AirPods",
    audioDeviceID: 52,
    bluetoothDevice: NSObject(),
    backend: liveBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let incompleteLiveAV = FakeListeningModeTransport(
    name: "Live Evidence AirPods",
    kind: .av,
    modes: ListeningMode.allCases,
    current: .noiseCancellation,
    settable: false
  )
  let liveFallback = coordinatorOutcome(
    ["lm", "set", "off", "--json"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Live Evidence AirPods",
        selectableNames: ["Live Evidence AirPods"],
        avTransport: incompleteLiveAV,
        halTransport: liveHAL,
        route: .unknown
      )
    ]
  )
  check(liveFallback.plain == "ok", "fresh AV Off evidence authorizes same-command HAL fallback")
  check(liveBackend.writtenValues == [1], "fresh evidence does not require cache persistence")
  check(
    liveFallback.payload["allowOffAvailability"] == nil,
    "fresh live evidence is never mislabeled as cached provenance"
  )

  let staleBackend = FakeHALRoutingBackend()
  staleBackend.rawModeRead = .value(2)
  staleBackend.deviceUIDs[62] = .value("uid-62")
  let wrappedCache = InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xD8, count: 32),
    now: { clock }
  )!
  _ = wrappedCache.applyObservation(
    rawDeviceUID: "uid-62",
    allowsOff: true,
    observedAt: clock
  )
  let failingRemovalCache = FailingRemovalAllowOffCache(wrapped: wrappedCache)
  let staleCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 62,
    collisionAudioDeviceIDs: [62],
    backend: staleBackend,
    cache: failingRemovalCache,
    logger: DebugLogger(enabled: false),
    now: { clock }
  )
  let staleHAL = HALListeningModeTransport(
    name: "Fresh Negative AirPods",
    audioDeviceID: 62,
    bluetoothDevice: NSObject(),
    backend: staleBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let negativeAV = FakeListeningModeTransport(
    name: "Fresh Negative AirPods",
    kind: .av,
    modes: [.transparency, .adaptive, .noiseCancellation],
    current: .noiseCancellation
  )
  let freshNegative = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Fresh Negative AirPods",
        selectableNames: ["Fresh Negative AirPods"],
        avTransport: negativeAV,
        halTransport: staleHAL,
        route: .unknown,
        allowOffCorrelation: staleCorrelation
      )
    ]
  )
  check(
    freshNegative.plain == "unsupported",
    "fresh AV negative evidence suppresses a stale cache hit even if deletion fails"
  )
  check(
    staleBackend.writtenValues.isEmpty,
    "failed negative-evidence persistence never reauthorizes HAL Off in the same command"
  )

  let stalePositiveBackend = FakeHALRoutingBackend()
  stalePositiveBackend.rawModeRead = .value(2)
  stalePositiveBackend.deviceUIDs[72] = .value("uid-72")
  let stalePositiveCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 72,
    collisionAudioDeviceIDs: [72],
    backend: stalePositiveBackend,
    cache: StalePositiveAllowOffCache(),
    logger: DebugLogger(enabled: false),
    now: { clock }
  )
  let stalePositiveAV = FakeListeningModeTransport(
    name: "Stale Positive AirPods",
    kind: .av,
    modes: ListeningMode.allCases,
    current: .noiseCancellation,
    settable: false
  )
  let stalePositiveHAL = HALListeningModeTransport(
    name: "Stale Positive AirPods",
    audioDeviceID: 72,
    bluetoothDevice: NSObject(),
    backend: stalePositiveBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let stalePositiveOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Stale Positive AirPods",
        selectableNames: ["Stale Positive AirPods"],
        avTransport: stalePositiveAV,
        halTransport: stalePositiveHAL,
        route: .unknown,
        allowOffCorrelation: stalePositiveCorrelation
      )
    ]
  )
  check(
    stalePositiveOutcome.plain == "unsupported",
    "a stale positive AV observation cannot authorize HAL Off"
  )
  check(
    stalePositiveBackend.writtenValues.isEmpty,
    "a rejected stale positive observation never reaches the HAL setter"
  )
}

func testListeningModeCoordinatorOrdersDelayedAVObservations() {
  let cache = InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xE1, count: 32)
  )!
  let oldReadStarted = DispatchSemaphore(value: 0)
  let releaseOldRead = DispatchSemaphore(value: 0)

  let oldBackend = FakeHALRoutingBackend()
  oldBackend.deviceUIDs[80] = .value("uid-80")
  let oldCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 80,
    collisionAudioDeviceIDs: [80],
    backend: oldBackend,
    cache: cache,
    logger: DebugLogger(enabled: false),
    now: { Date(timeIntervalSince1970: 2_000_000_400) }
  )
  let oldAV = FakeListeningModeTransport(
    name: "Delayed AirPods",
    kind: .av,
    modes: ListeningMode.allCases
  )
  oldAV.onAvailabilityRead = {
    oldReadStarted.signal()
    _ = releaseOldRead.wait(timeout: .now() + 2)
  }
  let oldWork = DispatchWorkItem {
    _ = coordinatorOutcome(
      ["lm", "list"],
      candidates: [
        candidate(
          name: "Delayed AirPods",
          av: oldAV,
          route: .selected,
          allowOffCorrelation: oldCorrelation
        )
      ]
    )
  }
  DispatchQueue.global().async(execute: oldWork)
  let oldStarted = oldReadStarted.wait(timeout: .now() + 2) == .success
  check(oldStarted, "the older AV read reaches its controlled pause")

  let newBackend = FakeHALRoutingBackend()
  newBackend.deviceUIDs[80] = .value("uid-80")
  let newCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 80,
    collisionAudioDeviceIDs: [80],
    backend: newBackend,
    cache: cache,
    logger: DebugLogger(enabled: false),
    now: { Date(timeIntervalSince1970: 2_000_000_500) }
  )
  let newAV = FakeListeningModeTransport(
    name: "Delayed AirPods",
    kind: .av,
    modes: [.transparency, .adaptive, .noiseCancellation]
  )
  let newOutcome = coordinatorOutcome(
    ["lm", "list"],
    candidates: [
      candidate(
        name: "Delayed AirPods",
        av: newAV,
        route: .selected,
        allowOffCorrelation: newCorrelation
      )
    ]
  )
  check(
    newOutcome.plain == "transparency,adaptive,noise-cancellation",
    "the newer negative AV observation completes while the older read is paused"
  )

  releaseOldRead.signal()
  check(
    oldWork.wait(timeout: .now() + 2) == .success,
    "the older AV observation completes after the newer one"
  )
  if case .miss = cache.lookup(rawDeviceUID: "uid-80") {
    check(true, "an older positive AV observation cannot replace a newer tombstone")
  } else {
    check(false, "an older positive AV observation cannot replace a newer tombstone")
  }

  let halBackend = FakeHALRoutingBackend()
  halBackend.rawModeRead = .value(2)
  halBackend.deviceUIDs[80] = .value("uid-80")
  let halCorrelation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 80,
    collisionAudioDeviceIDs: [80],
    backend: halBackend,
    cache: cache,
    logger: DebugLogger(enabled: false),
    now: { Date(timeIntervalSince1970: 2_000_000_500) }
  )
  let hal = HALListeningModeTransport(
    name: "Delayed AirPods",
    audioDeviceID: 80,
    bluetoothDevice: NSObject(),
    backend: halBackend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  let offOutcome = coordinatorOutcome(
    ["lm", "set", "off"],
    candidates: [
      ListeningModeCandidate(
        displayName: "Delayed AirPods",
        selectableNames: ["Delayed AirPods"],
        avTransport: nil,
        halTransport: hal,
        route: .notSelected,
        allowOffCorrelation: halCorrelation
      )
    ]
  )
  check(
    offOutcome.plain == "unsupported" && halBackend.writtenValues.isEmpty,
    "the newer negative tombstone blocks a later HAL Off write"
  )
}

func runListeningModeCoordinatorTests() {
  testListeningModeCoordinatorRouteAndPreflightSelection()
  testListeningModeCoordinatorPreservesAVUnknownStateWrites()
  testListeningModeCoordinatorReadsOnlyCommandRequirements()
  testListeningModeCoordinatorNeverFallsBackAfterASetter()
  testListeningModeCoordinatorAmbiguityAndCancellation()
  testListeningModeCoordinatorPrefersSelectedAVOverSoleInactiveHAL()
  testListeningModeCoordinatorKeepsHALIdentitySeparateFromAVNames()
  testHALListeningModeTranslationAndOffLimitation()
  testListeningModeAllowOffCacheConsumptionAndPrivacyMetadata()
  testListeningModeAllowOffCacheAuthorizesExplicitHALWritesOnly()
  testListeningModeWritePlanOwnsHALAllowOffPolicy()
  testListeningModeAllowOffHALMismatchEvictsOnlyAcceptedEvidence()
  testListeningModeAllowOffAVEvidenceLifecycleAndSilentAmbiguity()
  testListeningModeCoordinatorOrdersDelayedAVObservations()
}
