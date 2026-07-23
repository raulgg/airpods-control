// airpods-control — control AirPods listening mode and Conversation Awareness
// from a scriptable command-line interface.
//
// Compiled with swiftc (no Xcode needed) + a tiny C bypass dylib. On launch it
// re-execs itself once with avbypass.dylib inserted so the in-process
// entitlement gate for the shared system audio context is satisfied — the same
// technique NoiseBuddy uses.

import Darwin
import Foundation

func resolvedExecutablePath() -> String? {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  var size = UInt32(buffer.count)

  if _NSGetExecutablePath(&buffer, &size) != 0 {
    buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
  }

  let unresolved = String(cString: buffer)
  return URL(fileURLWithPath: unresolved)
    .resolvingSymlinksInPath()
    .standardizedFileURL.path
}

func ensureBypass(logger: DebugLogger) {
  if ProcessInfo.processInfo.environment["AIRPODS_CONTROL_BYPASSED"] != nil {
    logger.debug("bypass.status", "active")
    return
  }

  guard let executable = resolvedExecutablePath() else {
    logger.warning("bypass.status", "executable-path-unavailable")
    return
  }

  let dylib = (executable as NSString).deletingLastPathComponent + "/avbypass.dylib"
  guard FileManager.default.fileExists(atPath: dylib) else {
    logger.warning("bypass.status", "dylib-missing")
    logger.debug("bypass.dylib", dylib)
    return
  }

  setenv("DYLD_INSERT_LIBRARIES", dylib, 1)
  setenv("AIRPODS_CONTROL_BYPASSED", "1", 1)
  logger.info("bypass.status", "reexec")
  logger.debug("bypass.dylib", dylib)

  var cargs = CommandLine.arguments.map { strdup($0) }
  cargs.append(nil)
  execv(executable, &cargs)

  logger.warning("bypass.status", "reexec-failed")
  logger.debug("bypass.errno", errno)
}

func writeJSON(_ payload: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}

func finish(
  plain: String,
  code: Int32 = 0,
  jsonOutput: Bool,
  payload: [String: Any]
) -> Never {
  if jsonOutput {
    writeJSON(payload)
  } else {
    print(plain)
  }
  exit(code)
}

func finishResource(
  invocation: CLIInvocation,
  deviceName: String?,
  plain: String,
  code: Int32,
  result: String,
  state: String?,
  error: String? = nil,
  extra: [String: Any] = [:]
) -> Never {
  let resource = invocation.command.resource!
  finish(
    plain: plain,
    code: code,
    jsonOutput: invocation.jsonOutput,
    payload: makeResourcePayload(
      resource: resource,
      deviceName: deviceName,
      result: result,
      state: state,
      error: error,
      extra: extra
    )
  )
}

func canonicalListeningMode(_ rawMode: String?) -> String? {
  rawMode.flatMap { avToToken[$0] }
}

func setAndReadListeningMode(
  device: AudioDevice,
  target: String,
  logger: DebugLogger
) -> (accepted: Bool, observed: String?) {
  let accepted = device.setListeningMode(target) ?? false
  let observed = device.currentListeningMode()
  logger.debug("verify.listening_mode.attempt", 0)
  return (accepted, observed)
}

func setAndObserveConversationAwareness(
  device: AudioDevice,
  target: Bool,
  logger: DebugLogger
) -> (verified: Bool, observed: Bool?) {
  guard device.setConversationAwareness(target) != nil else {
    return (false, device.conversationAwarenessState())
  }

  var observed: Bool?
  for attempt in 1...16 {
    usleep(50_000)
    observed = device.conversationAwarenessState()
    logger.debug("verify.conversation_awareness.attempt", attempt)
    if observed == target { return (true, observed) }
  }
  return (false, observed)
}

let rawArgs = Array(CommandLine.arguments.dropFirst())

if rawArgs.isEmpty {
  print(globalHelp)
  exit(0)
}

if let help = helpText(for: rawArgs) {
  print(help)
  exit(0)
}

let preliminaryJSON = rawArgs.contains("--json")
let preliminaryDebug = rawArgs.contains("--debug")
let preliminaryLogger = DebugLogger(enabled: preliminaryDebug)

let invocation: CLIInvocation
do {
  invocation = try parseInvocation(rawArgs)
} catch {
  preliminaryLogger.warning("cli.parse", "bad-args")
  finish(
    plain: "bad-args",
    code: 2,
    jsonOutput: preliminaryJSON,
    payload: ["error": "bad-args", "result": "error"]
  )
}

let logger = DebugLogger(enabled: invocation.debugEnabled)
logger.debug("cli.command", invocation.command.debugName)
logger.debug("cli.json", invocation.jsonOutput)
logger.debug("cli.requested_device", invocation.requestedDeviceName)

if case .version = invocation.command {
  finish(
    plain: VERSION,
    jsonOutput: invocation.jsonOutput,
    payload: ["result": "ok", "version": VERSION]
  )
}

