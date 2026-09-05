import Foundation
import Testing

@testable import AirPodsControlCore

private func privateAVDevice(
  name: String,
  modes: [String] = Array(rawListeningModeValues.values),
  sources: Set<PrivateAudioDiscoverySource>
) -> (PrivateAudioDevice, FakeRawDevice) {
  let raw = FakeRawDevice(name: name, modes: modes)
  let device = PrivateAudioDevice.compatible(
    object: raw,
    sources: sources,
    index: 0,
    logger: DebugLogger(enabled: false)
  )!
  return (device, raw)
}

private func bootstrapListeningModeOutcome(
  _ arguments: [String],
  avDevices: [PrivateAudioDevice],
  loadHAL: @escaping () -> ListeningModeBootstrap.HALInventory
) throws -> CommandOutcome {
  let invocation = try parseInvocation(arguments)
  return CommandExecution.executeListeningMode(
    invocation,
    resolveSession: { command, name, logger in
      ListeningModeBootstrap.resolve(
        command: command,
        named: name,
        avDevices: avDevices,
        logger: logger,
        chooseAmbiguous: { _ in .unavailable },
        loadHAL: loadHAL
      )
    }
  )
}

private final class HALInventoryRecorder {
  private(set) var loadCount = 0
  private let inventory: ListeningModeBootstrap.HALInventory
  init(
    candidates: [ListeningModeCandidate] = [],
    discovery: ListeningModeHALDiscovery = .available
  ) {
    inventory = .init(candidates: candidates, discovery: discovery)
  }
  func load() -> ListeningModeBootstrap.HALInventory {
    loadCount += 1
    return inventory
  }
}

@Suite("Listening mode bootstrap")
struct ListeningModeBootstrapTests {

