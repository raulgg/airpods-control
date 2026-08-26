import Foundation

func testCommandExecutionLifecycleAndNoDeviceOutcomes() {
  let versionInvocation = try! parseInvocation(["version"])
  var resolverCallCount = 0
  let version = CommandExecution.execute(versionInvocation) { _, _ in
    resolverCallCount += 1
    return nil
  }
  check(resolverCallCount == 0, "version does not resolve a device")
  check(version.plain == VERSION, "version outcome has plain version")
  check(version.exitCode == 0, "version outcome succeeds")
  check(version.payload["result"] as? String == "ok", "version payload succeeds")
  check(version.payload["version"] as? String == VERSION, "version payload has version")

  let namedInvocation = try! parseInvocation(["--device", "Studio AirPods", "lm", "get"])
  var capturedName: String?
  var capturedLoggerEnabled = true
  resolverCallCount = 0
  let noDevice = CommandExecution.execute(namedInvocation) { name, logger in
    resolverCallCount += 1
    capturedName = name
    capturedLoggerEnabled = logger.enabled
    return nil
  }
  check(resolverCallCount == 1, "resource command resolves a device exactly once")
  check(capturedName == "Studio AirPods", "execution forwards the requested device name")
  check(!capturedLoggerEnabled, "execution forwards its configured logger")
  check(noDevice.plain == "no-device", "missing device has plain no-device")
  check(noDevice.exitCode == 1, "missing device exits one")
  check(noDevice.payload["device"] is NSNull, "missing device is JSON null")
  check(noDevice.payload["listeningMode"] is NSNull, "missing listening mode is JSON null")
  check(noDevice.payload["result"] as? String == "error", "missing device is an error")
  check(noDevice.payload["error"] as? String == "no-device", "missing device has error")

  let listInvocation = try! parseInvocation(["lm", "list"])
  let noDeviceList = CommandExecution.execute(listInvocation) { _, _ in nil }
  check(
    noDeviceList.payload["supportedListeningModes"] as? [String] == [],
    "missing-device list has an empty supported mode list"
  )

  let awarenessInvocation = try! parseInvocation(["ca", "get"])
  let noDeviceAwareness = CommandExecution.execute(awarenessInvocation) { _, _ in nil }
  check(
    noDeviceAwareness.payload["conversationAwareness"] is NSNull,
    "missing Conversation Awareness state is JSON null"
  )
  check(
    noDeviceAwareness.payload["listeningMode"] == nil,
    "Conversation Awareness payload omits listening mode"
  )

  let reportInvocation = try! parseInvocation(["support-report"])
  let noDeviceReport = CommandExecution.execute(reportInvocation) { _, _ in nil }
  check(noDeviceReport.exitCode == 1, "missing support-report device exits one")
  check(
    noDeviceReport.plain.contains(
      "Connect exactly one compatible AirPods or Beats device"
    ),
    "support-report requires an unambiguous privacy-preserving target"
  )
  check(noDeviceReport.supportReportIssueDraft == nil, "missing device does not offer issue creation")
}

