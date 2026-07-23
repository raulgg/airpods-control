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
  let appliesListeningModeAsynchronously: Bool

  init(
    name: String,
    modes: [String] = Array(tokenToAV.values),
    mode: String = tokenToAV["transparency"]!,
    conversationAwarenessSupported: Bool = true,
    conversationAwarenessEnabled: Bool = false,
    appliesListeningModeAsynchronously: Bool = false
  ) {
    outputName = name
    self.modes = modes
    self.mode = mode
    self.conversationAwarenessSupported = conversationAwarenessSupported
    self.conversationAwarenessEnabled = conversationAwarenessEnabled
    self.appliesListeningModeAsynchronously = appliesListeningModeAsynchronously
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
    if appliesListeningModeAsynchronously {
      DispatchQueue.main.async { self.mode = newMode }
    } else {
      mode = newMode
    }
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

@objc private final class FakeScriptedListeningModeDevice: NSObject {
  let reads: [String?]
  let setterAccepted: Bool
  var readIndex = 0

  init(reads: [String?], setterAccepted: Bool = true) {
    precondition(!reads.isEmpty)
    self.reads = reads
    self.setterAccepted = setterAccepted
  }

  @objc(name) func deviceName() -> String {
    "Scripted AirPods"
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    Array(tokenToAV.values)
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String? {
    let index = min(readIndex, reads.count - 1)
    readIndex += 1
    return reads[index]
  }

  @objc(setCurrentBluetoothListeningMode:error:)
  func setListeningMode(_ newMode: String, _ error: NSErrorPointer) -> Bool {
    setterAccepted
  }
}

private func scriptedAudioDevice(
  reads: [String?],
  setterAccepted: Bool = true
) -> AudioDevice {
  let rawDevice = FakeScriptedListeningModeDevice(
    reads: reads,
    setterAccepted: setterAccepted
  )
  let controller = PrivateAudioController(
    rawDevices: [rawDevice],
    logger: DebugLogger(enabled: false)
  )
  return controller.selectDevice(named: nil)!
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

private func testCycleParsing() {
  do {
    let invocation = try parseInvocation(["lm", "cycle"])
    if case let .listeningModeCycle(requested) = invocation.command {
      check(requested == nil, "bare cycle uses the default cycle set")
    } else {
      check(false, "bare cycle parses as listening-mode cycle")
    }
  } catch {
    check(false, "bare cycle parses successfully")
  }

  do {
    let invocation = try parseInvocation(["lm", "cycle", "--modes", "anc,trans"])
    if case let .listeningModeCycle(requested) = invocation.command {
      check(
        requested == ["transparency", "noise-cancellation"],
        "cycle modes canonicalize aliases and sort into canonical order"
      )
    } else {
      check(false, "cycle with --modes parses as listening-mode cycle")
    }
  } catch {
    check(false, "cycle with aliased modes parses successfully")
  }

  do {
    let invocation = try parseInvocation(
      ["lm", "cycle", "--modes", "noise-cancellation,off,transparency"]
    )
    if case let .listeningModeCycle(requested) = invocation.command {
      check(
        requested == ["off", "transparency", "noise-cancellation"],
        "off sorts first in the cycle set"
      )
    } else {
      check(false, "cycle with off parses as listening-mode cycle")
    }
  } catch {
    check(false, "cycle with off parses successfully")
  }

  expectParseFailure(["lm", "cycle", "extra"], "cycle takes no positional arguments")
  expectParseFailure(["lm", "cycle", "--modes"], "missing cycle modes value")
  expectParseFailure(["lm", "cycle", "--modes", "transparency"], "one mode is not a cycle")
  expectParseFailure(
    ["lm", "cycle", "--modes", "trans,transparency"],
    "aliases dedupe before the two-mode minimum"
  )
  expectParseFailure(["lm", "cycle", "--modes", "transparency,normal"], "unknown cycle token")
  expectParseFailure(["lm", "cycle", "--modes", ",transparency,adaptive"], "empty cycle token")
  expectParseFailure(
    ["lm", "cycle", "--modes", "a,b", "--modes", "a,b"],
    "duplicate --modes flag"
  )
  expectParseFailure(["lm", "get", "--modes", "transparency,adaptive"], "modes only for cycle")
  expectParseFailure(["--modes", "transparency,adaptive", "version"], "modes invalid for version")
}

private func testNextCycleMode() {
  let all = ["off", "transparency", "adaptive", "noise-cancellation"]
  let noOff = ["transparency", "adaptive", "noise-cancellation"]

  check(
    nextCycleMode(current: "transparency", cycleTokens: noOff) == "adaptive",
    "cycle advances in canonical order"
  )
  check(
    nextCycleMode(current: "noise-cancellation", cycleTokens: noOff) == "transparency",
    "cycle wraps to the set's first mode"
  )
  check(
    nextCycleMode(current: "noise-cancellation", cycleTokens: all) == "off",
    "cycle wraps through off when it is in the set"
  )
  check(
    nextCycleMode(current: "adaptive", cycleTokens: ["transparency", "noise-cancellation"])
      == "noise-cancellation",
    "a current mode outside the set folds into canonical order"
  )
  check(
    nextCycleMode(current: "adaptive", cycleTokens: ["off", "transparency"]) == "off",
    "folding wraps past the end of the canonical order"
  )
  check(
    nextCycleMode(current: "off", cycleTokens: noOff) == "transparency",
    "cycling out of off enters the set in canonical order"
  )
  check(
    nextCycleMode(current: nil, cycleTokens: noOff) == "transparency",
    "an unknown current mode starts at the set's first mode"
  )
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
  check(listeningModeNoOp["stateSource"] == nil, "no-op payload adds no inference field")

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

private func testListeningModeCanonicalization() {
  let off = tokenToAV["off"]!
  let noiseCancellation = tokenToAV["noise-cancellation"]!

  check(
    canonicalListeningMode(off) == "off",
    "Off readback is canonicalized"
  )
  check(
    canonicalListeningMode(noiseCancellation) == "noise-cancellation",
    "observed noise cancellation is not rewritten"
  )
  check(
    canonicalListeningMode("AVOutputDeviceBluetoothListeningModeFuture") == nil,
    "unknown readback is not invented"
  )
  check(
    canonicalListeningMode(nil) == nil,
    "missing readback is not invented"
  )
}

private func testObservedOffFallbackResolution() {
  let resolution = resolveListeningModeWrite(
    requestedToken: "off",
    setterAccepted: true,
    observedRawMode: tokenToAV["transparency"],
    transparencySupported: true
  )

  check(resolution.state == "transparency", "observed Off fallback reports Transparency")
  check(!resolution.inferredOffFallback, "observed Off fallback is not inferred")
}

private func testOffFallbackResolutionBoundaries() {
  let adaptive = tokenToAV["adaptive"]!
  let noiseCancellation = tokenToAV["noise-cancellation"]!
  let off = tokenToAV["off"]!
  let unknown = "AVOutputDeviceBluetoothListeningModeFuture"
  let inferenceCases: [(String, String?)] = [
    ("noise cancellation", noiseCancellation),
    ("Adaptive", adaptive),
    ("unknown", unknown),
    ("missing", nil),
  ]

  let verified = resolveListeningModeWrite(
    requestedToken: "off",
    setterAccepted: false,
    observedRawMode: off,
    transparencySupported: true
  )
  check(verified.verified, "observed Off verifies regardless of setter result")
  check(verified.state == "off", "verified Off reports Off")
  check(!verified.inferredOffFallback, "verified Off is not inferred")

  for (description, observed) in inferenceCases {
    let inferred = resolveListeningModeWrite(
      requestedToken: "off",
      setterAccepted: true,
      observedRawMode: observed,
      transparencySupported: true
    )
    check(!inferred.verified, "accepted Off does not verify \(description)")
    check(inferred.state == "transparency", "accepted Off infers \(description) fallback")
    check(inferred.inferredOffFallback, "accepted Off marks \(description) inference")
  }

  let rejected = resolveListeningModeWrite(
    requestedToken: "off",
    setterAccepted: false,
    observedRawMode: noiseCancellation,
    transparencySupported: true
  )
  check(rejected.state == "noise-cancellation", "rejected Off preserves observed state")
  check(!rejected.inferredOffFallback, "rejected Off is not inferred")

  let rejectedUnknown = resolveListeningModeWrite(
    requestedToken: "off",
    setterAccepted: false,
    observedRawMode: unknown,
    transparencySupported: true
  )
  check(rejectedUnknown.state == nil, "rejected Off preserves unknown state as null")

  let unsupported = resolveListeningModeWrite(
    requestedToken: "off",
    setterAccepted: true,
    observedRawMode: noiseCancellation,
    transparencySupported: false
  )
  check(unsupported.state == "noise-cancellation", "unsupported fallback preserves state")
  check(!unsupported.inferredOffFallback, "unsupported fallback is not inferred")

  let nonOff = resolveListeningModeWrite(
    requestedToken: "adaptive",
    setterAccepted: true,
    observedRawMode: noiseCancellation,
    transparencySupported: true
  )
  check(nonOff.state == "noise-cancellation", "non-Off preserves observed state")
  check(!nonOff.inferredOffFallback, "non-Off writes never infer Transparency")
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

private func testListeningModeReadbackWaitsForDelayedTarget() {
  let off = tokenToAV["off"]!
  let device = scriptedAudioDevice(
    reads: [tokenToAV["noise-cancellation"]!, tokenToAV["noise-cancellation"]!, off]
  )

  let outcome = device.setListeningModeAndReadBack(off, wait: { _ in })

  check(
    outcome.observedRawMode == off,
    "listening-mode readback waits for a delayed target"
  )
}

private func testListeningModeReadbackReturnsImmediatelyForObservedTarget() {
  let adaptive = tokenToAV["adaptive"]!
  let device = scriptedAudioDevice(
    reads: [adaptive],
    setterAccepted: false
  )
  var waitCount = 0

  let outcome = device.setListeningModeAndReadBack(adaptive) { _ in waitCount += 1 }

  check(
    outcome.observedRawMode == adaptive,
    "observed target is authoritative when the setter rejects"
  )
  check(!outcome.setterAccepted, "readback preserves setter rejection")
  check(waitCount == 0, "observed target returns without waiting")
}

private func testListeningModeReadbackReturnsFinalFallback() {
  let off = tokenToAV["off"]!
  let noiseCancellation = tokenToAV["noise-cancellation"]!
  let transparency = tokenToAV["transparency"]!
  let device = scriptedAudioDevice(
    reads: [noiseCancellation, transparency]
      + Array(repeating: noiseCancellation, count: 18)
      + [transparency]
  )
  var waitCount = 0

  let outcome = device.setListeningModeAndReadBack(off) { _ in waitCount += 1 }

  check(
    outcome.observedRawMode == transparency,
    "Off returns the settled fallback mode"
  )
  check(outcome.setterAccepted, "readback preserves setter acceptance")
  check(waitCount == 30, "Off readback uses its full settling window")
}

private func testListeningModeReadbackReturnsUnknownOrMissingFinalState() {
  let off = tokenToAV["off"]!
  let noiseCancellation = tokenToAV["noise-cancellation"]!
  let unknown = "AVOutputDeviceBluetoothListeningModeFuture"

  let unknownObserved = scriptedAudioDevice(reads: [noiseCancellation, unknown])
    .setListeningModeAndReadBack(off, wait: { _ in })
    .observedRawMode
  check(
    canonicalListeningMode(unknownObserved) == nil,
    "unknown final readback becomes null state"
  )

  let missingObserved = scriptedAudioDevice(reads: [noiseCancellation, nil])
    .setListeningModeAndReadBack(off, wait: { _ in })
    .observedRawMode
  check(
    canonicalListeningMode(missingObserved) == nil,
    "missing final readback becomes null state"
  )
}

private func testListeningModeReadbackPreservesDelayedNonOffModes() {
  let adaptive = tokenToAV["adaptive"]!
  let device = scriptedAudioDevice(
    reads: [tokenToAV["transparency"]!, adaptive]
  )

  let outcome = device.setListeningModeAndReadBack(adaptive, wait: { _ in })

  check(
    outcome.observedRawMode == adaptive,
    "non-Off modes retain delayed readback verification"
  )
}

private func testNonOffReadbackRetainsStandardTimeout() {
  let adaptive = tokenToAV["adaptive"]!
  let transparency = tokenToAV["transparency"]!
  let device = scriptedAudioDevice(reads: [transparency])
  var waitCount = 0

  let outcome = device.setListeningModeAndReadBack(adaptive) { _ in waitCount += 1 }

  check(
    outcome.observedRawMode == transparency,
    "timed-out non-Off returns the final observed mode"
  )
  check(waitCount == 16, "non-Off readback retains the standard timeout")
}

private func testListeningModeReadbackProcessesAsyncDeviceUpdates() {
  let rawDevice = FakeDevice(
    name: "Async AirPods",
    mode: tokenToAV["noise-cancellation"]!,
    appliesListeningModeAsynchronously: true
  )
  let controller = PrivateAudioController(
    rawDevices: [rawDevice],
    logger: DebugLogger(enabled: false)
  )
  let device = controller.selectDevice(named: nil)!
  let transparency = tokenToAV["transparency"]!

  let outcome = device.setListeningModeAndReadBack(transparency)

  check(
    outcome.observedRawMode == transparency,
    "readback processes asynchronous device updates"
  )
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
    testCycleParsing()
    testNextCycleMode()
    testResourcePayloads()
    testListeningModeCanonicalization()
    testObservedOffFallbackResolution()
    testOffFallbackResolutionBoundaries()
    testPrivateSelectorDiscovery()
    testListeningModeReadbackWaitsForDelayedTarget()
    testListeningModeReadbackReturnsImmediatelyForObservedTarget()
    testListeningModeReadbackReturnsFinalFallback()
    testListeningModeReadbackReturnsUnknownOrMissingFinalState()
    testListeningModeReadbackPreservesDelayedNonOffModes()
    testNonOffReadbackRetainsStandardTimeout()
    testListeningModeReadbackProcessesAsyncDeviceUpdates()
    testDeviceSelectionAndCapabilities()

    if failureCount > 0 {
      fputs("Swift tests failed: \(failureCount)\n", stderr)
      exit(1)
    }
    print("Swift selector and parser tests passed")
  }
}
