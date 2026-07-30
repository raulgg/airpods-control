import Foundation

func testPrivateSelectorDiscovery() {
  let logger = DebugLogger(enabled: false)
  let modern = FakeContext(devices: [])
  let legacy = FakeContext(devices: [])

  let legacyProvider = FakeLegacyContextProvider(context: legacy)
  let selectedLegacy = PrivateAudioDiscovery.sharedContext(from: legacyProvider, logger: logger)
  check(selectedLegacy === legacy, "legacy sharedSystemAudio selector is supported")

  let dualProvider = FakeDualContextProvider(modern: modern, legacy: legacy)
  let selectedModern = PrivateAudioDiscovery.sharedContext(from: dualProvider, logger: logger)
  check(selectedModern === modern, "modern context selector is preferred")

  let missingProvider = NSObject()
  check(
    PrivateAudioDiscovery.sharedContext(from: missingProvider, logger: logger) == nil,
    "missing context selectors return nil"
  )
  check(
    PrivateAudioDiscovery.outputDevices(from: missingProvider, logger: logger) == nil,
    "missing outputDevices selector returns nil"
  )

  let device = FakeRawDevice(name: "My AirPods Pro")
  let context = FakeContext(devices: [device])
  let outputDevices = PrivateAudioDiscovery.outputDevices(from: context, logger: logger)
  check(outputDevices?.count == 1, "outputDevices is discovered safely")
}

func testPrivateListeningModeTranslation() {
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
  check(
    device.availableListeningModes() == [.noiseCancellation, .transparency],
    "private adapter translates known available modes"
  )
  check(
    device.currentListeningMode() == .noiseCancellation,
    "private adapter translates the current mode"
  )

  let unknown = scriptedPrivateAudioDevice(
    reads: ["AVOutputDeviceBluetoothListeningModeFuture"]
  )
  check(unknown.currentListeningMode() == nil, "private adapter does not invent unknown modes")
}

func testSupportReportDiscoveryDoesNotReadDeviceNames() {
  let rawDevice = FakeSupportReportRawDevice()
  let controller = PrivateAudioController(
    rawDevices: [rawDevice],
    logger: DebugLogger(enabled: false),
    includeDeviceNames: false
  )
  guard let device = controller.selectDevice(named: nil) else {
    check(false, "support-report discovers an allowlisted device without a name")
    return
  }
  let report = passiveSupportReport(device: device)
  check(report != nil, "name-free private adapter produces a support report")
  check(
    report?.terminalOutput.contains("BTHeadphones76,8231") == true,
    "name-free report includes the allowlisted model identifier"
  )
  check(
    report?.terminalOutput.contains("Family                   AirPods") == true,
    "the Bluetooth model identifier resolves to the AirPods family"
  )
  check(
    report?.terminalOutput.contains("Model                    AirPods Pro 3") == true,
    "the Bluetooth product ID resolves to a model name"
  )
  check(device.name.isEmpty, "support-report adapter retains no customizable name")
  check(
    rawDevice.nameReadCount == 0,
    "support-report never invokes the customizable name selector"
  )
  check(
    report?.terminalOutput.contains("Custom Owner Name") == false,
    "support-report output never contains the customizable name"
  )
  check(!device.canSetListeningMode(), "support-report fixture exposes no mode setter")
  check(
    !device.canSetConversationAwareness(),
    "support-report fixture exposes no Conversation Awareness setter"
  )

  let otherRawDevice = FakeSupportReportRawDevice()
  let ambiguousController = PrivateAudioController(
    rawDevices: [rawDevice, otherRawDevice],
    logger: DebugLogger(enabled: false),
    includeDeviceNames: false
  )
  check(
    ambiguousController.selectDevice(named: nil) == nil,
    "name-free support-report selection requires one unique compatible device"
  )
  check(
    rawDevice.nameReadCount == 0 && otherRawDevice.nameReadCount == 0,
    "rejecting multiple report devices still reads no customizable names"
  )

  let namelessController = PrivateAudioController(
    rawDevices: [FakeNamelessRawDevice()],
    logger: DebugLogger(enabled: false),
    includeDeviceNames: false
  )
  check(
    namelessController.selectDevice(named: nil) == nil,
    "support-report rejects devices that other commands cannot target"
  )
}

