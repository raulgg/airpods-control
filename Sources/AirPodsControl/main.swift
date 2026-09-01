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
  terminalReason: TerminalReason = .success,
  jsonOutput: Bool,
  data: [String: Any] = [:]
) -> Never {
  if jsonOutput {
    writeJSON(terminalReason.addingEnvelope(to: data))
  } else {
    print(plain)
  }
  exit(terminalReason.exitCode)
}

func finish(_ outcome: CommandOutcome, jsonOutput: Bool) -> Never {
  finish(
    plain: outcome.plain,
    terminalReason: outcome.terminalReason,
    jsonOutput: jsonOutput,
    data: outcome.data
  )
}

func bootstrapAndResolveAudioDevices(
  named requestedName: String?,
  policy: DeviceSelectionPolicy,
  logger: DebugLogger,
  accessPolicy: PrivateAudioAccessPolicy
) -> CommandDeviceResolution {
  ensureBypass(logger: logger)

  switch accessPolicy {
  case .operational:
    guard let endpoints = PrivateAudioDiscovery.systemOperationalEndpoints(
      logger: logger
    ) else { return .failed(.unavailable) }
    switch PrivateAudioController(endpoints: endpoints, logger: logger)
      .resolveDevices(named: requestedName, policy: policy)
    {
    case let .selected(devices): return .devices(devices.map { $0 })
    case .noDevice: return .failed(.noDevice)
    case .ambiguousDevice: return .failed(.ambiguousDevice)
    }

  case .status:
    preconditionFailure("status uses bootstrapStatusSession")

  case .supportReport:
    // Preserve the name-free, plural-only support-report discovery contract.
    // In particular, do not query outputDevice or private device identifiers.
    guard let devices = PrivateAudioDiscovery.systemOutputDevices(logger: logger) else {
      return .failed(.unavailable)
    }
    switch PrivateAudioController(
      rawDevices: devices,
      logger: logger,
      includeDeviceNames: false
    ).resolveDevices(named: requestedName, policy: policy) {
    case let .selected(devices): return .devices(devices.map { $0 })
    case .noDevice: return .failed(.noDevice)
    case .ambiguousDevice: return .failed(.ambiguousDevice)
    }
  }
}

func bootstrapStatusSession(logger: DebugLogger) -> StatusSessionResolution {
  ensureBypass(logger: logger)
  let activeOutputContext = PrivateAudioDiscovery.systemStatusOutputContext(
    logger: logger
  )
  let store = PersistentBluetoothAssociationStore.systemDefault()
  var document: BluetoothSettingsDocument?
  if let store {
    switch store.load() {
    case let .value(value): document = value
    case .missing: document = nil
    case .invalid:
      logger.warning("bluetooth.settings", "invalid")
      document = nil
    }
  } else {
    logger.warning("bluetooth.settings", "location-unavailable")
    document = nil
  }
  let scanner = SystemBluetoothScanner()
  let bluetoothEnabled = document?.enabled == true
  let bluetoothAuthorized = scanner.authorization() == .authorized
  let bluetoothUsable = bluetoothEnabled && bluetoothAuthorized
  let controller: IOBluetoothStatusController
  switch IOBluetoothStatusController.create(
    logger: logger,
    activeOutputContext: activeOutputContext,
    readBluetoothCorrelationMetadata: bluetoothUsable
  ) {
  case let .success(value): controller = value
  case .unavailable: return .failed(.unavailable)
  case .readError: return .failed(.readError)
  }

  let devices = controller.statusDevices()
  let hal = devices.map { device in
    StatusHALRecord(
      device: device,
      target: document?.target(
        name: device.name,
        correlation: controller.bluetoothCorrelation(for: device),
        placement: device.readInEarPlacementStatus()
      )
    )
  }
  var observations: [BluetoothPeripheralObservation] = []
  if bluetoothUsable, var learned = document {
    let scan = scanner.scan(duration: BluetoothScan.duration)
    let advertisements = scan.radio == .poweredOn ? scan.advertisements : []
    observations = AirPodsBLEScanNormalizer.normalize(advertisements)
    learned = BluetoothLearning.learn(
      document: learned,
      targets: hal.compactMap(\.target),
      observations: observations,
      conflictingProductIDs: BluetoothLearning.conflictingProductIDs(
        advertisements
      ),
      now: Date()
    )
    if learned != document, let store {
      do {
        try store.save(learned)
      } catch {
        logger.warning("bluetooth.settings", "write-error")
      }
    }
    document = learned
  }

  return .session(
    StatusSession(
      hal: hal,
      document: document,
      observations: observations,
      bluetoothUsable: bluetoothUsable
    )
  )
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

  let halCandidates: [ListeningModeCandidate]
  switch IOBluetoothStatusController.create(
    logger: logger,
    activeOutputContext: outputContext,
    readStatusListeningMode: false,
    readStatusInEarPlacement: false,
    allowOffCache: allowOffCache
  ) {
  case let .success(controller): halCandidates = controller.listeningModeCandidates()
  case .unavailable, .readError: halCandidates = []
  }
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
      case .declined: return .unavailable
      }
    }
  )
}

let rawArgs = Array(CommandLine.arguments.dropFirst())

if rawArgs.isEmpty {
  finish(plain: globalHelp, jsonOutput: false)
}

if let help = helpText(for: rawArgs) {
  finish(plain: help, jsonOutput: false)
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
    terminalReason: .badArgs,
    jsonOutput: preliminaryJSON
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
if BluetoothCommandKind(invocation.command) != nil {
  if let store = PersistentBluetoothAssociationStore.systemDefault() {
    let logger = DebugLogger(enabled: invocation.debugEnabled)
    outcome = CommandExecution.executeBluetooth(
      invocation,
      store: store,
      scanner: SystemBluetoothScanner(),
      resolveStatusInventory: {
        switch IOBluetoothStatusController.create(
          logger: logger,
          activeOutputContext: nil,
          readStatusListeningMode: false,
          readStatusInEarPlacement: true,
          readBluetoothCorrelationMetadata: true
        ) {
        case let .success(controller):
          return (
            controller.statusDevices(),
            controller.bluetoothCorrelation(for:)
          )
        case .unavailable, .readError:
          return ([], { _ in nil })
        }
      },
      interactive: isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1,
      readResponse: { readLine() },
      writePrompt: { text in
        fputs(text, stderr)
        fflush(stderr)
      }
    )
  } else {
    outcome = CommandOutcome(
      plain: "bluetooth-settings",
      terminalReason: .unavailable,
      data: ["detail": "bluetooth-settings"]
    )
  }
} else if ListeningModeCommand(invocation.command) != nil {
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
} else if case .status = invocation.command {
  outcome = CommandExecution.executeStatus(invocation) { logger in
    bootstrapStatusSession(logger: logger)
  }
} else {
  outcome = CommandExecution.execute(
    invocation,
    resolveDevices: { requestedName, policy, logger in
      let accessPolicy: PrivateAudioAccessPolicy
      if case .supportReport = invocation.command {
        accessPolicy = .supportReport
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
  exit(SupportReportInteraction.present(outcome: outcome).exitCode)
}
finish(outcome, jsonOutput: invocation.jsonOutput)
