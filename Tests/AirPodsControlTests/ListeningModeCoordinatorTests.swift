import CoreAudio
import Foundation

private final class FakeListeningModeTransport: ListeningModeTransport {
  let name: String?
  let listeningModeTransportKind: ListeningModeTransportKind
  var modes: [ListeningMode]
  var current: ListeningMode?
  var settable: Bool
  var appliesWrites: Bool
  private(set) var readModesCount = 0
  private(set) var readCurrentCount = 0
  private(set) var canSetCount = 0
  private(set) var setterTargets: [ListeningMode] = []

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
    setterTargets.append(target)
    if appliesWrites { current = target }
    return DeviceWriteObservation(setterAccepted: settable, observed: current)
  }

  func settle(for interval: TimeInterval) {}
}

private final class FakeHALRoutingBackend: AudioRoutingBackend {
  var rawModeRead: AudioRoutingRead<UInt32> = .value(3)
  var supportRead: AudioRoutingRead<UInt32> = .value(0b111)
  var settableRead: AudioRoutingRead<Bool> = .value(true)
  var writeResult: AudioRoutingWrite = .success
  var appliesWrite = true
  private(set) var writtenValues: [UInt32] = []

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
  func readIsAppleAudioDevice(_ deviceID: AudioDeviceID) -> AudioRoutingRead<Bool> {
    .unavailable
  }
  func readBluetoothListeningMode(
    for deviceID: AudioDeviceID
  ) -> AudioRoutingRead<UInt32> { rawModeRead }
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
  return CommandExecution.execute(
    invocation,
    resolveDeviceResolution: { name, _, _ in
      coordinator.resolve(
        command: invocation.command,
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
  activeAV: Bool = false
) -> ListeningModeCandidate {
  ListeningModeCandidate(
    displayName: name,
    selectableNames: [name],
    avTransport: av,
    halTransport: hal,
    route: route,
    avIdentifiesActiveOutput: activeAV
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
        route: .unknown,
        activeAV: true
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

func testListeningModeCandidateMergeAvoidsPluralAVDuplicates() {
  let logger = DebugLogger(enabled: false)
  let pluralRaw = FakeRawDevice(name: "Desk AirPods", deviceIdentifier: "same-device")
  let pluralAV = PrivateAudioDevice.compatible(
    object: pluralRaw,
    sources: [.contextPlural],
    index: 0,
    logger: logger
  )!
  let hal = FakeListeningModeTransport(name: "Desk AirPods", kind: .hal)
  let halCandidate = candidate(name: "Desk AirPods", hal: hal, route: .notSelected)
  let merged = ListeningModeCoordinator.candidates(
    avDevices: [pluralAV],
    halCandidates: [halCandidate]
  )
  check(merged.count == 2, "unjoined AV inventory is never name-merged into HAL")
  let unresolvedDuplicate = coordinatorOutcome(
    ["--device", "Desk AirPods", "lm", "get"],
    candidates: merged
  )
  check(
    unresolvedDuplicate.plain == "ambiguous-device",
    "an unproven AV/HAL correlation fails closed instead of choosing by name"
  )

  let joinedRaw = FakeRawDevice(name: "Desk AirPods", deviceIdentifier: "joined-device")
  let joinedAV = PrivateAudioDevice.compatible(
    object: joinedRaw,
    sources: [.contextSingular],
    index: 0,
    logger: logger
  )!
  let proxyRaw = FakeRawDevice(name: "Desk AirPods", deviceIdentifier: "joined-device")
  let proxyAV = PrivateAudioDevice.compatible(
    object: proxyRaw,
    sources: [.contextSingular],
    index: 1,
    logger: logger
  )!
  let joinedCandidate = ListeningModeCandidate(
    displayName: "Desk AirPods",
    selectableNames: ["Desk AirPods"],
    avTransport: joinedAV,
    halTransport: hal,
    route: .selected,
    avIdentifiesActiveOutput: true
  )
  let deduplicated = ListeningModeCoordinator.candidates(
    avDevices: [proxyAV],
    halCandidates: [joinedCandidate]
  )
  check(
    deduplicated.count == 1,
    "distinct AV wrappers with the same ephemeral endpoint identifier deduplicate"
  )

  let otherRaw = FakeRawDevice(name: "Travel AirPods")
  let otherAV = PrivateAudioDevice.compatible(
    object: otherRaw,
    sources: [.contextPlural],
    index: 2,
    logger: logger
  )!
  let avOnly = ListeningModeCoordinator.candidates(
    avDevices: [pluralAV, otherAV],
    halCandidates: []
  )
  check(avOnly.count == 2, "HAL absence preserves the complete legacy AV inventory")
  let avOnlyOutcome = coordinatorOutcome(["lm", "get"], candidates: avOnly)
  check(
    avOnlyOutcome.payload["device"] as? String == "Desk AirPods",
    "HAL absence preserves legacy first-AV selection"
  )

  let mixed = ListeningModeCoordinator.candidates(
    avDevices: [otherAV],
    halCandidates: [halCandidate]
  )
  let namedOther = coordinatorOutcome(
    ["--device", "Travel AirPods", "lm", "get"],
    candidates: mixed
  )
  check(
    namedOther.payload["device"] as? String == "Travel AirPods",
    "an unrelated HAL candidate does not hide a named AV-only device"
  )
  var mixedChooserCalled = false
  let mixedCoordinator = ListeningModeCoordinator(
    candidates: mixed,
    logger: DebugLogger(enabled: false)
  )
  let mixedInvocation = try! parseInvocation(["lm", "get"])
  let mixedResolution = mixedCoordinator.resolve(
    command: mixedInvocation.command,
    named: nil,
    chooseAmbiguous: { _ in
      mixedChooserCalled = true
      return .selected(index: 0)
    }
  )
  if case .ambiguousDevice = mixedResolution {
    check(true, "mixed AV/HAL ambiguity fails closed")
  } else {
    check(false, "mixed AV/HAL ambiguity must not select a device")
  }
  check(!mixedChooserCalled, "mixed AV/HAL ambiguity never opens the HAL chooser")
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

func runListeningModeCoordinatorTests() {
  testListeningModeCoordinatorRouteAndPreflightSelection()
  testListeningModeCoordinatorPreservesAVUnknownStateWrites()
  testListeningModeCoordinatorReadsOnlyCommandRequirements()
  testListeningModeCoordinatorNeverFallsBackAfterASetter()
  testListeningModeCoordinatorAmbiguityAndCancellation()
  testListeningModeCandidateMergeAvoidsPluralAVDuplicates()
  testHALListeningModeTranslationAndOffLimitation()
}
