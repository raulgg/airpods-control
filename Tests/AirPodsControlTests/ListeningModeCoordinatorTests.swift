import CoreAudio
import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Listening mode coordinator")
struct ListeningModeCoordinatorTests {

  @Test("Preserves HAL discovery failures while allowing usable AV fallback")
  func listeningModeCoordinatorPreservesHALDiscoveryFailures() throws {
    let unavailableCases: [([String], TerminalReason)] = [
      (["lm", "get"], .unavailable),
      (["lm", "list"], .unavailable),
      (["lm", "set", "adaptive"], .unavailable),
      (["lm", "cycle"], .unavailable),
    ]
    for (arguments, expectedReason) in unavailableCases {
      let outcome = try coordinatorOutcome(
        arguments,
        candidates: [],
        halDiscovery: .unavailable
      )
      #expect(
        outcome.terminalReason == expectedReason,
        "\(arguments) preserves HAL unavailability"
      )
      #expect(
        outcome.plain == expectedReason.token,
        "\(arguments) reports HAL unavailability plainly"
      )
    }

    let readOnlyCases: [([String], TerminalReason)] = [
      (["lm", "get"], .readError),
      (["lm", "list"], .readError),
      (["lm", "set", "adaptive"], .unavailable),
      (["lm", "cycle"], .unavailable),
    ]
    for (arguments, expectedReason) in readOnlyCases {
      let outcome = try coordinatorOutcome(
        arguments,
        candidates: [],
        halDiscovery: .readError
      )
      #expect(
        outcome.terminalReason == expectedReason,
        "\(arguments) maps HAL discovery read errors to \(expectedReason.token)"
      )
    }

    let successfulEmptyDiscovery = try coordinatorOutcome(
      ["lm", "get"],
      candidates: [],
      halDiscovery: .available
    )
    #expect(
      successfulEmptyDiscovery.terminalReason == .noDevice,
      "an empty successful HAL inventory remains no-device"
    )

    let fallbackAV = FakeListeningModeTransport(
      name: "AV fallback AirPods",
      kind: .av,
      current: .transparency
    )
    let fallbackOutcome = try coordinatorOutcome(
      ["lm", "get"],
      candidates: [candidate(av: fallbackAV, route: .unknown)],
      halDiscovery: .readError
    )
    #expect(
      fallbackOutcome.terminalReason == .success,
      "HAL discovery errors do not hide a usable AV fallback"
    )

    let namedAV = FakeListeningModeTransport(
      name: "Named AV AirPods",
      kind: .av,
      current: .transparency
    )
    let namedOutcome = try coordinatorOutcome(
      ["--device", "named av airpods", "lm", "get"],
      candidates: [candidate(name: "Named AV AirPods", av: namedAV, route: .unknown)],
      halDiscovery: .unavailable
    )
    #expect(
      namedOutcome.terminalReason == .success,
      "an exact AV match survives HAL discovery failure"
    )

    let namedMiss = try coordinatorOutcome(
      ["--device", "Missing AirPods", "lm", "get"],
      candidates: [candidate(name: "Named AV AirPods", av: namedAV, route: .unknown)],
      halDiscovery: .readError
    )
    #expect(
      namedMiss.terminalReason == .readError,
      "a named miss retains the HAL read error when no AV name matches"
    )

    let firstAV = FakeListeningModeTransport(name: "First AV AirPods", kind: .av)
    let secondAV = FakeListeningModeTransport(name: "Second AV AirPods", kind: .av)
    let ambiguousAV = try coordinatorOutcome(
      ["lm", "get", "--json"],
      candidates: [
        candidate(name: "First AV AirPods", av: firstAV, route: .unknown),
        candidate(name: "Second AV AirPods", av: secondAV, route: .unknown),
      ],
      halDiscovery: .unavailable
    )
    #expect(
      ambiguousAV.terminalReason == .ambiguousDevice,
      "multiple AV candidates remain ambiguous when HAL discovery fails"
    )

    let unavailableAV = FakeListeningModeTransport(
      name: "Unavailable AV AirPods",
      kind: .av,
      current: .transparency
    )
    unavailableAV.availabilityObservation = .readError
    let avReadError = try coordinatorOutcome(
      ["lm", "list"],
      candidates: [candidate(av: unavailableAV, route: .unknown)],
      halDiscovery: .readError
    )
    #expect(
      avReadError.terminalReason == .readError,
      "a resolved AV read error is not replaced by the HAL discovery error"
    )
  }

  @Test
  func listeningModeCoordinatorRouteAndPreflightSelection() throws {
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
    let selectedOutcome = try coordinatorOutcome(
      ["lm", "set", "adaptive"],
      candidates: [candidate(av: selectedAV, hal: selectedHAL, route: .selected)]
    )
    #expect(selectedOutcome.plain == "ok", "selected output uses its ready AV transport")
    #expect(selectedAV.setterTargets == [.adaptive], "selected AV receives the setter")
    #expect(selectedHAL.setterTargets.isEmpty, "selected HAL remains untouched")
    #expect(
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
    _ = try coordinatorOutcome(
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
    #expect(unselectedAV.readCurrentCount == 0, "proven unselected route does not preflight AV")
    #expect(unselectedAV.setterTargets.isEmpty, "proven unselected route never writes through AV")
    #expect(unselectedHAL.setterTargets == [.adaptive], "proven unselected route writes through HAL")

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
    let fallbackOutcome = try coordinatorOutcome(
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
    #expect(fallbackOutcome.plain == "ok", "unknown route falls back after AV preflight")
    #expect(incompleteAV.setterTargets.isEmpty, "failed AV preflight performs no setter")
    #expect(fallbackHAL.setterTargets == [.adaptive], "HAL handles the preflight fallback")
  }

  @Test
  func listeningModeCoordinatorPreservesAVUnknownStateWrites() throws {
    let setAV = FakeListeningModeTransport(
      name: "Unknown AV AirPods",
      kind: .av,
      current: nil
    )
    let setOutcome = try coordinatorOutcome(
      ["lm", "set", "adaptive"],
      candidates: [candidate(av: setAV, route: .unknown)]
    )
    #expect(setOutcome.plain == "ok", "AV set preserves its unknown-current behavior")
    #expect(setAV.setterTargets == [.adaptive], "AV set with unknown current writes once")

    let cycleAV = FakeListeningModeTransport(
      name: "Unknown Cycle AirPods",
      kind: .av,
      current: nil
    )
    let cycleOutcome = try coordinatorOutcome(
      ["lm", "cycle"],
      candidates: [candidate(av: cycleAV, route: .unknown)]
    )
    #expect(
      cycleOutcome.plain == "transparency",
      "AV cycle with unknown current starts at the first default mode"
    )
    #expect(cycleAV.setterTargets == [.transparency], "unknown AV cycle writes its first target")
  }

  @Test
  func listeningModeCoordinatorReadsOnlyCommandRequirements() throws {
    let getTransport = FakeListeningModeTransport(
      name: "Get AirPods",
      kind: .hal,
      current: .adaptive
    )
    let getOutcome = try coordinatorOutcome(
      ["lm", "get"],
      candidates: [candidate(name: "Get AirPods", hal: getTransport, route: .notSelected)]
    )
    #expect(getOutcome.plain == "adaptive", "get reads the current provider state")
    #expect(getTransport.readCurrentCount == 1, "get reads current exactly once")
    #expect(getTransport.readModesCount == 0, "get does not read mode inventory")
    #expect(getTransport.canSetCount == 0, "get does not inspect setter writability")

    let listTransport = FakeListeningModeTransport(
      name: "List AirPods",
      kind: .hal,
      modes: [.transparency, .adaptive],
      current: .transparency
    )
    let listOutcome = try coordinatorOutcome(
      ["lm", "list"],
      candidates: [candidate(name: "List AirPods", hal: listTransport, route: .notSelected)]
    )
    #expect(listOutcome.plain == "transparency,adaptive", "list reads current inventory")
    #expect(listTransport.readCurrentCount == 1, "list reads current exactly once")
    #expect(listTransport.readModesCount == 1, "list reads inventory exactly once")
    #expect(listTransport.canSetCount == 0, "list does not inspect setter writability")
  }

  @Test
  func listeningModeCoordinatorNeverFallsBackAfterASetter() throws {
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
    let outcome = try coordinatorOutcome(
      ["lm", "set", "adaptive"],
      candidates: [candidate(name: "Sticky AirPods", av: av, hal: hal, route: .selected)]
    )
    #expect(outcome.plain == "no-op", "nonmatching selected-provider readback is a no-op")
    #expect(av.setterTargets == [.adaptive], "selected provider performs exactly one setter")
    #expect(hal.setterTargets.isEmpty, "a post-setter failure never falls through to HAL")
  }

  @Test
  func listeningModeCoordinatorAmbiguityAndDecline() throws {
    let first = FakeListeningModeTransport(name: "Desk AirPods", kind: .hal)
    let second = FakeListeningModeTransport(name: "Travel AirPods", kind: .hal)
    let candidates = [
      candidate(name: "Desk AirPods", hal: first, route: .notSelected),
      candidate(name: "Travel AirPods", hal: second, route: .notSelected),
    ]

    let ambiguous = try coordinatorOutcome(["lm", "get", "--json"], candidates: candidates)
    #expect(ambiguous.plain == "ambiguous-device", "noninteractive ambiguity is specific")
    #expect(ambiguous.exitCode == 8, "ambiguous device exits eight")
    #expect(
      ambiguous.payload["error"] as? String == "ambiguous-device",
      "ambiguous JSON has its specific error"
    )
    #expect(ambiguous.payload["listeningMode"] is NSNull, "ambiguous state is JSON null")

    let chosen = try coordinatorOutcome(
      ["lm", "get"],
      candidates: candidates,
      choice: .selected(index: 1)
    )
    #expect(chosen.payload["device"] as? String == "Travel AirPods", "chooser index selects target")

    let declined = try coordinatorOutcome(
      ["lm", "get"],
      candidates: candidates,
      choice: .unavailable
    )
    #expect(declined.plain == "ambiguous-device", "declining keeps ambiguity explicit")

    let duplicateNameCandidates = [
      candidate(name: "Same AirPods", hal: first, route: .notSelected),
      candidate(name: "Same AirPods", hal: second, route: .notSelected),
    ]
    let duplicate = try coordinatorOutcome(
      ["--device", "same airpods", "lm", "get"],
      candidates: duplicateNameCandidates,
      choice: .selected(index: 0)
    )
    #expect(duplicate.plain == "ambiguous-device", "duplicate exact names never prompt or select")
  }

  @Test
  func listeningModeCoordinatorTreatsSelectedAndInactiveAsAmbiguous() throws {
    let selectedAV = FakeListeningModeTransport(name: "Selected AirPods", kind: .av)
    let inactiveHAL = FakeListeningModeTransport(name: "Inactive AirPods", kind: .hal)
    let candidates = [
      candidate(name: "Selected AirPods", av: selectedAV, route: .selected),
      candidate(name: "Inactive AirPods", hal: inactiveHAL, route: .notSelected),
    ]

    let outcome = try coordinatorOutcome(
      ["lm", "set", "adaptive"],
      candidates: candidates
    )

    #expect(outcome.plain == "ambiguous-device", "route selection does not hide another target")
    #expect(selectedAV.setterTargets.isEmpty, "ambiguous selected AV target is not written")
    #expect(inactiveHAL.setterTargets.isEmpty, "the inactive HAL target remains untouched")

    let otherSelectedAV = FakeListeningModeTransport(name: "Other AirPods", kind: .av)
    let ambiguousOutcome = try coordinatorOutcome(
      ["lm", "set", "adaptive"],
      candidates: candidates + [
        candidate(name: "Other AirPods", av: otherSelectedAV, route: .selected)
      ]
    )

    #expect(ambiguousOutcome.plain == "ambiguous-device", "multiple selected AV targets fail closed")
    #expect(selectedAV.setterTargets.isEmpty, "ambiguous resolution does not write")
    #expect(otherSelectedAV.setterTargets.isEmpty, "an ambiguous selected AV target is not written")
    #expect(inactiveHAL.setterTargets.isEmpty, "ambiguous resolution does not write the HAL target")
  }

  @Test
  func listeningModeCoordinatorKeepsHALIdentitySeparateFromAVNames() throws {
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
      #expect(
        session.transport.listeningModeTransportKind == .av,
        "a unique selected HAL target pairs with the unique active AV endpoint"
      )
    } else {
      Issue.record("a unique selected pair must resolve without ambiguity")
    }
    let namedSelected = selectedCoordinator.resolve(
      command: .get,
      named: "desk airpods",
      chooseAmbiguous: { _ in .unavailable }
    )
    if case .session(let session) = namedSelected {
      #expect(
        session.transport.listeningModeTransportKind == .av,
        "an exact HAL name still pairs the unique selected AV endpoint"
      )
    } else {
      Issue.record("a shared AV/HAL name identifies one selected logical target")
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
      #expect(
        session.transport.listeningModeTransportKind == .hal,
        "an unselected HAL target remains reachable beside a differently named AV target"
      )
    } else {
      Issue.record("the unique unselected HAL name resolves without ambiguity")
    }

    let independentAV = FakeListeningModeTransport(
      name: "Desk AirPods",
      kind: .av
    )
    let sameName = try coordinatorOutcome(
      ["--device", "Desk AirPods", "lm", "set", "adaptive"],
      candidates: [
        candidate(name: "Desk AirPods", av: independentAV, route: .unknown),
        candidate(name: "Desk AirPods", hal: unselectedHAL, route: .notSelected),
      ]
    )
    #expect(
      sameName.plain == "ambiguous-device",
      "independent AV and HAL targets with the same name stay ambiguous"
    )
    #expect(independentAV.setterTargets.isEmpty, "ambiguous AV target is not written")
    #expect(unselectedHAL.setterTargets.isEmpty, "ambiguous HAL target is not written")

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
      #expect(
        session.transport.listeningModeTransportKind == .av,
        "a named AV-only sibling remains reachable when HAL exists"
      )
    } else {
      Issue.record("a unique AV-only name remains reachable")
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
    if case .failed(.ambiguousDevice) = unnamedMixed {
    } else {
      Issue.record("unnamed mixed providers remain ambiguous")
    }
    #expect(chooserCalled, "independent AV rows participate in the chooser")

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
    if case .failed(.ambiguousDevice) = avOnly {
    } else {
      Issue.record("HAL absence never selects the first AV candidate")
    }
  }

  @Test
  func hALListeningModeTranslationAndOffLimitation() throws {
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

    #expect(transport.currentListeningMode() == .off, "HAL translates raw current Off")
    #expect(
      transport.availableListeningModes()
        == [.transparency, .adaptive, .noiseCancellation],
      "HAL retains known lsms bits, ignores unknown bits, and omits Off"
    )
    let changed = transport.setListeningModeAndReadBack(.adaptive)
    #expect(changed.setterAccepted, "HAL accepts a mask-proven non-Off target")
    #expect(changed.observed == .adaptive, "HAL reads back the requested normalized state")
    #expect(backend.writtenValues == [4], "HAL writes the exact Adaptive UInt32")

    backend.rawModeRead = .value(1)
    let off = transport.setListeningModeAndReadBack(.off)
    #expect(!off.setterAccepted, "HAL production transport rejects Off pending discovery")
    #expect(off.observed == .off, "rejected HAL Off retains the observed current state")
    #expect(backend.writtenValues == [4], "HAL Off rejection performs no setter")

    backend.rawModeRead = .value(99)
    #expect(transport.currentListeningMode() == nil, "unknown HAL current raw value fails closed")
    let writeCountBeforeUnknown = backend.writtenValues.count
    let unknownCurrentOutcome = try coordinatorOutcome(
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
    #expect(unknownCurrentOutcome.plain == "unavailable", "unknown HAL state blocks a write")
    #expect(
      backend.writtenValues.count == writeCountBeforeUnknown,
      "unknown HAL state never reaches the setter"
    )
    backend.supportRead = .failure(-50)
    #expect(transport.availableListeningModes().isEmpty, "failed HAL support read is unavailable")
  }
}