// support-report is the one command that resolves its device with
// includeDeviceNames: false, which is what makes --debug safe for it. Pin that
// across the whole reachable log surface — discovery, selection, the snapshot
// reads, and the write-test writes — instead of trusting the name sites in
// compatible(object:index:logger:includeDeviceName:) to stay gated.
func testSupportReportDebugStreamOmitsTheDeviceName() {
  let ownerName = "Custom Owner Name"
  let rawDevice = FakeRawDevice(
    name: ownerName,
    modelIdentifier: "BTHeadphones76,8231",
    listeningModeError: NSError(domain: ownerName, code: 73),
    conversationAwarenessError: NSError(domain: ownerName, code: 74)
  )
  var report: SupportReportDocument?

  let captured = capturingStandardError {
    guard let device = PrivateAudioController(
      rawDevices: [rawDevice],
      logger: DebugLogger(enabled: true),
      includeDeviceNames: false
    ).selectDevice(named: nil) else { return }
    report = passiveSupportReport(device: device)
    // The write tester holds each mode for two seconds and carries no logger, so
    // the wait-free overloads reach every write-path log site without the wait.
    _ = device.setListeningModeAndReadBack(.noiseCancellation, wait: { _ in })
    _ = device.setConversationAwarenessAndReadBack(true, wait: { _ in })
  }

  guard let captured else {
    check(false, "the debug stream on standard error can be captured")
    return
  }
  check(report != nil, "the captured run produced a support report")
  check(
    rawDevice.listeningModeSetCount == 1 && rawDevice.conversationAwarenessSetCount == 1,
    "the captured run reached both setters"
  )
  check(
    captured.contains("debug: device.0.compatible=true"),
    "the debug stream reaches name-free device discovery"
  )
  check(
    captured.contains("info: selected_device=\"name-not-read\""),
    "selection logs a placeholder in place of the name"
  )
  check(
    captured.contains("debug: write.listening_mode.accepted=false")
      && captured.contains("warning: write.listening_mode.error=73")
      && captured.contains("warning: write.conversation_awareness.error=74"),
    "the debug stream reaches both setter-error branches without their domains"
  )
  check(
    !captured.contains(ownerName),
    "no support-report debug line carries the customizable device name"
  )
}

func testListeningModeReadbackWaitsForDelayedTarget() {
  let off = rawListeningModeValues[.off]!
  let device = scriptedPrivateAudioDevice(
    reads: [
      rawListeningModeValues[.noiseCancellation]!,
      rawListeningModeValues[.noiseCancellation]!,
      off,
    ]
  )

  let observation = device.setListeningModeAndReadBack(.off, wait: { _ in })

  check(
    observation.observed == .off,
    "listening-mode readback waits for a delayed target"
  )
}

func testListeningModeReadbackReturnsImmediatelyForObservedTarget() {
  let adaptive = rawListeningModeValues[.adaptive]!
  let device = scriptedPrivateAudioDevice(
    reads: [adaptive],
    setterAccepted: false
  )
  var waitCount = 0

  let observation = device.setListeningModeAndReadBack(.adaptive) { _ in waitCount += 1 }

  check(
    observation.observed == .adaptive,
    "observed target is authoritative when the setter rejects"
  )
  check(!observation.setterAccepted, "readback preserves setter rejection")
  check(waitCount == 0, "observed target returns without waiting")
}

func testListeningModeReadbackReturnsFinalFallback() {
  let noiseCancellation = rawListeningModeValues[.noiseCancellation]!
  let transparency = rawListeningModeValues[.transparency]!
  let device = scriptedPrivateAudioDevice(
    reads: [noiseCancellation, transparency]
      + Array(repeating: noiseCancellation, count: 18)
      + [transparency]
  )
  var waitCount = 0

  let observation = device.setListeningModeAndReadBack(.off) { _ in waitCount += 1 }

  check(
    observation.observed == .transparency,
    "Off returns the settled fallback mode"
  )
  check(observation.setterAccepted, "readback preserves setter acceptance")
  check(waitCount == 30, "Off readback uses its full settling window")
}

