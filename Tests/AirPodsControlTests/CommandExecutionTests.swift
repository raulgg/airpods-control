import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Command execution")
struct CommandExecutionTests {
  @Test("Keeps version device-free and reports typed no-device outcomes")
  func commandExecutionLifecycleAndNoDeviceOutcomes() throws {
    let versionInvocation = try parseInvocation(["version"])
    var resolverCallCount = 0
    let version = CommandExecution.execute(versionInvocation) { _, _ in
      resolverCallCount += 1
      return nil
    }
    #expect(resolverCallCount == 0, "version does not resolve a device")
    #expect(version.plain == BuildVersion.current, "version outcome has plain version")
    #expect(version.exitCode == 0, "version outcome succeeds")
    #expect(version.payload["version"] as? String == BuildVersion.current, "version payload has version")

    let namedInvocation = try parseInvocation(["--device", "Studio AirPods", "lm", "get"])
    var capturedName: String?
    var capturedLoggerEnabled = true
    resolverCallCount = 0
    let noDevice = CommandExecution.executeListeningMode(
      namedInvocation,
      resolveSession: { command, name, logger in
        resolverCallCount += 1
        capturedName = name
        capturedLoggerEnabled = logger.enabled
        guard case .get = command else {
          Issue.record("listening-mode execution must pass get")
          return .failed(.noDevice)
        }
        return .failed(.noDevice)
      }
    )
    #expect(resolverCallCount == 1, "resource command resolves a device exactly once")
    #expect(capturedName == "Studio AirPods", "execution forwards the requested device name")
    #expect(!capturedLoggerEnabled, "execution forwards its configured logger")
    #expect(noDevice.plain == "no-device", "missing device has plain no-device")
    #expect(noDevice.terminalReason == .noDevice)
    #expect(noDevice.exitCode == 1, "missing device exits one")
    #expect(noDevice.payload["device"] is NSNull, "missing device is JSON null")
    #expect(noDevice.payload["listeningMode"] is NSNull, "missing listening mode is JSON null")
    #expect(noDevice.payload["error"] as? String == "no-device", "missing device has error")

    let listInvocation = try parseInvocation(["lm", "list"])
    let noDeviceList = CommandExecution.executeListeningMode(listInvocation) { _, _, _ in
      .failed(.noDevice)
    }
    #expect(
      noDeviceList.payload["supportedListeningModes"] as? [String] == [],
      "missing-device list has an empty supported mode list"
    )

