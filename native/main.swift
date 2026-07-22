// airpods — control AirPods listening mode and Conversation Awareness from a
// scriptable command-line interface.
//
// Compiled with swiftc (no Xcode needed) + a tiny C bypass dylib. On launch it
// re-execs itself once with avbypass.dylib inserted so the in-process
// entitlement gate for the shared system audio context is satisfied — the same
// technique NoiseBuddy uses. We set DYLD_INSERT_LIBRARIES inside the
// child, so it does not matter whether the parent process strips DYLD_* vars.
//
// Command surface (single-token, machine-parseable output):
//   get                         -> off | transparency | adaptive |
//                                  noise-cancellation | unknown | no-device
//   set <token>                 -> ok | no-op | unsupported | no-device
//   toggle <tokenA> <tokenB>    -> <new token> | no-op | no-device
//   list                        -> comma-separated available tokens | no-device
//   ca get                      -> on | off | unsupported | no-device
//   ca set <on|off>             -> ok | no-op | unsupported | no-device
//   ca toggle                   -> on | off | no-op | unsupported | no-device
//   --json                      -> structured output for any command
//   --help | -h                 -> usage
//   --version | -v | version    -> 0.1.0
//
// Exit codes: 0 ok, 1 no-device, 2 bad-args, 3 no-op, 4 unsupported.

import Foundation

let VERSION = "0.1.0"
var jsonOutput = false

// ── Entitlement-bypass bootstrap ──────────────────────────────────────────
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

func ensureBypass() {
  if ProcessInfo.processInfo.environment["AIRPODS_BYPASSED"] != nil { return }
  guard let exe = resolvedExecutablePath() else { return }
  let dylib = (exe as NSString).deletingLastPathComponent + "/avbypass.dylib"
  setenv("DYLD_INSERT_LIBRARIES", dylib, 1)
  setenv("AIRPODS_BYPASSED", "1", 1)
  var cargs = CommandLine.arguments.map { strdup($0) }
  cargs.append(nil)
  execv(exe, &cargs)
  // If execv returns it failed; we continue unbypassed and report no-device.
}

// ── Private API surface (duck-typed via an @objc protocol) ────────────────
@objc protocol AVOutputDeviceShim {
  @objc(availableBluetoothListeningModes) func availableModes() -> [String]?
  @objc(currentBluetoothListeningMode) func currentMode() -> String?
  @objc(setCurrentBluetoothListeningMode:error:)
  func setMode(_ mode: String, _ error: NSErrorPointer) -> Bool
  @objc(isConversationDetectionEnabled) func caEnabled() -> Bool
  @objc(setConversationDetectionEnabled:error:)
  func setCA(_ enabled: Bool, _ error: NSErrorPointer) -> Bool
  @objc(supportsConversationDetection) func supportsCA() -> Bool
}

func airpodsDevice() -> AVOutputDeviceShim? {
  dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_NOW)
  dlopen("/System/Library/Frameworks/AVRouting.framework/AVRouting", RTLD_NOW)
  guard let cls = NSClassFromString("AVOutputContext") else { return nil }
  let ctxSel = NSSelectorFromString("sharedSystemAudioContext")
  guard let ctxU = (cls as AnyObject).perform(ctxSel) else { return nil }
  let ctx = ctxU.takeUnretainedValue()
  guard let devU = ctx.perform(NSSelectorFromString("outputDevices")),
        let devices = devU.takeUnretainedValue() as? [AnyObject] else { return nil }
  for d in devices {
    let shim = unsafeBitCast(d, to: AVOutputDeviceShim.self)
    if let modes = shim.availableModes(), !modes.isEmpty { return shim }
  }
  return nil
}

// ── Token <-> AVOutputDevice mode-string mapping ──────────────────────────
let tokenToAV: [String: String] = [
  "off": "AVOutputDeviceBluetoothListeningModeNormal",
  "transparency": "AVOutputDeviceBluetoothListeningModeAudioTransparency",
  "adaptive": "AVOutputDeviceBluetoothListeningModeAutomatic",
  "noise-cancellation": "AVOutputDeviceBluetoothListeningModeActiveNoiseCancellation",
]
let modeTokenOrder = ["off", "transparency", "adaptive", "noise-cancellation"]
let avToToken = Dictionary(uniqueKeysWithValues: tokenToAV.map { ($1, $0) })

func finish(_ token: String, code: Int32 = 0, json: [String: Any]? = nil) -> Never {
  if jsonOutput {
    let payload = json ?? [code == 0 ? "result" : "error": token]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  } else {
    print(token)
  }
  exit(code)
}

func fail(_ token: String, _ code: Int32, json: [String: Any]? = nil) -> Never {
  finish(token, code: code, json: json)
}

let help = """
Usage:
  airpods get [--json]
  airpods set <mode> [--json]
  airpods toggle <modeA> <modeB> [--json]
  airpods list [--json]
  airpods ca [get | set on|off | toggle] [--json]
  airpods --version | -v | version
  airpods --help | -h

Modes:
  off, transparency, adaptive, noise-cancellation

Options:
  --json       Emit structured JSON instead of plain script-friendly output.
  --version    Print the version and exit.
  --help       Print this help and exit.
"""

enum CLICommand {
  case get
  case list
  case set(String, String)
  case toggle(String, String, String, String)
  case caGet
  case caSet(Bool)
  case caToggle
}

