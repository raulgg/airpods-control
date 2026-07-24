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

func runPrivateAudioTests() {
  testPrivateSelectorDiscovery()
  testPrivateListeningModeTranslation()
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