func testListeningModeReadbackReturnsUnknownOrMissingFinalState() {
  let noiseCancellation = rawListeningModeValues[.noiseCancellation]!
  let unknown = "AVOutputDeviceBluetoothListeningModeFuture"

  let unknownObserved = scriptedPrivateAudioDevice(reads: [noiseCancellation, unknown])
    .setListeningModeAndReadBack(.off, wait: { _ in })
    .observed
  check(unknownObserved == nil, "unknown final readback becomes null state")

  let missingObserved = scriptedPrivateAudioDevice(reads: [noiseCancellation, nil])
    .setListeningModeAndReadBack(.off, wait: { _ in })
    .observed
  check(missingObserved == nil, "missing final readback becomes null state")
}

func testListeningModeReadbackPreservesDelayedNonOffModes() {
  let device = scriptedPrivateAudioDevice(
    reads: [
      rawListeningModeValues[.transparency]!,
      rawListeningModeValues[.adaptive]!,
    ]
  )

  let observation = device.setListeningModeAndReadBack(.adaptive, wait: { _ in })

  check(
    observation.observed == .adaptive,
    "non-Off modes retain delayed readback verification"
  )
}

func testNonOffReadbackRetainsStandardTimeout() {
  let transparency = rawListeningModeValues[.transparency]!
  let device = scriptedPrivateAudioDevice(reads: [transparency])
  var waitCount = 0

  let observation = device.setListeningModeAndReadBack(.adaptive) { _ in waitCount += 1 }

  check(
    observation.observed == .transparency,
    "timed-out non-Off returns the final observed mode"
  )
  check(waitCount == 16, "non-Off readback retains the standard timeout")
}

func testListeningModeReadbackProcessesAsyncDeviceUpdates() {
  let rawDevice = FakeRawDevice(
    name: "Async AirPods",
    mode: rawListeningModeValues[.noiseCancellation]!,
    appliesListeningModeAsynchronously: true
  )
  let device = privateAudioDevice(rawDevice)

  let observation = device.setListeningModeAndReadBack(.transparency)

  check(
    observation.observed == .transparency,
    "readback processes asynchronous device updates"
  )
}

func testConversationAwarenessReadbackPolicy() {
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

  check(unchanged.setterAccepted, "Conversation Awareness preserves setter acceptance")
  check(unchanged.observed == false, "Conversation Awareness returns final observed state")
  check(waitCount == 16, "Conversation Awareness uses the standard settling window")

  let changedRawDevice = FakeRawDevice(
    name: "Changed Awareness AirPods",
    conversationAwarenessEnabled: false
  )
  let changedDevice = privateAudioDevice(changedRawDevice)
  let changed = changedDevice.setConversationAwarenessAndReadBack(true, wait: { _ in })

  check(changed.observed == true, "Conversation Awareness returns an applied write")
  check(
    changedRawDevice.conversationAwarenessSetCount == 1,
    "Conversation Awareness invokes the private setter once"
  )
}