func parseCommand(_ args: [String]) -> CLICommand {
  guard let cmd = args.first else { fail("bad-args", 2) }

  switch cmd {
  case "get":
    guard args.count == 1 else { fail("bad-args", 2) }
    return .get

  case "list":
    guard args.count == 1 else { fail("bad-args", 2) }
    return .list

  case "set":
    guard args.count == 2 else { fail("bad-args", 2) }
    guard let av = tokenToAV[args[1]] else { fail("unsupported", 4) }
    return .set(args[1], av)

  case "toggle":
    guard args.count == 3 else { fail("bad-args", 2) }
    guard let avA = tokenToAV[args[1]], let avB = tokenToAV[args[2]] else {
      fail("unsupported", 4)
    }
    return .toggle(args[1], avA, args[2], avB)

  case "ca":
    let sub = args.count >= 2 ? args[1] : "get"
    switch sub {
    case "get":
      guard args.count <= 2 else { fail("bad-args", 2) }
      return .caGet
    case "set":
      guard args.count == 3, ["on", "off"].contains(args[2]) else {
        fail("bad-args", 2)
      }
      return .caSet(args[2] == "on")
    case "toggle":
      guard args.count == 2 else { fail("bad-args", 2) }
      return .caToggle
    default:
      fail("bad-args", 2)
    }

  default:
    fail("bad-args", 2)
  }
}

// Sets `av` and confirms by read-back (the BOOL return lies — it is 1 even for
// silent no-ops like Off on AirPods Pro). Returns true only on a verified flip.
func setAndVerify(_ dev: AVOutputDeviceShim, _ av: String) -> Bool {
  _ = dev.setMode(av, nil)
  for _ in 0..<16 {
    usleep(50_000) // ~800ms total budget
    if dev.currentMode() == av { return true }
  }
  return false
}

func caSetAndVerify(_ dev: AVOutputDeviceShim, _ enabled: Bool) -> Bool {
  _ = dev.setCA(enabled, nil)
  for _ in 0..<16 {
    usleep(50_000)
    if dev.caEnabled() == enabled { return true }
  }
  return false
}

// ── Entry ─────────────────────────────────────────────────────────────────
let rawArgs = Array(CommandLine.arguments.dropFirst())
let jsonFlagCount = rawArgs.filter { $0 == "--json" }.count
jsonOutput = jsonFlagCount > 0
guard jsonFlagCount <= 1 else { fail("bad-args", 2) }

let args = rawArgs.filter { $0 != "--json" }

if args.count == 1, ["--help", "-h"].contains(args[0]) {
  print(help)
  exit(0)
}

if args.count == 1, ["--version", "-v", "version"].contains(args[0]) {
  finish(VERSION, json: ["version": VERSION])
}

let command = parseCommand(args)

ensureBypass()
guard let dev = airpodsDevice() else { fail("no-device", 1) }

switch command {
case .get:
  let av = dev.currentMode()
  let mode = av.flatMap { avToToken[$0] } ?? "unknown"
  finish(mode, json: ["mode": mode])

case .list:
  let availableModes = Set(dev.availableModes() ?? [])
  let tokens = modeTokenOrder.filter { token in
    tokenToAV[token].map { availableModes.contains($0) } ?? false
  }
  finish(tokens.joined(separator: ","), json: ["modes": tokens])

case let .set(token, av):
  guard (dev.availableModes() ?? []).contains(av) else { fail("unsupported", 4) }
  if dev.currentMode() == av {
    finish("ok", json: ["mode": token, "result": "ok"])
  }
  let okSet = setAndVerify(dev, av)
  if okSet {
    finish("ok", json: ["mode": token, "result": "ok"])
  } else {
    fail("no-op", 3, json: ["result": "no-op"])
  }

case let .toggle(tokenA, avA, tokenB, avB):
  let cur = dev.currentMode()
  let target = (cur == avA) ? avB : avA
  let targetToken = (cur == avA) ? tokenB : tokenA
  guard (dev.availableModes() ?? []).contains(target) else { fail("unsupported", 4) }
  if setAndVerify(dev, target) {
    finish(targetToken, json: ["mode": targetToken, "result": "ok"])
  } else {
    fail("no-op", 3, json: ["result": "no-op"])
  }

case .caGet, .caSet(_), .caToggle:
  guard dev.supportsCA() else { fail("unsupported", 4) }

  switch command {
  case .caGet:
    let state = dev.caEnabled() ? "on" : "off"
    finish(state, json: ["ca": state])

  case let .caSet(target):
    if dev.caEnabled() == target {
      finish("ok", json: ["ca": target ? "on" : "off", "result": "ok"])
    }
    let okCA = caSetAndVerify(dev, target)
    if okCA {
      finish("ok", json: ["ca": target ? "on" : "off", "result": "ok"])
    } else {
      fail("no-op", 3, json: ["result": "no-op"])
    }

  case .caToggle:
    let target = !dev.caEnabled()
    if caSetAndVerify(dev, target) {
      let state = target ? "on" : "off"
      finish(state, json: ["ca": state, "result": "ok"])
    } else {
      fail("no-op", 3, json: ["result": "no-op"])
    }

  default:
    fatalError("unreachable")
  }
}
