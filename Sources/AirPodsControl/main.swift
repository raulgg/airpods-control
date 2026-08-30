// airpods-control — control AirPods listening mode and Conversation Awareness
// from a scriptable command-line interface.
//
// Compiled with swiftc (no Xcode needed) + a tiny C bypass dylib. On launch it
// re-execs itself once with avbypass.dylib inserted so the in-process
// entitlement gate for the shared system audio context is satisfied — the same
// technique NoiseBuddy uses. The executable and companion dylib are ad-hoc
// signed.

import Darwin
import Foundation
import BypassProbe

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
    if AirPodsControlBypassIsActive() {
      logger.debug("bypass.status", "active")
    } else {
      logger.warning("bypass.status", "inactive")
    }
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

func bootstrapAndResolveAudioDevices(
  named requestedName: String?,
  policy: DeviceSelectionPolicy,
  logger: DebugLogger,
  accessPolicy: PrivateAudioAccessPolicy
) -> [any CompatibleAudioDevice]? {
  ensureBypass(logger: logger)

  switch accessPolicy {
  case .operational:
    guard let endpoints = PrivateAudioDiscovery.systemOperationalEndpoints(
      logger: logger
    ) else { return nil }
    return PrivateAudioController(endpoints: endpoints, logger: logger)
      .selectDevices(named: requestedName, policy: policy)

  case .status:
    let activeOutputContext = PrivateAudioDiscovery.systemStatusOutputContext(
      logger: logger
    )
    guard let controller = IOBluetoothStatusController(
      logger: logger,
      activeOutputContext: activeOutputContext
    ), let devices = controller.selectDevices(named: requestedName, policy: policy)
    else { return nil }
    return devices.map { $0 }

  case .supportReport:
    // Preserve the name-free, plural-only support-report discovery contract.
    // In particular, do not query outputDevice or private device identifiers.
    guard let devices = PrivateAudioDiscovery.systemOutputDevices(logger: logger) else {
      return nil
    }
    return PrivateAudioController(
      rawDevices: devices,
      logger: logger,
      includeDeviceNames: false
    ).selectDevices(named: requestedName, policy: policy)
  }
}

func bootstrapAndResolveListeningMode(
  command: ListeningModeCommand,
  invocation: CLIInvocation,
  logger: DebugLogger
) -> ListeningModeResolution {
  ensureBypass(logger: logger)

  let outputContext = PrivateAudioDiscovery.systemStatusOutputContext(logger: logger)
  let avDevices: [PrivateAudioDevice]
  if let outputContext {
    let endpoints = PrivateAudioDiscovery.contextEndpoints(
      from: outputContext,
      logger: logger
    )
    avDevices = PrivateAudioController(endpoints: endpoints, logger: logger)
      .selectDevices(named: nil, policy: .allOrExact) ?? []
  } else {
    avDevices = []
  }

  let allowOffCache = PersistentListeningModeAllowOffCache.systemDefault()

  let halCandidates = IOBluetoothStatusController(
    logger: logger,
    activeOutputContext: outputContext,
    readStatusListeningMode: false,
    readStatusInEarPlacement: false,
    allowOffCache: allowOffCache
  )?.listeningModeCandidates() ?? []
  let coordinator = ListeningModeCoordinator(
    avDevices: avDevices,
    halCandidates: halCandidates,
    logger: logger
  )

  return coordinator.resolve(
    command: command,
    named: invocation.requestedDeviceName,
    chooseAmbiguous: { names in
      let inputIsTerminal = isatty(STDIN_FILENO) == 1
      let errorIsTerminal = isatty(STDERR_FILENO) == 1
      guard inputIsTerminal, errorIsTerminal, !invocation.jsonOutput else {
        return .unavailable
      }

      let outcome = InteractiveDeviceChooser.choose(
        deviceNames: names,
        eligibility: .init(
          inputIsTerminal: inputIsTerminal,
          errorIsTerminal: errorIsTerminal,
          jsonOutput: invocation.jsonOutput
        ),
        readResponse: { readLine() },
        writeError: { text in
          fputs(text, stderr)
          fflush(stderr)
        }
      )
      switch outcome {
      case let .selected(index): return .selected(index: index)
      case .cancelled: return .cancelled
      }
    }
  )
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

let supportReport = SupportReportCommand(
  requestWriteTestConsent: { plan in
    SupportReportInteraction.requestWriteTestConsent(plan: plan)
  },
  runWriteTests: { plan, device in
    let progress = SupportReportProgressDisplay(
      plan: plan,
      debugEnabled: invocation.debugEnabled
    )
    return SupportReportWriteTester.runInterruptibly(
      plan: plan,
      device: device,
      progress: { progress?.receive($0) }
    )
  }
)

let outcome: CommandOutcome
if ListeningModeCommand(invocation.command) != nil {
  outcome = CommandExecution.executeListeningMode(
    invocation,
    resolveSession: { command, _, logger in
      bootstrapAndResolveListeningMode(
        command: command,
        invocation: invocation,
        logger: logger
      )
    }
  )
} else {
  outcome = CommandExecution.execute(
    invocation,
    resolveDevices: { requestedName, policy, logger in
      let accessPolicy: PrivateAudioAccessPolicy
      if case .supportReport = invocation.command {
        accessPolicy = .supportReport
      } else if case .status = invocation.command {
        accessPolicy = .status
      } else {
        accessPolicy = .operational
      }
      return bootstrapAndResolveAudioDevices(
        named: requestedName,
        policy: policy,
        logger: logger,
        accessPolicy: accessPolicy
      )
    },
    supportReport: supportReport
  )
}
if case .supportReport = invocation.command {
  exit(SupportReportInteraction.present(outcome: outcome))
}
finish(outcome, jsonOutput: invocation.jsonOutput)
