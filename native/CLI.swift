import Foundation

let VERSION = "0.1.0"

let tokenToAV: [String: String] = [
  "off": "AVOutputDeviceBluetoothListeningModeNormal",
  "transparency": "AVOutputDeviceBluetoothListeningModeAudioTransparency",
  "adaptive": "AVOutputDeviceBluetoothListeningModeAutomatic",
  "noise-cancellation": "AVOutputDeviceBluetoothListeningModeActiveNoiseCancellation",
]

let modeAliases: [String: String] = [
  "anc": "noise-cancellation",
  "nc": "noise-cancellation",
  "trans": "transparency",
  "automatic": "adaptive",
  "auto": "adaptive",
]

let modeTokenOrder = ["off", "transparency", "adaptive", "noise-cancellation"]
let avToToken = Dictionary(uniqueKeysWithValues: tokenToAV.map { ($1, $0) })

enum CLIResource {
  case listeningMode
  case conversationAwareness

  var stateKey: String {
    switch self {
    case .listeningMode: return "listeningMode"
    case .conversationAwareness: return "conversationAwareness"
    }
  }
}

enum CLICommand {
  case version
  case listeningModeGet
  case listeningModeSet(token: String, avMode: String)
  case listeningModeList
  // Requested cycle tokens in canonical order; nil means the default set
  // (every available mode except off).
  case listeningModeCycle(requested: [String]?)
  case conversationAwarenessGet
  case conversationAwarenessSet(Bool)

  var resource: CLIResource? {
    switch self {
    case .version:
      return nil
    case .listeningModeGet, .listeningModeSet, .listeningModeList, .listeningModeCycle:
      return .listeningMode
    case .conversationAwarenessGet, .conversationAwarenessSet:
      return .conversationAwareness
    }
  }

  var debugName: String {
    switch self {
    case .version: return "version"
    case .listeningModeGet: return "listening-mode.get"
    case .listeningModeSet: return "listening-mode.set"
    case .listeningModeList: return "listening-mode.list"
    case .listeningModeCycle: return "listening-mode.cycle"
    case .conversationAwarenessGet: return "conversation-awareness.get"
    case .conversationAwarenessSet: return "conversation-awareness.set"
    }
  }
}

struct CLIInvocation {
  let command: CLICommand
  let jsonOutput: Bool
  let debugEnabled: Bool
  let requestedDeviceName: String?
}

struct CLIParseError: Error {}

struct DebugLogger {
  let enabled: Bool

  func debug(_ key: String, _ value: Any?) {
    write(level: "debug", key: key, value: value)
  }

  func info(_ key: String, _ value: Any?) {
    write(level: "info", key: key, value: value)
  }

  func warning(_ key: String, _ value: Any?) {
    write(level: "warning", key: key, value: value)
  }

