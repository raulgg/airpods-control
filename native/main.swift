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

func finish(_ outcome: CommandOutcome, jsonOutput: Bool) -> Never {
  finish(
    plain: outcome.plain,
    code: outcome.exitCode,
    jsonOutput: jsonOutput,
    payload: outcome.payload
  )
}

func bootstrapAndSelectAudioDevice(
  named requestedName: String?,
  logger: DebugLogger
) -> AudioDevice? {
  ensureBypass(logger: logger)

  guard let rawDevices = PrivateAudioDiscovery.systemOutputDevices(logger: logger) else {
    return nil
  }

  return PrivateAudioController(rawDevices: rawDevices, logger: logger)
    .selectDevice(named: requestedName)
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

let outcome = CommandExecution.execute(
  invocation,
  resolveDevice: bootstrapAndSelectAudioDevice
)
finish(outcome, jsonOutput: invocation.jsonOutput)
