import Foundation

private var failureCount = 0

private func check(_ condition: @autoclosure () -> Bool, _ description: String) {
  if !condition() {
    fputs("FAIL: \(description)\n", stderr)
    failureCount += 1
  }
}

private func expectParseFailure(_ args: [String], _ description: String) {
  do {
    _ = try parseInvocation(args)
    check(false, description)
  } catch {
    check(true, description)
  }
}

@objc private final class FakeContext: NSObject {
  let devices: [AnyObject]

  init(devices: [AnyObject]) {
    self.devices = devices
  }

  @objc(outputDevices) func outputDeviceValues() -> [AnyObject] {
    devices
  }
}

@objc private final class FakeLegacyContextProvider: NSObject {
  let context: AnyObject

  init(context: AnyObject) {
    self.context = context
  }

  @objc(sharedSystemAudio) func legacyContext() -> AnyObject {
    context
  }
}

@objc private final class FakeDualContextProvider: NSObject {
  let modernContext: AnyObject
  let legacyContextValue: AnyObject

  init(modern: AnyObject, legacy: AnyObject) {
    modernContext = modern
    legacyContextValue = legacy
  }

  @objc(sharedSystemAudioContext) func modernContextValue() -> AnyObject {
    modernContext
  }

  @objc(sharedSystemAudio) func legacyContext() -> AnyObject {
    legacyContextValue
  }
}

@objc private final class FakeDevice: NSObject {
  let outputName: String
  let modes: [String]
  var mode: String
  let conversationAwarenessSupported: Bool
  var conversationAwarenessEnabled: Bool

  init(
    name: String,
    modes: [String] = Array(tokenToAV.values),
    mode: String = tokenToAV["transparency"]!,
    conversationAwarenessSupported: Bool = true,
    conversationAwarenessEnabled: Bool = false
  ) {
    outputName = name
    self.modes = modes
    self.mode = mode
    self.conversationAwarenessSupported = conversationAwarenessSupported
    self.conversationAwarenessEnabled = conversationAwarenessEnabled
  }

  @objc(name) func deviceName() -> String {
    outputName
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    modes
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String {
    mode
  }

  @objc(setCurrentBluetoothListeningMode:error:)
  func setListeningMode(_ newMode: String, _ error: NSErrorPointer) -> Bool {
    mode = newMode
    return true
  }

  @objc(supportsConversationDetection) func supportsConversationDetection() -> Bool {
    conversationAwarenessSupported
  }

  @objc(isConversationDetectionEnabled) func isConversationDetectionEnabled() -> Bool {
    conversationAwarenessEnabled
  }

  @objc(setConversationDetectionEnabled:error:)
  func setConversationDetectionEnabled(_ enabled: Bool, _ error: NSErrorPointer) -> Bool {
    conversationAwarenessEnabled = enabled
    return true
  }
}

@objc private final class FakeReadOnlyDevice: NSObject {
  let outputName: String

  init(name: String) {
    outputName = name
  }

