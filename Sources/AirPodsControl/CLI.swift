import Foundation

let VERSION = "0.2.0"

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

enum WriteTestsPreference {
  case ask
  case always
  case never
}

enum CLICommand {
  case version
  case status
  case supportReport(writeTests: WriteTestsPreference)
  case listeningModeGet
  case listeningModeSet(ListeningMode)
  case listeningModeList
  // Requested cycle tokens in canonical order; nil means the default set
  // (every available mode except off).
  case listeningModeCycle(requested: [ListeningMode]?)
  case conversationAwarenessGet
  case conversationAwarenessSet(Bool)

  var resource: CLIResource? {
    switch self {
    case .version, .status, .supportReport:
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
    case .status: return "status"
    case .supportReport: return "support-report"
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

let globalHelp = """
Usage:
  airpods-control [--device NAME] <resource> <command> [--json] [--debug]
  airpods-control status [--device NAME] [--json] [--debug]
  airpods-control support-report [--with-write-tests | --no-write-tests] [--debug]
  airpods-control --version | -v | version
  airpods-control --help | -h

Resources:
  listening-mode, lm            Read, set, list, or cycle listening modes.
  conversation-awareness, ca    Read or set Conversation Awareness.

Command:
  status       Read modes and macOS audio output/input selection for every
               compatible AirPods or Beats device, or one selected by name.

Contributor command:
  support-report
               Build a local compatibility report. Open a prefilled GitHub
               issue form only after confirmation.

Global options:
  --device NAME
               Target a compatible device by exact name (case-insensitive).
  --json       Emit structured JSON instead of plain script-friendly output.
  --debug      Emit diagnostic logs to stderr without changing command output.
  --version, -v
               Print the version and exit.
  --help, -h   Print this help and exit.

Run 'airpods-control status --help' or
'airpods-control <resource> --help' for command-specific help.
"""

let statusHelp = """
Usage:
  airpods-control status [--device NAME] [--json] [--debug]

Read the status of every compatible AirPods or Beats device without changing
anything: listening mode, Conversation Awareness, and whether it is selected as
the macOS audio output or input.
"Selected" means that the device matches the ordinary default route. It does
not mean that audio is playing or recording. App routes, the alert route, and
membership in a composite route do not count.

Without --device, status reads macOS's public list of available Core Audio
devices. An eligible endpoint is ordinary and nonaggregate, uses classic
Bluetooth, is alive and ready, has an audio stream, and maps to an
IOBluetoothDevice. An undocumented HAL property identifies Apple audio
hardware. If that property is unavailable, status checks an allowlisted Apple
or Beats manufacturer. Input and output endpoints form one record when their
mapped objects compare equal in both directions, with the output endpoint
preferred. With --device, the Core Audio name must have one case-insensitive
exact match. Names are used for display and targeting, not identity.

Input and output are checked separately. Aggregate routes and known unrelated
transports produce no. Bluetooth LE, USB, unknown transports, missing
properties, and unavailable mappings produce unknown. A failed Core Audio read
or mapper call is a read error.

An inactive endpoint may expose its current listening mode through an
undocumented HAL property. The mapped Bluetooth object is the fallback when the
HAL property is unavailable or neutral, or when its read fails. The active AV
endpoint takes priority when it can be joined to the stable default output and
the same mapped Bluetooth object. Unknown AV or HAL values, and conflicting HAL
values, leave the mode unknown rather than falling back. Conversation Awareness
also requires this active-output join. The join translates a bounded AVOutputContext
associatedAudioDeviceID through Core Audio and compares the result with the
default output ID. It samples the private AVOutputDevice deviceID before and
after to reject a route change.

Core Audio handles are passed unchanged to macOS and never parsed. They and the
enrichment identifiers stay inside the process and are never printed or logged.
Inventory and selection do not read Bluetooth/MAC addresses, Core Audio UIDs,
or private route identifiers. Raw HAL values are not emitted, and support-report
does not use this status path.

Plain selection values are yes, no, or unknown; the selection fields follow the
listening-mode and Conversation Awareness fields, with read errors last. An
unresolved or failed feature read is also unknown; a feature proven unsupported
is omitted.

If no compatible device is connected, or the requested name is not unique,
print 'No compatible AirPods or Beats device is connected.' and exit 1.

Options:
  --device NAME
               Return only the uniquely named compatible device.
  --json       Emit a top-level devices array; selection values are Boolean or
               null when they cannot be determined safely.
  --debug      Emit diagnostic logs to stderr without changing command output.
  --help, -h   Print this help and exit without accessing any device.
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

let supportReportHelp = """
Usage:
  airpods-control support-report [--with-write-tests | --no-write-tests] [--debug]

Build a local compatibility report from device and macOS metadata. When the
command can plan at least one write test safely, an interactive run shows the
plan and asks for consent. Declining produces a read-only report. Exactly one
compatible output device must be available; the command does not read device
names or choose arbitrarily among devices.

Terminal output uses distinct Device, Capabilities, and Write tests sections,
with a compact summary and restoration result. The GitHub issue field uses the
same report data, formatted as Markdown.

The optional tests switch through the advertised listening modes recognized by
this CLI and toggle Conversation Awareness away from the captured initial state
and back. If a setting changes while consent is pending, or its initial state
cannot be restored safely, that setting is skipped without writing. The tests
can be disruptive: mode switches are audible and noise control changes while
the device is worn.

After normal completion or a setter error, the command makes one restoration
attempt. An unverified restoration reports the final state and
exits 3. An externally delivered SIGHUP, SIGINT, or SIGTERM caught during the
tests prints an interrupt notice on stderr, attempts restoration first, then
exits 129, 130, or 143, respectively, without offering an issue form.

Options:
  --with-write-tests
               Consent to the write tests without asking. This is the only
               way to run them when standard input is not interactive.
  --no-write-tests
               Skip the write tests and the consent question.
  --debug      Emit selector and device-discovery diagnostics to stderr
               without changing the report. They share stderr with the
               prompts, so the consent question appears among them.

The command never reads the customizable device name, firmware version, serial
numbers, Bluetooth/MAC addresses, account data, or raw system dumps and logs. It
does not enumerate the Core Audio status inventory, query selected audio routes,
call the selection mapper, run the status feature-enrichment probe, or read or
report routing identifiers. It never uses the clipboard, sends telemetry, or
submits anything. A read-only report does not change device
settings or intentionally interrupt audio. Check the report before choosing
whether to open a prefilled GitHub issue form.
"""

func helpText(for rawArgs: [String]) -> String? {
  guard let helpIndex = rawArgs.firstIndex(where: { ["--help", "-h"].contains($0) }) else {
    return nil
  }

  let contextualCommands = [
    "status", "listening-mode", "lm", "conversation-awareness", "ca", "support-report",
  ]
  let arguments = Array(rawArgs[..<helpIndex])
  var resource: String?
  var index = 0
  while index < arguments.count {
    if ["--device", "--modes"].contains(arguments[index]) {
      // These options consume the next token. A device named "status" or
      // "lm" must not select unrelated contextual help.
      index += 2
      continue
    }
    if contextualCommands.contains(arguments[index]) {
      resource = arguments[index]
      break
    }
    index += 1
  }

  switch resource {
  case "status":
    return statusHelp
  case "listening-mode", "lm":
    return listeningModeHelp
  case "conversation-awareness", "ca":
    return conversationAwarenessHelp
  case "support-report":
    return supportReportHelp
  default:
    return globalHelp
  }
}

// Parses a --modes value into distinct canonical tokens in canonical order.
// Empty or unknown tokens and sets of fewer than two distinct modes are
// parse errors.
func parseCycleModes(_ raw: String) throws -> [ListeningMode] {
  let tokens = try raw
    .split(separator: ",", omittingEmptySubsequences: false)
    .map { piece -> ListeningMode in
      guard let mode = ListeningMode(token: String(piece)) else {
        throw CLIParseError()
      }
      return mode
    }
  let unique = Set(tokens)
  guard unique.count >= 2 else { throw CLIParseError() }
  return ListeningMode.allCases.filter { unique.contains($0) }
}

func parseInvocation(_ rawArgs: [String]) throws -> CLIInvocation {
  var positional: [String] = []
  var jsonOutput = false
  var debugEnabled = false
  var withWriteTests = false
  var noWriteTests = false
  var requestedDeviceName: String?
  var requestedCycleModes: [ListeningMode]?
  var index = 0

  while index < rawArgs.count {
    switch rawArgs[index] {
    case "--json":
      guard !jsonOutput else { throw CLIParseError() }
      jsonOutput = true

    case "--with-write-tests":
      guard !withWriteTests else { throw CLIParseError() }
      withWriteTests = true

    case "--no-write-tests":
      guard !noWriteTests else { throw CLIParseError() }
      noWriteTests = true

    case "--debug":
      guard !debugEnabled else { throw CLIParseError() }
      debugEnabled = true

    case "--device":
      guard requestedDeviceName == nil, index + 1 < rawArgs.count else {
        throw CLIParseError()
      }
      let name = rawArgs[index + 1]
      guard !name.isEmpty,
            !name.hasPrefix("-")
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
    guard requestedDeviceName == nil,
          requestedCycleModes == nil,
          !withWriteTests,
          !noWriteTests
    else {
      throw CLIParseError()
    }
    return CLIInvocation(
      command: .version,
      jsonOutput: jsonOutput,
      debugEnabled: debugEnabled,
      requestedDeviceName: nil
    )
  }

  // --debug is allowed: whoever runs support-report is whoever's device the CLI
  // does not recognize, and the diagnostics say why. Resolving the report device
  // with includeDeviceNames: false keeps the customizable name out of the
  // stream. --json is not allowed; the report is not a JSON payload.
  if positional == ["support-report"] {
    guard requestedDeviceName == nil,
          requestedCycleModes == nil,
          !jsonOutput,
          !(withWriteTests && noWriteTests)
    else {
      throw CLIParseError()
    }
    let writeTests: WriteTestsPreference
    if withWriteTests {
      writeTests = .always
    } else if noWriteTests {
      writeTests = .never
    } else {
      writeTests = .ask
    }
    return CLIInvocation(
      command: .supportReport(writeTests: writeTests),
      jsonOutput: false,
      debugEnabled: debugEnabled,
      requestedDeviceName: nil
    )
  }

  guard !withWriteTests, !noWriteTests else { throw CLIParseError() }

  if positional == ["status"] {
    guard requestedCycleModes == nil else { throw CLIParseError() }
    return CLIInvocation(
      command: .status,
      jsonOutput: jsonOutput,
      debugEnabled: debugEnabled,
      requestedDeviceName: requestedDeviceName
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
            let mode = ListeningMode(token: positional[2])
      else {
        throw CLIParseError()
      }
      command = .listeningModeSet(mode)

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
