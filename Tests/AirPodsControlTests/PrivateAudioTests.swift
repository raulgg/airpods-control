import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Private audio")
struct PrivateAudioTests {
  @Test
  func privateListeningModeTranslationAndStatusClassification() throws {
    let rawDevice = FakeRawDevice(
      name: "Translation AirPods",
      modes: [
        rawListeningModeValues[.noiseCancellation]!,
        rawListeningModeValues[.transparency]!,
        "AVOutputDeviceBluetoothListeningModeFuture",
      ],
      mode: rawListeningModeValues[.noiseCancellation]!
    )
    let device = privateAudioDevice(rawDevice)
    #expect(
      device.availableListeningModes() == [.noiseCancellation, .transparency],
      "private adapter translates known available modes"
    )
    #expect(
      device.currentListeningMode() == .noiseCancellation,
      "private adapter translates the current mode"
    )
    if case .value(.noiseCancellation) = device.readListeningModeStatus() {
    } else {
      Issue.record("status maps a known private listening mode")
    }

    let future = scriptedPrivateAudioDevice(
      reads: ["AVOutputDeviceBluetoothListeningModeFuture"]
    )
    #expect(future.currentListeningMode() == nil, "private adapter does not invent unknown modes")
    if case .unresolved = future.readListeningModeStatus() {
    } else {
      Issue.record("an answered but unknown mode is unresolved")
    }

    let failed = scriptedPrivateAudioDevice(reads: [nil])
    if case .readError = failed.readListeningModeStatus() {
    } else {
      Issue.record("a missing required mode response is a status read error")
    }

    let emptyRaw = FakeRawDevice(name: "Empty Inventory AirPods", modes: [])
    let emptyDevices = try requireSelectedDevices(PrivateAudioController(
      endpoints: PrivateAudioContextEndpoints(plural: [], singular: emptyRaw),
      logger: DebugLogger(enabled: false)
    ).resolveDevices(named: nil, policy: .singleOrExact))
    let empty = try #require(emptyDevices.first, "an empty AV inventory resolves its singular endpoint")
    if case .value(let modes) = empty.listeningModeAvailabilityObservation() {
      #expect(modes.isEmpty, "an answered empty AV inventory is typed evidence")
    } else {
      Issue.record("an answered empty AV inventory is typed evidence")
    }

    let unsupportedCA = privateAudioDevice(
      FakeRawDevice(name: "Unsupported CA AirPods", conversationAwarenessSupported: false)
    )
    if case .unsupported = unsupportedCA.readConversationAwarenessStatus() {
    } else {
      Issue.record("explicit false proves Conversation Awareness unsupported")
    }

    let unresolvedCA = privateAudioDevice(FakeReadOnlyRawDevice(name: "Unresolved CA AirPods"))
    if case .unresolved = unresolvedCA.readConversationAwarenessStatus() {
    } else {
      Issue.record("a missing Conversation Awareness support probe is unresolved")
    }

    let failedCA = privateAudioDevice(FakeMissingConversationAwarenessStateRawDevice())
    if case .readError = failedCA.readConversationAwarenessStatus() {
    } else {
      Issue.record("advertised CA with no state getter is a read error")
    }
  }

  @Test
  func supportReportDiscoveryDoesNotReadDeviceNames() throws {
    let rawDevice = FakeSupportReportRawDevice()
    let controller = PrivateAudioController(
      rawDevices: [rawDevice],
      logger: DebugLogger(enabled: false),
      includeDeviceNames: false
    )
    let devices = try requireSelectedDevices(
      controller.resolveDevices(named: nil, policy: .singleOrExact),
      "support-report discovers an allowlisted device without a name"
    )
    let device = try #require(devices.first, "support-report selected an allowlisted device")
    let report = passiveSupportReport(device: device)
    #expect(report != nil, "name-free private adapter produces a support report")
    #expect(
      report?.terminalOutput.contains("BTHeadphones76,8231") == true,
      "name-free report includes the allowlisted model identifier"
    )
    #expect(
      report?.terminalOutput.contains("Family                   AirPods") == true,
      "the Bluetooth model identifier resolves to the AirPods family"
    )
    #expect(
      report?.terminalOutput.contains("Model                    AirPods Pro 3") == true,
      "the Bluetooth product ID resolves to a model name"
    )
    #expect(device.name == nil, "support-report adapter retains no customizable name")
    #expect(
      rawDevice.nameReadCount == 0,
      "support-report never invokes the customizable name selector"
    )
    if case .noDevice = controller.resolveDevices(
      named: "Custom Owner Name",
      policy: .singleOrExact
    ) {
    } else {
      Issue.record("name-free discovery refuses --device selection")
    }
    #expect(
      rawDevice.nameReadCount == 0,
      "refusing --device selection reads no customizable name"
    )
    #expect(
      report?.terminalOutput.contains("Custom Owner Name") == false,
      "support-report output never contains the customizable name"
    )
    #expect(!device.canSetListeningMode(), "support-report fixture exposes no mode setter")
    #expect(
      !device.canSetConversationAwareness(),
      "support-report fixture exposes no Conversation Awareness setter"
    )

    let otherRawDevice = FakeSupportReportRawDevice()
    let ambiguousController = PrivateAudioController(
      rawDevices: [rawDevice, otherRawDevice],
      logger: DebugLogger(enabled: false),
      includeDeviceNames: false
    )
    if case .ambiguousDevice = ambiguousController.resolveDevices(
      named: nil,
      policy: .singleOrExact
    ) {
    } else {
      Issue.record("name-free support-report selection requires one unique compatible device")
    }
    #expect(
      rawDevice.nameReadCount == 0 && otherRawDevice.nameReadCount == 0,
      "rejecting multiple report devices still reads no customizable names"
    )

    let namelessController = PrivateAudioController(
      rawDevices: [FakeNamelessRawDevice()],
      logger: DebugLogger(enabled: false),
      includeDeviceNames: false
    )
    if case .noDevice = namelessController.resolveDevices(
      named: nil,
      policy: .singleOrExact
    ) {
    } else {
      Issue.record("support-report rejects devices that other commands cannot target")
    }
  }

  // support-report is the one command that resolves its device with
  // includeDeviceNames: false, which is what makes --debug safe for it. Pin that
  // across the whole reachable log surface — discovery, selection, the snapshot
  // reads, and the write-test writes — instead of trusting the name sites in
  // compatible(object:index:logger:includeDeviceName:) to stay gated.
  @Test
  func supportReportDebugStreamOmitsTheDeviceName() throws {
    let ownerName = "Custom Owner Name"
    let rawDevice = FakeRawDevice(
      name: ownerName,
      modelIdentifier: "BTHeadphones76,8231",
      listeningModeError: NSError(domain: ownerName, code: 73),
      conversationAwarenessError: NSError(domain: ownerName, code: 74)
    )
    var report: SupportReportDocument?

    let captured = try capturingStandardError {
      let devices = try requireSelectedDevices(PrivateAudioController(
        rawDevices: [rawDevice],
        logger: DebugLogger(enabled: true),
        includeDeviceNames: false
      ).resolveDevices(named: nil, policy: .singleOrExact))
      let device = try #require(devices.first, "name-free support-report selects one device")
      report = passiveSupportReport(device: device)
      // The write tester holds each mode for two seconds and carries no logger, so
      // the wait-free overloads reach every write-path log site without the wait.
      _ = device.setListeningModeAndReadBack(.noiseCancellation, wait: { _ in })
      _ = device.setConversationAwarenessAndReadBack(true, wait: { _ in })
    }

    guard let captured else {
      Issue.record("the debug stream on standard error can be captured")
      return
    }
    #expect(report != nil, "the captured run produced a support report")
    #expect(
      rawDevice.listeningModeSetCount == 1 && rawDevice.conversationAwarenessSetCount == 1,
      "the captured run reached both setters"
    )
    #expect(
      captured.contains("debug: device.0.compatible=true"),
      "the debug stream reaches name-free device discovery"
    )
    #expect(
      captured.contains("info: selected_device=\"name-not-read\""),
      "selection logs a placeholder in place of the name"
    )
    #expect(
      captured.contains("debug: write.listening_mode.accepted=false")
        && captured.contains("warning: write.listening_mode.error=73")
        && captured.contains("warning: write.conversation_awareness.error=74"),
      "the debug stream reaches both setter-error branches without their domains"
    )
    #expect(
      !captured.contains(ownerName),
      "no support-report debug line carries the customizable device name"
    )
  }

  @Test
  func listeningModeReadbackWaitsSettlesAndPreservesUnknown() throws {
    let off = rawListeningModeValues[.off]!
    let delayed = scriptedPrivateAudioDevice(
      reads: [
        rawListeningModeValues[.noiseCancellation]!,
        rawListeningModeValues[.noiseCancellation]!,
        off,
      ]
    )
    #expect(
      delayed.setListeningModeAndReadBack(.off, wait: { _ in }).observed == .off,
      "listening-mode readback waits for a delayed target"
    )

    let adaptive = rawListeningModeValues[.adaptive]!
    var waitCount = 0
    let immediate = scriptedPrivateAudioDevice(
      reads: [adaptive],
      setterAccepted: false
    ).setListeningModeAndReadBack(.adaptive) { _ in waitCount += 1 }
    #expect(
      immediate.observed == .adaptive,
      "observed target is authoritative when the setter rejects"
    )
    #expect(!immediate.setterAccepted, "readback preserves setter rejection")
    #expect(waitCount == 0, "observed target returns without waiting")

    let noiseCancellation = rawListeningModeValues[.noiseCancellation]!
    let transparency = rawListeningModeValues[.transparency]!
    waitCount = 0
    let fallback = scriptedPrivateAudioDevice(
      reads: [noiseCancellation, transparency]
        + Array(repeating: noiseCancellation, count: 18)
        + [transparency]
    ).setListeningModeAndReadBack(.off) { _ in waitCount += 1 }
    #expect(fallback.observed == .transparency, "Off returns the settled fallback mode")
    #expect(fallback.setterAccepted, "readback preserves setter acceptance")
    #expect(waitCount > 0, "Off readback waits for the fallback to settle")

    #expect(
      scriptedPrivateAudioDevice(
        reads: [noiseCancellation, "AVOutputDeviceBluetoothListeningModeFuture"]
      ).setListeningModeAndReadBack(.off, wait: { _ in }).observed == nil,
      "unknown final readback becomes null state"
    )
    #expect(
      scriptedPrivateAudioDevice(reads: [noiseCancellation, nil])
        .setListeningModeAndReadBack(.off, wait: { _ in }).observed == nil,
      "missing final readback becomes null state"
    )
  }

  @Test(.serialized, arguments: [
    FakeRawDevice.ListeningModeUpdateDelivery.mainRunLoop,
    .mainDispatchQueue,
  ])
  func listeningModeReadbackProcessesAsyncDeviceUpdates(
    delivery: FakeRawDevice.ListeningModeUpdateDelivery
  ) async throws {
    // Like the CLI, run on the main thread outside a main-dispatch task,
    // which cannot drain its own queue. Serial cases prevent nested readbacks.
    let (isMainThread, observation): (Bool, DeviceWriteObservation<ListeningMode>) =
      await withCheckedContinuation { continuation in
        RunLoop.main.perform {
          let rawDevice = FakeRawDevice(
            name: "Async AirPods",
            mode: rawListeningModeValues[.noiseCancellation]!,
            listeningModeUpdateDelivery: delivery
          )
          let device = privateAudioDevice(rawDevice)
          continuation.resume(returning: (
            Thread.isMainThread,
            device.setListeningModeAndReadBack(.transparency)
          ))
        }
      }

    try #require(isMainThread, "async readback runs on the main thread")
    #expect(observation.setterAccepted, "the asynchronous setter accepts the write")

    #expect(
      observation.observed == .transparency,
      "readback processes asynchronous device updates"
    )
  }

  @Test
  func conversationAwarenessReadbackPolicy() throws {
    let unchangedRawDevice = FakeRawDevice(
      name: "Unchanged Awareness AirPods",
      conversationAwarenessEnabled: false,
      appliesConversationAwarenessWrite: false
    )
    let unchangedDevice = privateAudioDevice(unchangedRawDevice)
    var waitCount = 0

    let unchanged = unchangedDevice.setConversationAwarenessAndReadBack(true) { _ in
      waitCount += 1
    }

    #expect(unchanged.setterAccepted, "Conversation Awareness preserves setter acceptance")
    #expect(unchanged.observed == false, "Conversation Awareness returns final observed state")
    #expect(waitCount > 0, "Conversation Awareness waits for an unapplied write")

    let changedRawDevice = FakeRawDevice(
      name: "Changed Awareness AirPods",
      conversationAwarenessEnabled: false
    )
    let changedDevice = privateAudioDevice(changedRawDevice)
    let changed = changedDevice.setConversationAwarenessAndReadBack(true, wait: { _ in })

    #expect(changed.observed == true, "Conversation Awareness returns an applied write")
    #expect(
      changedRawDevice.conversationAwarenessSetCount == 1,
      "Conversation Awareness invokes the private setter once"
    )
  }

  @Test
  func deviceSelectionAndCapabilities() throws {
    let logger = DebugLogger(enabled: false)
    let first = FakeRawDevice(name: "My AirPods Pro")
    let second = FakeRawDevice(name: "Studio AirPods")
    let controller = PrivateAudioController(rawDevices: [first, second], logger: logger)

    if case .ambiguousDevice = controller.resolveDevices(
      named: nil,
      policy: .singleOrExact
    ) {
    } else {
      Issue.record("multiple unnamed devices have a typed ambiguous result")
    }
    let allDevices = try requireSelectedDevices(
      controller.resolveDevices(named: nil, policy: .allOrExact),
      "all-device selection preserves private routing discovery order"
    )
    #expect(
      allDevices.compactMap(\.name) == ["My AirPods Pro", "Studio AirPods"],
      "all-device selection preserves private routing discovery order"
    )
    let exactDevices = try requireSelectedDevices(
      controller.resolveDevices(named: "STUDIO AIRPODS", policy: .allOrExact),
      "all-or-exact selection returns one uniquely named device"
    )
    #expect(
      exactDevices.compactMap(\.name) == ["Studio AirPods"],
      "all-or-exact selection returns one uniquely named device"
    )
    let namedDevices = try requireSelectedDevices(
      controller.resolveDevices(named: "MY AIRPODS PRO", policy: .singleOrExact),
      "device matching is case-insensitive and exact"
    )
    let namedDevice = try #require(namedDevices.first, "device matching selects one exact device")
    #expect(namedDevice.name == "My AirPods Pro", "device matching is case-insensitive and exact")
    if case .noDevice = controller.resolveDevices(named: "My", policy: .singleOrExact) {
    } else {
      Issue.record("device matching does not use substrings")
    }
    if case .noDevice = controller.resolveDevices(
      named: "Missing AirPods",
      policy: .singleOrExact
    ) {
    } else {
      Issue.record("device matching never falls back")
    }

    let duplicate = FakeRawDevice(name: "MY AIRPODS PRO")
    let ambiguous = PrivateAudioController(rawDevices: [first, duplicate], logger: logger)
    if case .ambiguousDevice = ambiguous.resolveDevices(
      named: "My AirPods Pro",
      policy: .singleOrExact
    ) {
    } else {
      Issue.record("duplicate exact names are rejected")
    }
    if case .ambiguousDevice = ambiguous.resolveDevices(
      named: "My AirPods Pro",
      policy: .allOrExact
    ) {
    } else {
      Issue.record("status rejects duplicate case-insensitive exact names")
    }
    for arguments in [
      ["--device", "My AirPods Pro", "lm", "set", "adaptive"],
      ["--device", "My AirPods Pro", "ca", "set", "on"],
    ] {
      let invocation = try parseInvocation(arguments)
      let outcome = CommandExecution.execute(
        invocation,
        resolveDevices: { name, policy, _ in
          switch ambiguous.resolveDevices(named: name, policy: policy) {
          case let .selected(devices): return .devices(devices.map { $0 })
          case .noDevice: return .failed(.noDevice)
          case .ambiguousDevice: return .failed(.ambiguousDevice)
          }
        }
      )
      #expect(outcome.plain == "ambiguous-device", "ambiguous named setter stays explicit")
    }
    #expect(
      first.listeningModeSetCount == 0 && duplicate.listeningModeSetCount == 0,
      "ambiguous selection cannot write listening mode"
    )
    #expect(
      first.conversationAwarenessSetCount == 0
        && duplicate.conversationAwarenessSetCount == 0,
      "ambiguous selection cannot write Conversation Awareness"
    )

    let incomplete = FakeIncompleteRawDevice()
    let filtered = PrivateAudioController(rawDevices: [incomplete, second], logger: logger)
    let filteredDevices = try requireSelectedDevices(
      filtered.resolveDevices(named: nil, policy: .singleOrExact),
      "devices missing a core selector are ignored"
    )
    let filteredDevice = try #require(filteredDevices.first, "the filtered device is selected")
    #expect(filteredDevice.name == "Studio AirPods", "devices missing a core selector are ignored")
    let beats = FakeRawDevice(name: "Studio Beats", modelIdentifier: "BeatsTest1,1")
    let ordered = PrivateAudioController(
      rawDevices: [second, incomplete, beats, first],
      logger: logger
    )
    let orderedDevices = try requireSelectedDevices(
      ordered.resolveDevices(named: nil, policy: .allOrExact),
      "all-device selection keeps compatible Beats and stable filtered order"
    )
    #expect(
      orderedDevices.compactMap(\.name)
        == ["Studio AirPods", "Studio Beats", "My AirPods Pro"],
      "all-device selection keeps compatible Beats and stable filtered order"
    )

    let readOnly = FakeReadOnlyRawDevice(name: "Read-only AirPods")
    let readOnlyController = PrivateAudioController(rawDevices: [readOnly], logger: logger)
    let readOnlyDevices = try requireSelectedDevices(
      readOnlyController.resolveDevices(named: nil, policy: .singleOrExact),
      "read-only device remains available for reads"
    )
    let selectedReadOnly = try #require(readOnlyDevices.first, "read-only device is selected")
    #expect(!selectedReadOnly.canSetListeningMode(), "missing mode setter is detected")
    #expect(
      selectedReadOnly.supportsConversationAwareness() == nil,
      "missing Conversation Awareness selector is detected"
    )

    let selectedDevices = try requireSelectedDevices(
      controller.resolveDevices(named: "Studio AirPods", policy: .singleOrExact),
      "a uniquely named device is selected"
    )
    let selected = try #require(selectedDevices.first, "the uniquely named device is selected")
    let reportMetadata = selected.supportReportMetadata()
    #expect(reportMetadata.family == .airPods, "report identifies AirPods from model metadata")
    #expect(
      reportMetadata.modelIdentifier == "AirPodsTest1,1",
      "report reads the allowlisted model identifier"
    )
    #expect(
      reportMetadata.unrecognizedListeningModes.isEmpty,
      "all-known advertised modes leave nothing unrecognized"
    )
    #expect(
      reportMetadata.listeningModeQueryAnswered,
      "an answering mode query is recorded for the report"
    )
    #expect(selected.canSetListeningMode(), "mode setter capability is detected")
    _ = selected.setListeningModeAndReadBack(.adaptive, wait: { _ in })
    #expect(
      selected.currentListeningMode() == .adaptive,
      "mode setter is invoked after capability checking"
    )
    #expect(selected.supportsConversationAwareness() == true, "CA support is read")
    _ = selected.setConversationAwarenessAndReadBack(true, wait: { _ in })
    #expect(selected.conversationAwarenessState() == true, "CA setter and state are invoked safely")
  }

  @Test
  func supportReportMetadataForUnrecognizedModes() throws {
    let future = FakeRawDevice(
      name: "Future AirPods",
      modes: [
        rawListeningModeValues[.off]!,
        "AVOutputDeviceBluetoothListeningModeHearingAid",
      ],
      mode: "AVOutputDeviceBluetoothListeningModeHearingAid",
      modelIdentifier: "BTHeadphones76,8231"
    )
    let device = privateAudioDevice(future)
    let metadata = device.supportReportMetadata()
    #expect(
      metadata.unrecognizedListeningModes
        == ["AVOutputDeviceBluetoothListeningModeHearingAid"],
      "an unknown advertised mode is carried into the report metadata"
    )
    #expect(
      metadata.listeningModeQueryAnswered,
      "an unmapped current mode still counts as an answered query"
    )
    #expect(
      device.currentListeningMode() == nil,
      "an unmapped current mode is not translated"
    )

    let allUnknown = FakeRawDevice(
      name: "Unknown-mode AirPods",
      modes: ["AVOutputDeviceBluetoothListeningModeFuture"],
      mode: "AVOutputDeviceBluetoothListeningModeFuture",
      modelIdentifier: "BTHeadphones76,8231"
    )
    let report = passiveSupportReport(device: privateAudioDevice(allUnknown))
    let cliOutput = report?.terminalOutput ?? ""
    #expect(report != nil, "a device advertising only unknown modes still reports")
    #expect(
      cliOutput.contains("Listening modes          Unavailable / not reported"),
      "unknown-only advertised modes leave the known list empty"
    )
    #expect(
      cliOutput.contains(
        "Other modes              AVOutputDeviceBluetoothListeningModeFuture"
      ),
      "unknown-only advertised modes are still reported verbatim"
    )
    #expect(
      cliOutput.contains("Mode query               Available · unrecognized mode"),
      "an unmapped current mode is distinguished in the report"
    )
  }
}
