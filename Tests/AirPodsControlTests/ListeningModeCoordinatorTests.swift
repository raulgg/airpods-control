import Foundation

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
  testListeningModeAllowOffAVEvidenceLifecycle()
  testListeningModeAllowOffAmbiguousCorrelation()
  testListeningModeAllowOffLiveFallback()
  testListeningModeAllowOffFreshNegativeEvidence()
  testListeningModeAllowOffStalePositiveAuthorization()
  testInMemoryAllowOffCachePreservesObservationOrdering()
  testListeningModeCoordinatorOrdersDelayedAVObservations()
}