    let awarenessInvocation = try parseInvocation(["ca", "get"])
    let noDeviceAwareness = CommandExecution.execute(awarenessInvocation) { _, _ in nil }
    #expect(
      noDeviceAwareness.payload["conversationAwareness"] is NSNull,
      "missing Conversation Awareness state is JSON null"
    )
    #expect(
      noDeviceAwareness.payload["listeningMode"] == nil,
      "Conversation Awareness payload omits listening mode"
    )

    let reportInvocation = try parseInvocation(["support-report"])
    let noDeviceReport = CommandExecution.execute(reportInvocation) { _, _ in nil }
    #expect(noDeviceReport.exitCode == 1, "missing support-report device exits one")
    #expect(
      noDeviceReport.plain.contains(
        "Connect exactly one compatible AirPods or Beats device"
      ),
      "support-report requires an unambiguous privacy-preserving target"
    )
    #expect(noDeviceReport.supportReport == nil, "missing device does not offer issue creation")
  }

  @Test("Renders listening-mode reads and verified, unsupported, or no-op writes")
  func listeningModeCommandExecution() throws {
    let knownDevice = FakeCompatibleAudioDevice(
      name: "Known AirPods",
      listeningMode: .transparency
    )
    let known = try commandOutcome(["lm", "get"], device: knownDevice)
    #expect(known.plain == "transparency", "listening-mode get returns the current mode")
    #expect(known.payload["device"] as? String == "Known AirPods", "get payload has device")
    #expect(
      known.payload["listeningMode"] as? String == "transparency",
      "get payload has current mode"
    )
    let unknown = try commandOutcome(
      ["lm", "get"],
      device: FakeCompatibleAudioDevice(name: "Future AirPods", listeningMode: nil)
    )
    #expect(unknown.plain == "unknown", "unknown listening mode has plain fallback")
    #expect(unknown.payload["listeningMode"] is NSNull, "unknown listening mode is JSON null")

    let listDevice = FakeCompatibleAudioDevice(
      name: "Subset AirPods",
      listeningModes: [.noiseCancellation, .transparency],
      listeningMode: .noiseCancellation
    )
    let list = try commandOutcome(["lm", "list"], device: listDevice)
    #expect(
      list.plain == "transparency,noise-cancellation",
      "listening-mode list uses canonical order"
    )
    #expect(
      list.payload["supportedListeningModes"] as? [String]
        == ["transparency", "noise-cancellation"],
      "list payload has supported modes"
    )
    #expect(
      list.payload["listeningMode"] as? String == "noise-cancellation",
      "list payload has current mode"
    )

    let unsupportedDevice = FakeCompatibleAudioDevice(
      name: "Limited AirPods",
      listeningModes: [.transparency],
      listeningMode: .transparency
    )
    let unsupported = try commandOutcome(["lm", "set", "adaptive"], device: unsupportedDevice)
    #expect(unsupported.plain == "unsupported", "unavailable listening mode is unsupported")
    #expect(unsupported.exitCode == 4, "unsupported listening mode exits four")
    #expect(unsupported.terminalReason == .unsupported)
    #expect(
      unsupported.payload["listeningMode"] as? String == "transparency",
      "unsupported set preserves current mode"
    )
    let currentDevice = FakeCompatibleAudioDevice(
      name: "Current AirPods",
      listeningMode: .adaptive
    )
    let current = try commandOutcome(["lm", "set", "adaptive"], device: currentDevice)
    #expect(current.plain == "ok", "setting the current mode succeeds")
    #expect(currentDevice.listeningModeSetCount == 0, "idempotent set skips the setter")

    let changedDevice = FakeCompatibleAudioDevice(
      name: "Changed AirPods",
      listeningMode: .transparency
    )
    let changed = try commandOutcome(["lm", "set", "adaptive"], device: changedDevice)
    #expect(changed.plain == "ok", "verified listening-mode change succeeds")
    #expect(
      changed.payload["listeningMode"] as? String == "adaptive",
      "verified change reports observed mode"
    )
    #expect(changedDevice.listeningMode == .adaptive, "verified change mutates the device")
    #expect(changedDevice.listeningModeSetCount == 1, "verified change invokes the setter once")

    let unchangedDevice = FakeCompatibleAudioDevice(
      name: "Unchanged AirPods",
      listeningMode: .transparency,
      appliesListeningModeWrite: false
    )
    let unchanged = try commandOutcome(["lm", "set", "adaptive"], device: unchangedDevice)
    #expect(unchanged.plain == "no-op", "unverified listening-mode change is a no-op")
    #expect(unchanged.exitCode == 3, "unverified listening-mode change exits three")
    #expect(unchanged.terminalReason == .noOp)
    #expect(
      unchanged.payload["result"] as? String == "no-op"
        && unchanged.payload["error"] == nil,
      "a no-op has its distinct JSON envelope"
    )
    #expect(
      unchanged.payload["listeningMode"] as? String == "transparency",
      "no-op payload has observed mode"
    )
  }

  @Test("Reports default and explicit cycles with unsupported and no-op outcomes")
  func listeningModeCycleCommandExecution() throws {
    let defaultDevice = FakeCompatibleAudioDevice(
      name: "Cycle AirPods",
      listeningMode: .transparency
    )
    let defaultCycle = try commandOutcome(["lm", "cycle"], device: defaultDevice)
    #expect(defaultCycle.plain == "adaptive", "default cycle advances to Adaptive")
    #expect(
      defaultCycle.payload["listeningMode"] as? String == "adaptive",
      "cycle payload has target mode"
    )
    #expect(defaultDevice.listeningMode == .adaptive, "cycle mutates the device")
    #expect(
      defaultCycle.payload["supportedListeningModes"] == nil,
      "cycle payload omits supported mode list"
    )

    let explicitDevice = FakeCompatibleAudioDevice(
      name: "Explicit Cycle AirPods",
      listeningMode: .transparency
    )
    let explicitCycle = try commandOutcome(
      ["lm", "cycle", "--modes", "transparency,noise-cancellation"],
      device: explicitDevice
    )
    #expect(
      explicitCycle.plain == "noise-cancellation",
      "explicit cycle advances within its selected modes"
    )
    #expect(
      explicitDevice.listeningMode == .noiseCancellation,
      "explicit cycle applies its target"
    )

    let limitedDevice = FakeCompatibleAudioDevice(
      name: "Limited Cycle AirPods",
      listeningModes: [.transparency],
      listeningMode: .transparency
    )
    let unsupported = try commandOutcome(["lm", "cycle"], device: limitedDevice)
    #expect(unsupported.plain == "unsupported", "cycle with fewer than two modes is unsupported")
    #expect(
      unsupported.payload["listeningMode"] as? String == "transparency",
      "unsupported cycle preserves current mode"
    )
    let unchangedDevice = FakeCompatibleAudioDevice(
      name: "Unchanged Cycle AirPods",
      listeningMode: .transparency,
      appliesListeningModeWrite: false
    )
    let unchanged = try commandOutcome(["lm", "cycle"], device: unchangedDevice)
    #expect(unchanged.plain == "no-op", "unverified cycle is a no-op")
    #expect(
      unchanged.payload["listeningMode"] as? String == "transparency",
      "cycle no-op payload has observed mode"
    )
  }

  @Test("Reports Conversation Awareness reads and write outcomes")
  func conversationAwarenessCommandExecution() throws {
    let offDevice = FakeCompatibleAudioDevice(
      name: "Awareness AirPods",
      conversationAwarenessEnabled: false
    )
    let get = try commandOutcome(["ca", "get"], device: offDevice)
    #expect(get.plain == "off", "Conversation Awareness get returns state")
    #expect(
      get.payload["conversationAwareness"] as? String == "off",
      "Conversation Awareness payload has state"
    )

    let unsupportedDevice = FakeCompatibleAudioDevice(
      name: "Unsupported Awareness AirPods",
      conversationAwarenessSupported: false
    )
    let unsupported = try commandOutcome(["ca", "get"], device: unsupportedDevice)
    #expect(unsupported.plain == "unsupported", "unsupported Conversation Awareness is reported")
    #expect(
      unsupported.payload["conversationAwareness"] is NSNull,
      "unsupported Conversation Awareness state is JSON null"
    )
    let unsupportedSet = try commandOutcome(["ca", "set", "on"], device: unsupportedDevice)
    #expect(
      unsupportedSet.plain == "unsupported",
      "unsupported Conversation Awareness set is reported"
    )
    let currentDevice = FakeCompatibleAudioDevice(
      name: "Current Awareness AirPods",
      conversationAwarenessEnabled: true
    )
    let current = try commandOutcome(["ca", "set", "on"], device: currentDevice)
    #expect(current.plain == "ok", "setting current Conversation Awareness state succeeds")
    #expect(
      currentDevice.conversationAwarenessSetCount == 0,
      "idempotent Conversation Awareness set skips the setter"
    )

    let changedDevice = FakeCompatibleAudioDevice(
      name: "Changed Awareness AirPods",
      conversationAwarenessEnabled: false
    )
    let changed = try commandOutcome(["ca", "set", "on"], device: changedDevice)
    #expect(changed.plain == "ok", "verified Conversation Awareness change succeeds")
    #expect(
      changed.payload["conversationAwareness"] as? String == "on",
      "verified Conversation Awareness change reports observed state"
    )
    #expect(changedDevice.conversationAwarenessEnabled == true, "Conversation Awareness mutates")
    #expect(
      changedDevice.conversationAwarenessSetCount == 1,
      "Conversation Awareness change invokes the setter once"
    )

    let unchangedDevice = FakeCompatibleAudioDevice(
      name: "Unchanged Awareness AirPods",
      conversationAwarenessEnabled: false,
      appliesConversationAwarenessWrite: false
    )
    let unchanged = try commandOutcome(["ca", "set", "on"], device: unchangedDevice)
    #expect(unchanged.plain == "no-op", "unverified Conversation Awareness change is a no-op")
    #expect(
      unchanged.payload["conversationAwareness"] as? String == "off",
      "Conversation Awareness no-op reports observed state"
    )
  }

  @Test(
    "Resolves one exact named target for Conversation Awareness get and set",
    arguments: [
      ["ca", "--device", "Studio AirPods", "get"],
      ["ca", "set", "on", "--device", "Studio AirPods"],
    ]
  )
  func conversationAwarenessUsesSharedNamedSelection(arguments: [String]) throws {
    let invocation = try parseInvocation(arguments)
    var resolverCallCount = 0
    var capturedName: String?
    var capturedPolicy: DeviceSelectionPolicy?
    let outcome = CommandExecution.execute(
      invocation,
      resolveDevices: { name, policy, _ in
        resolverCallCount += 1
        capturedName = name
        capturedPolicy = policy
        return .failed(.noDevice)
      }
    )
    #expect(resolverCallCount == 1, "\(arguments) resolves exactly once")
    #expect(capturedName == "Studio AirPods", "\(arguments) forwards its exact requested name")
    guard case .singleOrExact? = capturedPolicy else {
      Issue.record("\(arguments) requires one operational target")
      return
    }
    #expect(outcome.payload["conversationAwareness"] is NSNull, "\(arguments) nulls its canonical state")
    #expect(outcome.payload["device"] is NSNull, "\(arguments) has no selected device")
    #expect(outcome.payload["supportedListeningModes"] == nil, "Conversation Awareness omits supported modes")
  }
}