func testDeviceSelectionAndCapabilities() {
  let logger = DebugLogger(enabled: false)
  let first = FakeRawDevice(name: "My AirPods Pro")
  let second = FakeRawDevice(name: "Studio AirPods")
  let controller = PrivateAudioController(rawDevices: [first, second], logger: logger)

  check(
    controller.selectDevice(named: nil)?.name == "My AirPods Pro",
    "default selection uses the first compatible device"
  )
  check(
    controller.selectDevice(named: "MY AIRPODS PRO")?.name == "My AirPods Pro",
    "device matching is case-insensitive and exact"
  )
  check(
    controller.selectDevice(named: "My") == nil,
    "device matching does not use substrings"
  )
  check(
    controller.selectDevice(named: "Missing AirPods") == nil,
    "device matching never falls back"
  )

  let duplicate = FakeRawDevice(name: "MY AIRPODS PRO")
  let ambiguous = PrivateAudioController(rawDevices: [first, duplicate], logger: logger)
  check(
    ambiguous.selectDevice(named: "My AirPods Pro") == nil,
    "duplicate exact names are rejected"
  )

  let incomplete = FakeIncompleteRawDevice()
  let filtered = PrivateAudioController(rawDevices: [incomplete, second], logger: logger)
  check(
    filtered.selectDevice(named: nil)?.name == "Studio AirPods",
    "devices missing a core selector are ignored"
  )

  let readOnly = FakeReadOnlyRawDevice(name: "Read-only AirPods")
  let readOnlyController = PrivateAudioController(rawDevices: [readOnly], logger: logger)
  let selectedReadOnly = readOnlyController.selectDevice(named: nil)
  check(selectedReadOnly != nil, "read-only device remains available for reads")
  check(selectedReadOnly?.canSetListeningMode() == false, "missing mode setter is detected")
  check(
    selectedReadOnly?.supportsConversationAwareness() == nil,
    "missing Conversation Awareness selector is detected"
  )

  let selected = controller.selectDevice(named: "Studio AirPods")!
  let reportMetadata = selected.supportReportMetadata()
  check(reportMetadata.family == .airPods, "report identifies AirPods from model metadata")
  check(
    reportMetadata.modelIdentifier == "AirPodsTest1,1",
    "report reads the allowlisted model identifier"
  )
  check(
    reportMetadata.unrecognizedListeningModes.isEmpty,
    "all-known advertised modes leave nothing unrecognized"
  )
  check(
    reportMetadata.listeningModeQueryAnswered,
    "an answering mode query is recorded for the report"
  )
  check(selected.canSetListeningMode(), "mode setter capability is detected")
  _ = selected.setListeningModeAndReadBack(.adaptive, wait: { _ in })
  check(
    selected.currentListeningMode() == .adaptive,
    "mode setter is invoked after capability checking"
  )
  check(selected.supportsConversationAwareness() == true, "CA support is read")
  _ = selected.setConversationAwarenessAndReadBack(true, wait: { _ in })
  check(selected.conversationAwarenessState() == true, "CA setter and state are invoked safely")
}

func testSupportReportMetadataForUnrecognizedModes() {
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
  check(
    metadata.unrecognizedListeningModes
      == ["AVOutputDeviceBluetoothListeningModeHearingAid"],
    "an unknown advertised mode is carried into the report metadata"
  )
  check(
    metadata.listeningModeQueryAnswered,
    "an unmapped current mode still counts as an answered query"
  )
  check(
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
  check(report != nil, "a device advertising only unknown modes still reports")
  check(
    cliOutput.contains("Listening modes          Unavailable / not reported"),
    "unknown-only advertised modes leave the known list empty"
  )
  check(
    cliOutput.contains(
      "Other modes              AVOutputDeviceBluetoothListeningModeFuture"
    ),
    "unknown-only advertised modes are still reported verbatim"
  )
  check(
    cliOutput.contains("Mode query               Available · unrecognized mode"),
    "an unmapped current mode is distinguished in the report"
  )
}

func runPrivateAudioTests() {
  testPrivateSelectorDiscovery()
  testPrivateListeningModeTranslation()
  testSupportReportDiscoveryDoesNotReadDeviceNames()
  testSupportReportMetadataForUnrecognizedModes()
  testSupportReportDebugStreamOmitsTheDeviceName()
  testListeningModeReadbackWaitsForDelayedTarget()
  testListeningModeReadbackReturnsImmediatelyForObservedTarget()
  testListeningModeReadbackReturnsFinalFallback()
  testListeningModeReadbackReturnsUnknownOrMissingFinalState()
  testListeningModeReadbackPreservesDelayedNonOffModes()
  testNonOffReadbackRetainsStandardTimeout()
  testListeningModeReadbackProcessesAsyncDeviceUpdates()
  testConversationAwarenessReadbackPolicy()
  testDeviceSelectionAndCapabilities()
}