  @Test
  func defersInventoryForSelectedReadyGet() throws {
    let (selected, _) = privateAVDevice(
      name: "Desk AirPods",
      sources: [.contextSingular]
    )
    let recorder = HALInventoryRecorder()
    var outcome: CommandOutcome?
    let stderr = try capturingStandardError {
      outcome = try bootstrapListeningModeOutcome(
        ["--debug", "lm", "get"],
        avDevices: [selected],
        loadHAL: recorder.load
      )
    }
    #expect(outcome?.plain == "transparency", "selected AV-ready get uses AV")
    #expect(recorder.loadCount == 0, "selected AV-ready get does not construct HAL inventory")
    guard let stderr else {
      Issue.record("the debug stream on standard error can be captured")
      return
    }
    #expect(
      stderr.contains("debug: listening_mode.hal_inventory=\"deferred\""),
      "selected AV-ready path logs deferred HAL inventory"
    )
    #expect(
      stderr.contains("info: listening_mode.transport=\"av\""),
      "selected AV-ready path logs the AV transport"
    )
  }

  @Test
  func defersInventoryForSelectedReadyList() throws {
    let (selected, _) = privateAVDevice(
      name: "Desk AirPods",
      sources: [.contextSingular]
    )
    let recorder = HALInventoryRecorder()
    let outcome = try bootstrapListeningModeOutcome(
      ["lm", "list"],
      avDevices: [selected],
      loadHAL: recorder.load
    )
    #expect(
      outcome.plain == "off,transparency,adaptive,noise-cancellation",
      "selected AV-ready list uses AV"
    )
    #expect(recorder.loadCount == 0, "selected AV-ready list does not construct HAL inventory")
  }

  @Test
  func defersInventoryForSelectedReadySet() throws {
    let (selected, selectedRaw) = privateAVDevice(
      name: "Desk AirPods",
      sources: [.contextSingular]
    )
    let unusedHAL = FakeListeningModeTransport(
      name: "Desk AirPods",
      kind: .hal,
      modes: [.transparency, .adaptive, .noiseCancellation]
    )
    let recorder = HALInventoryRecorder(
      candidates: [candidate(hal: unusedHAL, route: .selected)]
    )

    let setOutcome = try bootstrapListeningModeOutcome(
      ["lm", "set", "adaptive"],
      avDevices: [selected],
      loadHAL: recorder.load
    )
    #expect(setOutcome.plain == "ok", "selected AV-ready set still writes through AV")

    let namedSet = try bootstrapListeningModeOutcome(
      ["--device", "Desk AirPods", "lm", "set", "noise-cancellation"],
      avDevices: [selected],
      loadHAL: recorder.load
    )
    #expect(namedSet.plain == "ok", "named selected AV-ready set still writes through AV")
    #expect(
      selectedRaw.listeningModeSetCount == 2,
      "selected AV receives both unnamed and named setters"
    )
    #expect(unusedHAL.setterTargets.isEmpty, "deferred HAL inventory performs no setter")
    #expect(recorder.loadCount == 0, "selected AV-ready set does not construct HAL inventory")
  }

  @Test
  func defersInventoryForSelectedAVOff() throws {
    let (selected, selectedRaw) = privateAVDevice(
      name: "Desk AirPods",
      sources: [.contextSingular]
    )
    let recorder = HALInventoryRecorder()
    let outcome = try bootstrapListeningModeOutcome(
      ["lm", "set", "off"],
      avDevices: [selected],
      loadHAL: recorder.load
    )
    #expect(outcome.plain == "ok", "selected AV that advertises Off writes Off without HAL")
    #expect(selectedRaw.listeningModeSetCount == 1, "AV Off write does not require HAL inventory")
    #expect(recorder.loadCount == 0, "AV-ready Off does not construct HAL inventory")
  }

  @Test
  func defersInventoryForSelectedReadyCycle() throws {
    let (selected, selectedRaw) = privateAVDevice(
      name: "Desk AirPods",
      sources: [.contextSingular]
    )
    let recorder = HALInventoryRecorder()
    let outcome = try bootstrapListeningModeOutcome(
      ["lm", "cycle"],
      avDevices: [selected],
      loadHAL: recorder.load
    )
    #expect(outcome.plain == "adaptive", "selected AV-ready cycle advances from transparency")
    #expect(selectedRaw.listeningModeSetCount == 1, "selected AV receives the cycle setter")
    #expect(recorder.loadCount == 0, "selected AV-ready cycle does not construct HAL inventory")
  }

  @Test
  func loadsInventoryWhenSelectedAVIsIncomplete() throws {
    let (incomplete, incompleteRaw) = privateAVDevice(
      name: "Desk AirPods",
      modes: [],
      sources: [.contextSingular]
    )
    let fallbackHAL = FakeListeningModeTransport(
      name: "Desk AirPods",
      kind: .hal,
      modes: [.transparency, .adaptive, .noiseCancellation]
    )
    let recorder = HALInventoryRecorder(
      candidates: [candidate(hal: fallbackHAL, route: .selected)]
    )
    let outcome = try bootstrapListeningModeOutcome(
      ["lm", "set", "adaptive"],
      avDevices: [incomplete],
      loadHAL: recorder.load
    )
    #expect(outcome.plain == "ok", "incomplete selected AV still falls back to HAL")
    #expect(
      incompleteRaw.listeningModeSetCount == 0,
      "incomplete selected AV performs no setter"
    )
    #expect(fallbackHAL.setterTargets == [.adaptive], "HAL saves the selected-AV write")
    #expect(recorder.loadCount == 1, "incomplete selected AV constructs HAL inventory once")
  }

  @Test
  func loadsInventoryForExplicitOffWithoutAVOff() throws {
    let noOffModes = [
      rawListeningModeValues[.transparency]!,
      rawListeningModeValues[.adaptive]!,
      rawListeningModeValues[.noiseCancellation]!,
    ]
    let (noOffAV, noOffRaw) = privateAVDevice(
      name: "Desk AirPods",
      modes: noOffModes,
      sources: [.contextSingular]
    )
    let probeHAL = FakeListeningModeTransport(
      name: "Desk AirPods",
      kind: .hal,
      modes: [.transparency, .adaptive, .noiseCancellation]
    )
    let recorder = HALInventoryRecorder(
      candidates: [candidate(hal: probeHAL, route: .selected)]
    )
    let outcome = try bootstrapListeningModeOutcome(
      ["lm", "set", "off"],
      avDevices: [noOffAV],
      loadHAL: recorder.load
    )
    #expect(outcome.plain == "ok", "explicit Off still reaches a HAL Off probe")
    #expect(noOffRaw.listeningModeSetCount == 0, "AV without Off does not take the Off write")
    #expect(
      probeHAL.allowOffWrites == [true],
      "HAL Off probe uses the allowing-off setter"
    )
    #expect(recorder.loadCount == 1, "explicit Off without AV Off constructs HAL inventory")
  }

  @Test
  func loadsInventoryForUnknownRouteThenWritesThroughAV() throws {
    let (unknownAV, unknownRaw) = privateAVDevice(
      name: "Nearby AirPods",
      sources: [.contextPlural]
    )
    let recorder = HALInventoryRecorder()
    let outcome = try bootstrapListeningModeOutcome(
      ["lm", "set", "adaptive"],
      avDevices: [unknownAV],
      loadHAL: recorder.load
    )
    #expect(outcome.plain == "ok", "unknown-route AV can still write after HAL loads")
    #expect(unknownRaw.listeningModeSetCount == 1, "unknown-route AV write still uses AV")
    #expect(recorder.loadCount == 1, "unknown-route AV constructs HAL inventory")
  }

  @Test
  func loadsInventoryWhenNamedDeviceMissesAV() throws {
    let (selected, _) = privateAVDevice(
      name: "Desk AirPods",
      sources: [.contextSingular]
    )
    let recorder = HALInventoryRecorder()
    let outcome = try bootstrapListeningModeOutcome(
      ["--device", "Travel AirPods", "lm", "get"],
      avDevices: [selected],
      loadHAL: recorder.load
    )
    #expect(
      outcome.terminalReason == .noDevice,
      "an AV name miss still loads HAL before failing"
    )
    #expect(recorder.loadCount == 1, "--device that does not resolve on AV constructs HAL inventory")
  }

  @Test
  func loadsInventoryForUnselectedHALWrite() throws {
    let unselectedHAL = FakeListeningModeTransport(
      name: "Travel AirPods",
      kind: .hal,
      modes: [.transparency, .adaptive, .noiseCancellation]
    )
    let recorder = HALInventoryRecorder(
      candidates: [
        candidate(
          name: "Travel AirPods",
          hal: unselectedHAL,
          route: .notSelected
        )
      ]
    )
    var outcome: CommandOutcome?
    let stderr = try capturingStandardError {
      outcome = try bootstrapListeningModeOutcome(
        ["--debug", "lm", "set", "adaptive"],
        avDevices: [],
        loadHAL: recorder.load
      )
    }
    #expect(outcome?.plain == "ok", "unselected AirPods still write through HAL")
    #expect(unselectedHAL.setterTargets == [.adaptive], "unselected HAL receives the setter")
    #expect(recorder.loadCount == 1, "AV-absent unselected control constructs HAL inventory")
    guard let stderr else {
      Issue.record("the debug stream on standard error can be captured")
      return
    }
    #expect(
      stderr.contains("debug: listening_mode.hal_inventory=\"loaded\""),
      "unselected control logs loaded HAL inventory"
    )
  }

  @Test
  func mapsControllerCreationResultToInventory() {
    let (unavailableResult, _) = makeBluetoothControllerResult(
      inventory: [],
      inventoryRead: .unavailable
    )
    let unavailable = ListeningModeBootstrap.HALInventory(unavailableResult)
    #expect(unavailable.discovery == .unavailable, "unavailable inventory maps discovery")
    #expect(unavailable.candidates.isEmpty, "unavailable inventory has no candidates")

    let (readErrorResult, _) = makeBluetoothControllerResult(
      inventory: [],
      inventoryRead: .failure(-1)
    )
    let readError = ListeningModeBootstrap.HALInventory(readErrorResult)
    #expect(readError.discovery == .readError, "failed inventory maps a typed read error")
    #expect(readError.candidates.isEmpty, "failed inventory has no candidates")

    let (availableResult, _) = makeBluetoothControllerResult(
      inventory: [],
      inventoryRead: .value([])
    )
    let available = ListeningModeBootstrap.HALInventory(availableResult)
    #expect(available.discovery == .available, "empty successful inventory stays available")
    #expect(available.candidates.isEmpty, "empty successful inventory has no candidates")
  }
}