func testListeningModeCommandExecution() {
  let knownDevice = FakeCompatibleAudioDevice(
    name: "Known AirPods",
    listeningMode: .transparency
  )
  let known = commandOutcome(["lm", "get"], device: knownDevice)
  check(known.plain == "transparency", "listening-mode get returns the current mode")
  check(known.exitCode == 0, "listening-mode get succeeds")
  check(known.payload["device"] as? String == "Known AirPods", "get payload has device")
  check(
    known.payload["listeningMode"] as? String == "transparency",
    "get payload has current mode"
  )
  check(known.payload["error"] == nil, "successful get omits error")

  let unknown = commandOutcome(
    ["lm", "get"],
    device: FakeCompatibleAudioDevice(name: "Future AirPods", listeningMode: nil)
  )
  check(unknown.plain == "unknown", "unknown listening mode has plain fallback")
  check(unknown.payload["listeningMode"] is NSNull, "unknown listening mode is JSON null")

  let listDevice = FakeCompatibleAudioDevice(
    name: "Subset AirPods",
    listeningModes: [.noiseCancellation, .transparency],
    listeningMode: .noiseCancellation
  )
  let list = commandOutcome(["lm", "list"], device: listDevice)
  check(
    list.plain == "transparency,noise-cancellation",
    "listening-mode list uses canonical order"
  )
  check(
    list.payload["supportedListeningModes"] as? [String]
      == ["transparency", "noise-cancellation"],
    "list payload has supported modes"
  )
  check(
    list.payload["listeningMode"] as? String == "noise-cancellation",
    "list payload has current mode"
  )

  let unsupportedDevice = FakeCompatibleAudioDevice(
    name: "Limited AirPods",
    listeningModes: [.transparency],
    listeningMode: .transparency
  )
  let unsupported = commandOutcome(["lm", "set", "adaptive"], device: unsupportedDevice)
  check(unsupported.plain == "unsupported", "unavailable listening mode is unsupported")
  check(unsupported.exitCode == 4, "unsupported listening mode exits four")
  check(unsupported.payload["result"] as? String == "error", "unsupported set is an error")
  check(
    unsupported.payload["listeningMode"] as? String == "transparency",
    "unsupported set preserves current mode"
  )
  check(unsupported.payload["error"] as? String == "unsupported", "unsupported set has error")

  let currentDevice = FakeCompatibleAudioDevice(
    name: "Current AirPods",
    listeningMode: .adaptive
  )
  let current = commandOutcome(["lm", "set", "adaptive"], device: currentDevice)
  check(current.plain == "ok", "setting the current mode succeeds")
  check(current.exitCode == 0, "setting the current mode exits zero")
  check(currentDevice.listeningModeSetCount == 0, "idempotent set skips the setter")

  let changedDevice = FakeCompatibleAudioDevice(
    name: "Changed AirPods",
    listeningMode: .transparency
  )
  let changed = commandOutcome(["lm", "set", "adaptive"], device: changedDevice)
  check(changed.plain == "ok", "verified listening-mode change succeeds")
  check(changed.exitCode == 0, "verified listening-mode change exits zero")
  check(
    changed.payload["listeningMode"] as? String == "adaptive",
    "verified change reports observed mode"
  )
  check(changedDevice.listeningMode == .adaptive, "verified change mutates the device")
  check(changedDevice.listeningModeSetCount == 1, "verified change invokes the setter once")

  let unchangedDevice = FakeCompatibleAudioDevice(
    name: "Unchanged AirPods",
    listeningMode: .transparency,
    appliesListeningModeWrite: false
  )
  let unchanged = commandOutcome(["lm", "set", "adaptive"], device: unchangedDevice)
  check(unchanged.plain == "no-op", "unverified listening-mode change is a no-op")
  check(unchanged.exitCode == 3, "unverified listening-mode change exits three")
  check(unchanged.payload["result"] as? String == "no-op", "no-op payload has result")
  check(
    unchanged.payload["listeningMode"] as? String == "transparency",
    "no-op payload has observed mode"
  )
  check(unchanged.payload["error"] == nil, "no-op payload omits error")
}

func testListeningModeCycleCommandExecution() {
  let defaultDevice = FakeCompatibleAudioDevice(
    name: "Cycle AirPods",
    listeningMode: .transparency
  )
  let defaultCycle = commandOutcome(["lm", "cycle"], device: defaultDevice)
  check(defaultCycle.plain == "adaptive", "default cycle advances to Adaptive")
  check(defaultCycle.exitCode == 0, "verified cycle exits zero")
  check(
    defaultCycle.payload["listeningMode"] as? String == "adaptive",
    "cycle payload has target mode"
  )
  check(defaultDevice.listeningMode == .adaptive, "cycle mutates the device")
  check(
    defaultCycle.payload["supportedListeningModes"] == nil,
    "cycle payload omits supported mode list"
  )

  let explicitDevice = FakeCompatibleAudioDevice(
    name: "Explicit Cycle AirPods",
    listeningMode: .transparency
  )
  let explicitCycle = commandOutcome(
    ["lm", "cycle", "--modes", "transparency,noise-cancellation"],
    device: explicitDevice
  )
  check(
    explicitCycle.plain == "noise-cancellation",
    "explicit cycle advances within its selected modes"
  )
  check(
    explicitDevice.listeningMode == .noiseCancellation,
    "explicit cycle applies its target"
  )

  let limitedDevice = FakeCompatibleAudioDevice(
    name: "Limited Cycle AirPods",
    listeningModes: [.transparency],
    listeningMode: .transparency
  )
  let unsupported = commandOutcome(["lm", "cycle"], device: limitedDevice)
  check(unsupported.plain == "unsupported", "cycle with fewer than two modes is unsupported")
  check(unsupported.exitCode == 4, "unsupported cycle exits four")
  check(
    unsupported.payload["listeningMode"] as? String == "transparency",
    "unsupported cycle preserves current mode"
  )
  check(unsupported.payload["error"] as? String == "unsupported", "unsupported cycle has error")

  let unchangedDevice = FakeCompatibleAudioDevice(
    name: "Unchanged Cycle AirPods",
    listeningMode: .transparency,
    appliesListeningModeWrite: false
  )
  let unchanged = commandOutcome(["lm", "cycle"], device: unchangedDevice)
  check(unchanged.plain == "no-op", "unverified cycle is a no-op")
  check(unchanged.exitCode == 3, "unverified cycle exits three")
  check(unchanged.payload["result"] as? String == "no-op", "cycle no-op payload has result")
  check(
    unchanged.payload["listeningMode"] as? String == "transparency",
    "cycle no-op payload has observed mode"
  )
}