  private func write(level: String, key: String, value: Any?) {
    guard enabled else { return }
    let rendered: String
    switch value {
    case nil:
      rendered = "null"
    case let string as String:
      rendered = String(reflecting: string)
    case let bool as Bool:
      rendered = bool ? "true" : "false"
    default:
      rendered = String(describing: value!)
    }
    let line = "\(level): \(key)=\(rendered)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}

let globalHelp = """
Usage:
  airpods-control [--device NAME] <resource> <command> [--json] [--debug]
  airpods-control --version | -v | version
  airpods-control --help | -h

Resources:
  listening-mode, lm            Read, set, list, or cycle listening modes.
  conversation-awareness, ca    Read or set Conversation Awareness.

Global options:
  --device NAME
               Target a compatible output device by exact name (case-insensitive).
  --json       Emit structured JSON instead of plain script-friendly output.
  --debug      Emit diagnostic logs to stderr without changing command output.
  --version, -v
               Print the version and exit.
  --help, -h   Print this help and exit.

Run 'airpods-control <resource> --help' for resource-specific help.
"""

let listeningModeHelp = """
Usage:
  airpods-control [--device NAME] listening-mode get [--json] [--debug]
  airpods-control [--device NAME] listening-mode set <mode> [--json] [--debug]
  airpods-control [--device NAME] listening-mode list [--json] [--debug]
  airpods-control [--device NAME] listening-mode cycle [--modes <m1,m2[,...]>] [--json] [--debug]

Alias:
  lm

Modes:
  off, transparency, adaptive, noise-cancellation

Mode aliases:
  trans
               transparency
  automatic, auto
               adaptive
  anc, nc      noise-cancellation

Cycle:
  cycle advances to the next mode in the order above, wrapping around, and
  prints the mode it landed on. The cycle set defaults to every mode the
  device supports except off. --modes selects an explicit subset (at least
  two distinct modes); modes the device lacks are skipped. If the current
  mode is outside the cycle set, cycle still advances in the order above
  from the current mode to the next mode that is in the set (wrapping); if
  the current mode is unknown, cycle starts at the set's first mode.

Options:
  --device NAME
               Target a compatible output device by exact name (case-insensitive).
  --modes <m1,m2[,...]>
               Cycle set for listening-mode cycle: at least two distinct
               modes, comma-separated. Mode aliases are accepted.
  --json       Emit structured JSON instead of plain script-friendly output.
  --debug      Emit diagnostic logs to stderr without changing command output.
  --help, -h   Print this help and exit without accessing the device.
"""

let conversationAwarenessHelp = """
Usage:
  airpods-control [--device NAME] conversation-awareness get [--json] [--debug]
  airpods-control [--device NAME] conversation-awareness set <on|off> [--json] [--debug]

Alias:
  ca

Options:
  --device NAME
               Target a compatible output device by exact name (case-insensitive).
  --json       Emit structured JSON instead of plain script-friendly output.
  --debug      Emit diagnostic logs to stderr without changing command output.
  --help, -h   Print this help and exit without accessing the device.
"""

func helpText(for rawArgs: [String]) -> String? {
  guard let helpIndex = rawArgs.firstIndex(where: { ["--help", "-h"].contains($0) }) else {
    return nil
  }

  let resource = rawArgs[..<helpIndex].first { argument in
    ["listening-mode", "lm", "conversation-awareness", "ca"].contains(argument)
  }

  switch resource {
  case "listening-mode", "lm":
    return listeningModeHelp
  case "conversation-awareness", "ca":
    return conversationAwarenessHelp
  default:
    return globalHelp
  }
}

func canonicalModeToken(_ input: String) -> String? {
  if tokenToAV[input] != nil { return input }
  return modeAliases[input]
}

// Parses a --modes value into distinct canonical tokens in canonical order.
// Empty or unknown tokens and sets of fewer than two distinct modes are
// parse errors.
func parseCycleModes(_ raw: String) throws -> [String] {
  let tokens = try raw
    .split(separator: ",", omittingEmptySubsequences: false)
    .map { piece -> String in
      guard let canonical = canonicalModeToken(String(piece)) else {
        throw CLIParseError()
      }
      return canonical
    }
  let unique = Set(tokens)
  guard unique.count >= 2 else { throw CLIParseError() }
  return modeTokenOrder.filter { unique.contains($0) }
}

// Advances through the canonical mode order from the current mode, wrapping,
// to the next mode in the cycle set — a current mode outside the set folds
// into the same order. An unknown current mode starts at the set's first mode.
func nextCycleMode(current: String?, cycleTokens: [String]) -> String {
  guard let current, let start = modeTokenOrder.firstIndex(of: current) else {
    return cycleTokens[0]
  }
  for step in 1...modeTokenOrder.count {
    let candidate = modeTokenOrder[(start + step) % modeTokenOrder.count]
    if cycleTokens.contains(candidate) { return candidate }
  }
  return cycleTokens[0]
}

func listeningModeStateAfterSet(
  requestedToken: String,
  setterAccepted: Bool,
  observedRawMode: String?
) -> String? {
  guard let observedRawMode else { return nil }

  // MVP heuristic: current AirPods firmware resolves an accepted Off request
  // to Transparency when Off Listening Mode is disabled. Replace this with an
  // authoritative device event if that private signal becomes reliable.
  if requestedToken == "off",
     setterAccepted,
     observedRawMode != tokenToAV["off"]
  {
    return "transparency"
  }

  return avToToken[observedRawMode]
}

func makeResourcePayload(
  resource: CLIResource,
  deviceName: String?,
  result: String,
  state: String?,
  error: String? = nil,
  extra: [String: Any] = [:]
) -> [String: Any] {
  var payload = extra
  payload["device"] = deviceName ?? NSNull()
  payload["result"] = result
  payload[resource.stateKey] = state ?? NSNull()
  if let error {
    payload["error"] = error
  }
  return payload
}

func parseInvocation(_ rawArgs: [String]) throws -> CLIInvocation {
  var positional: [String] = []
  var jsonOutput = false
  var debugEnabled = false
  var requestedDeviceName: String?
  var requestedCycleModes: [String]?
  var index = 0

  while index < rawArgs.count {
    switch rawArgs[index] {
    case "--json":
      guard !jsonOutput else { throw CLIParseError() }
      jsonOutput = true

    case "--debug":
      guard !debugEnabled else { throw CLIParseError() }
      debugEnabled = true

    case "--device":
      guard requestedDeviceName == nil, index + 1 < rawArgs.count else {
        throw CLIParseError()
      }
      let name = rawArgs[index + 1]
      guard !name.isEmpty, !["--json", "--debug", "--device", "--help", "-h"].contains(name)
      else {
        throw CLIParseError()
      }
      requestedDeviceName = name
      index += 1

    case "--modes":
      guard requestedCycleModes == nil, index + 1 < rawArgs.count else {
        throw CLIParseError()
      }
      requestedCycleModes = try parseCycleModes(rawArgs[index + 1])
      index += 1

    default:
      positional.append(rawArgs[index])
    }

    index += 1
  }

  if positional.count == 1, ["--version", "-v", "version"].contains(positional[0]) {
    guard requestedDeviceName == nil, requestedCycleModes == nil else { throw CLIParseError() }
    return CLIInvocation(
      command: .version,
      jsonOutput: jsonOutput,
      debugEnabled: debugEnabled,
      requestedDeviceName: nil
    )
  }

  guard positional.count >= 2 else { throw CLIParseError() }

  let command: CLICommand
  switch positional[0] {
  case "listening-mode", "lm":
    switch positional[1] {
    case "get":
      guard positional.count == 2 else { throw CLIParseError() }
      command = .listeningModeGet

    case "set":
      guard positional.count == 3,
            let canonical = canonicalModeToken(positional[2]),
            let avMode = tokenToAV[canonical]
      else {
        throw CLIParseError()
      }
      command = .listeningModeSet(token: canonical, avMode: avMode)

    case "list":
      guard positional.count == 2 else { throw CLIParseError() }
      command = .listeningModeList

    case "cycle":
      guard positional.count == 2 else { throw CLIParseError() }
      command = .listeningModeCycle(requested: requestedCycleModes)
      requestedCycleModes = nil

    default:
      throw CLIParseError()
    }

  case "conversation-awareness", "ca":
    switch positional[1] {
    case "get":
      guard positional.count == 2 else { throw CLIParseError() }
      command = .conversationAwarenessGet

    case "set":
      guard positional.count == 3, ["on", "off"].contains(positional[2]) else {
        throw CLIParseError()
      }
      command = .conversationAwarenessSet(positional[2] == "on")

    default:
      throw CLIParseError()
    }

  default:
    throw CLIParseError()
  }

  // --modes is only meaningful for listening-mode cycle, which consumes it.
  guard requestedCycleModes == nil else { throw CLIParseError() }

  return CLIInvocation(
    command: command,
    jsonOutput: jsonOutput,
    debugEnabled: debugEnabled,
    requestedDeviceName: requestedDeviceName
  )
}