ensureBypass(logger: logger)

guard let rawDevices = PrivateAudioDiscovery.systemOutputDevices(logger: logger) else {
  let extra: [String: Any]
  if case .listeningModeList = invocation.command {
    extra = ["supportedListeningModes": [String]()]
  } else {
    extra = [:]
  }
  finishResource(
    invocation: invocation,
    deviceName: nil,
    plain: "no-device",
    code: 1,
    result: "error",
    state: nil,
    error: "no-device",
    extra: extra
  )
}

let controller = PrivateAudioController(rawDevices: rawDevices, logger: logger)
guard let device = controller.selectDevice(named: invocation.requestedDeviceName) else {
  let extra: [String: Any]
  if case .listeningModeList = invocation.command {
    extra = ["supportedListeningModes": [String]()]
  } else {
    extra = [:]
  }
  finishResource(
    invocation: invocation,
    deviceName: nil,
    plain: "no-device",
    code: 1,
    result: "error",
    state: nil,
    error: "no-device",
    extra: extra
  )
}

switch invocation.command {
case .version:
  fatalError("version handled before device discovery")

case .listeningModeGet:
  let mode = canonicalListeningMode(device.currentListeningMode())
  finishResource(
    invocation: invocation,
    deviceName: device.name,
    plain: mode ?? "unknown",
    code: 0,
    result: "ok",
    state: mode
  )

case .listeningModeList:
  let current = canonicalListeningMode(device.currentListeningMode())
  let availableModes = Set(device.availableListeningModes())
  let tokens = modeTokenOrder.filter { token in
    tokenToAV[token].map { availableModes.contains($0) } ?? false
  }
  finishResource(
    invocation: invocation,
    deviceName: device.name,
    plain: tokens.joined(separator: ","),
    code: 0,
    result: "ok",
    state: current,
    extra: ["supportedListeningModes": tokens]
  )

case let .listeningModeSet(token, avMode):
  let currentRaw = device.currentListeningMode()
  let current = canonicalListeningMode(currentRaw)

  guard device.availableListeningModes().contains(avMode), device.canSetListeningMode() else {
    finishResource(
      invocation: invocation,
      deviceName: device.name,
      plain: "unsupported",
      code: 4,
      result: "error",
      state: current,
      error: "unsupported"
    )
  }

  if currentRaw == avMode {
    finishResource(
      invocation: invocation,
      deviceName: device.name,
      plain: "ok",
      code: 0,
      result: "ok",
      state: token
    )
  }

  let outcome = setAndReadListeningMode(device: device, target: avMode, logger: logger)
  let state = listeningModeStateAfterSet(
    requestedToken: token,
    setterAccepted: outcome.accepted,
    observedRawMode: outcome.observed
  )
  let inferredOffFallback =
    token == "off" && outcome.accepted && outcome.observed != nil && outcome.observed != avMode
  logger.debug("verify.listening_mode.inferred_off_fallback", inferredOffFallback)

  if outcome.observed == avMode {
    finishResource(
      invocation: invocation,
      deviceName: device.name,
      plain: "ok",
      code: 0,
      result: "ok",
      state: state
    )
  } else {
    finishResource(
      invocation: invocation,
      deviceName: device.name,
      plain: "no-op",
      code: 3,
      result: "no-op",
      state: state
    )
  }

case .conversationAwarenessGet:
  guard device.supportsConversationAwareness() == true,
        let enabled = device.conversationAwarenessState()
  else {
    finishResource(
      invocation: invocation,
      deviceName: device.name,
      plain: "unsupported",
      code: 4,
      result: "error",
      state: nil,
      error: "unsupported"
    )
  }
  finishResource(
    invocation: invocation,
    deviceName: device.name,
    plain: enabled ? "on" : "off",
    code: 0,
    result: "ok",
    state: enabled ? "on" : "off"
  )

case let .conversationAwarenessSet(target):
  guard device.supportsConversationAwareness() == true,
        let current = device.conversationAwarenessState(),
        device.canSetConversationAwareness()
  else {
    finishResource(
      invocation: invocation,
      deviceName: device.name,
      plain: "unsupported",
      code: 4,
      result: "error",
      state: nil,
      error: "unsupported"
    )
  }

  if current == target {
    let state = target ? "on" : "off"
    finishResource(
      invocation: invocation,
      deviceName: device.name,
      plain: "ok",
      code: 0,
      result: "ok",
      state: state
    )
  }

  let outcome = setAndObserveConversationAwareness(
    device: device,
    target: target,
    logger: logger
  )
  let observed = outcome.observed.map { $0 ? "on" : "off" }
  if outcome.verified {
    finishResource(
      invocation: invocation,
      deviceName: device.name,
      plain: "ok",
      code: 0,
      result: "ok",
      state: observed
    )
  } else {
    finishResource(
      invocation: invocation,
      deviceName: device.name,
      plain: "no-op",
      code: 3,
      result: "no-op",
      state: observed
    )
  }
}