func testConversationAwarenessCommandExecution() {
  let offDevice = FakeCompatibleAudioDevice(
    name: "Awareness AirPods",
    conversationAwarenessEnabled: false
  )
  let get = commandOutcome(["ca", "get"], device: offDevice)
  check(get.plain == "off", "Conversation Awareness get returns state")
  check(get.exitCode == 0, "Conversation Awareness get succeeds")
  check(
    get.payload["conversationAwareness"] as? String == "off",
    "Conversation Awareness payload has state"
  )

  let unsupportedDevice = FakeCompatibleAudioDevice(
    name: "Unsupported Awareness AirPods",
    conversationAwarenessSupported: false
  )
  let unsupported = commandOutcome(["ca", "get"], device: unsupportedDevice)
  check(unsupported.plain == "unsupported", "unsupported Conversation Awareness is reported")
  check(unsupported.exitCode == 4, "unsupported Conversation Awareness exits four")
  check(
    unsupported.payload["conversationAwareness"] is NSNull,
    "unsupported Conversation Awareness state is JSON null"
  )
  check(
    unsupported.payload["error"] as? String == "unsupported",
    "unsupported Conversation Awareness has error"
  )
  let unsupportedSet = commandOutcome(["ca", "set", "on"], device: unsupportedDevice)
  check(
    unsupportedSet.plain == "unsupported",
    "unsupported Conversation Awareness set is reported"
  )
  check(unsupportedSet.exitCode == 4, "unsupported Conversation Awareness set exits four")

  let currentDevice = FakeCompatibleAudioDevice(
    name: "Current Awareness AirPods",
    conversationAwarenessEnabled: true
  )
  let current = commandOutcome(["ca", "set", "on"], device: currentDevice)
  check(current.plain == "ok", "setting current Conversation Awareness state succeeds")
  check(
    currentDevice.conversationAwarenessSetCount == 0,
    "idempotent Conversation Awareness set skips the setter"
  )

  let changedDevice = FakeCompatibleAudioDevice(
    name: "Changed Awareness AirPods",
    conversationAwarenessEnabled: false
  )
  let changed = commandOutcome(["ca", "set", "on"], device: changedDevice)
  check(changed.plain == "ok", "verified Conversation Awareness change succeeds")
  check(changed.exitCode == 0, "verified Conversation Awareness change exits zero")
  check(
    changed.payload["conversationAwareness"] as? String == "on",
    "verified Conversation Awareness change reports observed state"
  )
  check(changedDevice.conversationAwarenessEnabled == true, "Conversation Awareness mutates")
  check(
    changedDevice.conversationAwarenessSetCount == 1,
    "Conversation Awareness change invokes the setter once"
  )

  let unchangedDevice = FakeCompatibleAudioDevice(
    name: "Unchanged Awareness AirPods",
    conversationAwarenessEnabled: false,
    appliesConversationAwarenessWrite: false
  )
  let unchanged = commandOutcome(["ca", "set", "on"], device: unchangedDevice)
  check(unchanged.plain == "no-op", "unverified Conversation Awareness change is a no-op")
  check(unchanged.exitCode == 3, "unverified Conversation Awareness change exits three")
  check(
    unchanged.payload["conversationAwareness"] as? String == "off",
    "Conversation Awareness no-op reports observed state"
  )
  check(unchanged.payload["result"] as? String == "no-op", "Conversation Awareness no-op result")
  check(unchanged.payload["error"] == nil, "Conversation Awareness no-op omits error")
}

func runCommandExecutionTests() {
  testCommandExecutionLifecycleAndNoDeviceOutcomes()
  testListeningModeCommandExecution()
  testListeningModeCycleCommandExecution()
  testConversationAwarenessCommandExecution()
}