  @objc(name) func deviceName() -> String {
    outputName
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    Array(tokenToAV.values)
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String {
    tokenToAV["transparency"]!
  }
}

@objc private final class FakeIncompleteDevice: NSObject {
  @objc(name) func deviceName() -> String {
    "Incomplete AirPods"
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    Array(tokenToAV.values)
  }
}

private func testCLIParsing() {
  let aliases = [
    ("anc", "noise-cancellation"),
    ("nc", "noise-cancellation"),
    ("trans", "transparency"),
    ("automatic", "adaptive"),
    ("auto", "adaptive"),
  ]

  for (alias, expected) in aliases {
    do {
      let invocation = try parseInvocation(["lm", "set", alias])
      if case let .listeningModeSet(token, avMode) = invocation.command {
        check(token == expected, "alias \(alias) canonicalizes to \(expected)")
        check(avMode == tokenToAV[expected], "alias \(alias) maps to the canonical AV mode")
      } else {
        check(false, "alias \(alias) parses as listening-mode set")
      }
    } catch {
      check(false, "alias \(alias) parses successfully")
    }
  }

  expectParseFailure(["lm", "set", "normal"], "off has no alias")

  do {
    let invocation = try parseInvocation([
      "--debug", "lm", "--device", "RAUL’S AIRPODS PRO", "get", "--json",
    ])
    check(invocation.debugEnabled, "--debug is accepted anywhere")
    check(invocation.jsonOutput, "--json is accepted anywhere")
    check(
      invocation.requestedDeviceName == "RAUL’S AIRPODS PRO",
      "--device preserves the requested name"
    )
  } catch {
    check(false, "mixed global flag placement parses")
  }

  expectParseFailure(["--device", "A", "--device", "B", "lm", "get"], "duplicate device")
  expectParseFailure(["lm", "get", "--device"], "missing device name")
  expectParseFailure(["--debug", "--debug", "lm", "get"], "duplicate debug")
  expectParseFailure(["--device", "AirPods", "version"], "device is invalid for version")
}

private func testResourcePayloads() {
  let listeningMode = makeResourcePayload(
    resource: .listeningMode,
    deviceName: "Raul’s AirPods Pro",
    result: "ok",
    state: "transparency",
    extra: ["supportedListeningModes": ["transparency", "noise-cancellation"]]
  )
  check(listeningMode["device"] as? String == "Raul’s AirPods Pro", "payload has device")
  check(listeningMode["result"] as? String == "ok", "payload has result")
  check(
    listeningMode["listeningMode"] as? String == "transparency",
    "listening-mode payload has post-command state"
  )
  check(
    listeningMode["supportedListeningModes"] as? [String]
      == ["transparency", "noise-cancellation"],
    "list payload has supportedListeningModes"
  )
  check(listeningMode["error"] == nil, "successful payload omits error")

  let listeningModeNoOp = makeResourcePayload(
    resource: .listeningMode,
    deviceName: "Raul’s AirPods Pro",
    result: "no-op",
    state: "transparency"
  )
  check(
    listeningModeNoOp["listeningMode"] as? String == "transparency",
    "no-op payload has the observed post-command listening mode"
  )
  check(listeningModeNoOp["result"] as? String == "no-op", "no-op payload has result")

  let noDevice = makeResourcePayload(
    resource: .conversationAwareness,
    deviceName: nil,
    result: "error",
    state: nil,
    error: "no-device"
  )
  check(noDevice["device"] is NSNull, "missing device is JSON null")
  check(
    noDevice["conversationAwareness"] is NSNull,
    "unavailable resource state is JSON null"
  )
  check(noDevice["error"] as? String == "no-device", "failure payload has optional error")
}

private func testListeningModeSetState() {
  let off = tokenToAV["off"]!
  let transparency = tokenToAV["transparency"]!
  let noiseCancellation = tokenToAV["noise-cancellation"]!

  check(
    listeningModeStateAfterSet(
      requestedToken: "off",
      setterAccepted: true,
      observedRawMode: off
    ) == "off",
    "successful Off readback is reported as off"
  )
  check(
    listeningModeStateAfterSet(
      requestedToken: "off",
      setterAccepted: true,
      observedRawMode: noiseCancellation
    ) == "transparency",
    "accepted Off no-op infers the Transparency fallback"
  )
  check(
    listeningModeStateAfterSet(
      requestedToken: "off",
      setterAccepted: false,
      observedRawMode: noiseCancellation
    ) == "noise-cancellation",
    "rejected Off write preserves the observed mode"
  )
  check(
    listeningModeStateAfterSet(
      requestedToken: "off",
      setterAccepted: true,
      observedRawMode: nil
    ) == nil,
    "missing Off readback is not inferred"
  )
  check(
    listeningModeStateAfterSet(
      requestedToken: "noise-cancellation",
      setterAccepted: true,
      observedRawMode: transparency
    ) == "transparency",
    "other modes always report their observed state"
  )
}

private func testPrivateSelectorDiscovery() {
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

  let device = FakeDevice(name: "Raul’s AirPods Pro")
  let context = FakeContext(devices: [device])
  let outputDevices = PrivateAudioDiscovery.outputDevices(from: context, logger: logger)
  check(outputDevices?.count == 1, "outputDevices is discovered safely")
}

private func testDeviceSelectionAndCapabilities() {
  let logger = DebugLogger(enabled: false)
  let first = FakeDevice(name: "Raul’s AirPods Pro")
  let second = FakeDevice(name: "Studio AirPods")
  let controller = PrivateAudioController(rawDevices: [first, second], logger: logger)

  check(
    controller.selectDevice(named: nil)?.name == "Raul’s AirPods Pro",
    "default selection uses the first compatible device"
  )
  check(
    controller.selectDevice(named: "RAUL’S AIRPODS PRO")?.name == "Raul’s AirPods Pro",
    "device matching is case-insensitive and exact"
  )
  check(
    controller.selectDevice(named: "Raul") == nil,
    "device matching does not use substrings"
  )
  check(
    controller.selectDevice(named: "Missing AirPods") == nil,
    "device matching never falls back"
  )

  let duplicate = FakeDevice(name: "RAUL’S AIRPODS PRO")
  let ambiguous = PrivateAudioController(rawDevices: [first, duplicate], logger: logger)
  check(
    ambiguous.selectDevice(named: "Raul’s AirPods Pro") == nil,
    "duplicate exact names are rejected"
  )

  let incomplete = FakeIncompleteDevice()
  let filtered = PrivateAudioController(rawDevices: [incomplete, second], logger: logger)
  check(
    filtered.selectDevice(named: nil)?.name == "Studio AirPods",
    "devices missing a core selector are ignored"
  )

  let readOnly = FakeReadOnlyDevice(name: "Read-only AirPods")
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
  _ = selected.setListeningMode(tokenToAV["adaptive"]!)
  check(
    selected.currentListeningMode() == tokenToAV["adaptive"],
    "mode setter is invoked after capability checking"
  )
  check(selected.supportsConversationAwareness() == true, "CA support is read")
  _ = selected.setConversationAwareness(true)
  check(selected.conversationAwarenessState() == true, "CA setter and state are invoked safely")
}

@main
private struct SwiftTests {
  static func main() {
    testCLIParsing()
    testResourcePayloads()
    testListeningModeSetState()
    testPrivateSelectorDiscovery()
    testDeviceSelectionAndCapabilities()

    if failureCount > 0 {
      fputs("Swift tests failed: \(failureCount)\n", stderr)
      exit(1)
    }
    print("Swift selector and parser tests passed")
  }
}
