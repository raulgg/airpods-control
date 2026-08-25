import Foundation

struct CommandOutcome {
  let plain: String
  let exitCode: Int32
  let payload: [String: Any]
  let supportReport: SupportReportDocument?

  init(
    plain: String,
    exitCode: Int32 = 0,
    payload: [String: Any],
    supportReport: SupportReportDocument? = nil
  ) {
    self.plain = plain
    self.exitCode = exitCode
    self.payload = payload
    self.supportReport = supportReport
  }
}

enum CommandExecution {
  static func executeListeningMode(
    _ invocation: CLIInvocation,
    resolveSession: (
      _ command: ListeningModeCommand,
      _ requestedName: String?,
      _ logger: DebugLogger
    ) -> ListeningModeResolution
  ) -> CommandOutcome {
    guard let command = ListeningModeCommand(invocation.command) else {
      preconditionFailure("executeListeningMode requires a listening-mode command")
    }
    let logger = DebugLogger(enabled: invocation.debugEnabled)
    logger.debug("cli.command", invocation.command.debugName)
    logger.debug("cli.json", invocation.jsonOutput)
    logger.debug("cli.requested_device", invocation.requestedDeviceName)

    let resolution = resolveSession(command, invocation.requestedDeviceName, logger)
    let session: ListeningModeSession
    switch resolution {
    case .session(let resolved):
      session = resolved
    case .noDevice:
      return deviceResolutionFailureOutcome(
        for: invocation.command,
        plain: "no-device",
        error: "no-device"
      )
    case .ambiguousDevice:
      return deviceResolutionFailureOutcome(
        for: invocation.command,
        plain: "ambiguous-device",
        error: "ambiguous-device"
      )
    case .cancelled:
      return deviceResolutionFailureOutcome(
        for: invocation.command,
        plain: "cancelled",
        error: "cancelled"
      )
    }

    switch command {
    case .get:
      let mode = session.currentMode
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: session.name,
        plain: mode?.rawValue ?? "unknown",
        result: "ok",
        state: mode?.rawValue
      )

    case .list:
      let tokens = session.availableModes.map(\.rawValue)
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: session.name,
        plain: tokens.joined(separator: ","),
        result: "ok",
        state: session.currentMode?.rawValue,
        extra: ["supportedListeningModes": tokens]
      )

    case .set(let target):
      let stateIsSafe =
        session.transport.listeningModeTransportKind == .av
        || session.currentMode != nil
      guard stateIsSafe,
            session.availableModes.contains(target),
            session.canSet
      else {
        return unsupportedListeningModeOutcome(session: session)
      }

      if session.currentMode == target {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: session.name,
          plain: "ok",
          result: "ok",
          state: target.rawValue
        )
      }

      return listeningModeWriteOutcome(
        target: target,
        successPlain: "ok",
        session: session,
        logger: logger
      )

    case .cycle(let requested):
      let base = requested ?? ListeningMode.allCases.filter { $0 != .off }
      let cycleModes = base.filter { session.availableModes.contains($0) }
      let stateIsSafe =
        session.transport.listeningModeTransportKind == .av
        || session.currentMode != nil
      guard stateIsSafe, cycleModes.count >= 2, session.canSet else {
        return unsupportedListeningModeOutcome(session: session)
      }

      let target = ListeningMode.next(current: session.currentMode, within: cycleModes)
      logger.debug("cycle.set", cycleModes.map(\.rawValue).joined(separator: ","))
      logger.debug("cycle.target", target.rawValue)
      return listeningModeWriteOutcome(
        target: target,
        successPlain: target.rawValue,
        session: session,
        logger: logger
      )
    }
  }

  static func execute(
    _ invocation: CLIInvocation,
    resolveDevices: (
      _ requestedName: String?,
      _ policy: DeviceSelectionPolicy,
      _ logger: DebugLogger
    ) -> [any CompatibleAudioDevice]?,
    supportReport: SupportReportCommand = SupportReportCommand()
  ) -> CommandOutcome {
    let logger = DebugLogger(enabled: invocation.debugEnabled)
    logger.debug("cli.command", invocation.command.debugName)
    logger.debug("cli.json", invocation.jsonOutput)
    logger.debug("cli.requested_device", invocation.requestedDeviceName)

    if case .version = invocation.command {
      return CommandOutcome(
        plain: VERSION,
        payload: ["result": "ok", "version": VERSION]
      )
    }

    let selectionPolicy: DeviceSelectionPolicy
    if case .status = invocation.command {
      selectionPolicy = .allOrExact
    } else {
      selectionPolicy = .firstOrExact
    }

    guard let devices = resolveDevices(
      invocation.requestedDeviceName,
      selectionPolicy,
      logger
    ), !devices.isEmpty
    else {
      return deviceResolutionFailureOutcome(
        for: invocation.command,
        plain: "no-device",
        error: "no-device"
      )
    }

    if case .status = invocation.command {
      return StatusCommand.outcome(devices: devices)
    }

    let device = devices[0]

    switch invocation.command {
    case .version:
      preconditionFailure("version handled before device resolution")

    case .status:
      preconditionFailure("status handled after device resolution")

    case let .supportReport(writeTestsPreference):
      return supportReport.outcome(writeTests: writeTestsPreference, device: device)

    case .listeningModeGet, .listeningModeList,
      .listeningModeSet, .listeningModeCycle:
      preconditionFailure("listening-mode commands use executeListeningMode")

    case .conversationAwarenessGet:
      guard device.supportsConversationAwareness() == true,
            let enabled = device.conversationAwarenessState()
      else {
        return resourceOutcome(
          resource: .conversationAwareness,
          deviceName: device.name,
          plain: "unsupported",
          exitCode: 4,
          result: "error",
          state: nil,
          error: "unsupported"
        )
      }
      let state = enabled ? "on" : "off"
      return resourceOutcome(
        resource: .conversationAwareness,
        deviceName: device.name,
        plain: state,
        result: "ok",
        state: state
      )

    case let .conversationAwarenessSet(target):
      guard device.supportsConversationAwareness() == true,
            let current = device.conversationAwarenessState(),
            device.canSetConversationAwareness()
      else {
        return resourceOutcome(
          resource: .conversationAwareness,
          deviceName: device.name,
          plain: "unsupported",
          exitCode: 4,
          result: "error",
          state: nil,
          error: "unsupported"
        )
      }

      if current == target {
        let state = target ? "on" : "off"
        return resourceOutcome(
          resource: .conversationAwareness,
          deviceName: device.name,
          plain: "ok",
          result: "ok",
          state: state
        )
      }

      let observation = device.setConversationAwarenessAndReadBack(target)
      let observed = observation.observed.map { $0 ? "on" : "off" }
      if observation.observed == target {
        return resourceOutcome(
          resource: .conversationAwareness,
          deviceName: device.name,
          plain: "ok",
          result: "ok",
          state: observed
        )
      }
      return resourceOutcome(
        resource: .conversationAwareness,
        deviceName: device.name,
        plain: "no-op",
        exitCode: 3,
        result: "no-op",
        state: observed
      )
    }
  }

  private static func unsupportedListeningModeOutcome(
    session: ListeningModeSession
  ) -> CommandOutcome {
    resourceOutcome(
      resource: .listeningMode,
      deviceName: session.name,
      plain: "unsupported",
      exitCode: 4,
      result: "error",
      state: session.currentMode?.rawValue,
      error: "unsupported"
    )
  }

  private static func listeningModeWriteOutcome(
    target: ListeningMode,
    successPlain: String,
    session: ListeningModeSession,
    logger: DebugLogger
  ) -> CommandOutcome {
    let observation = session.transport.setListeningModeAndReadBack(target)
    let resolution = resolveListeningModeWrite(
      requested: target,
      setterAccepted: observation.setterAccepted,
      observed: observation.observed,
      transparencySupported: session.availableModes.contains(.transparency)
    )
    if resolution.inferredOffFallback {
      logger.debug("verify.listening_mode.inferred_off_fallback", true)
    }

    if resolution.verified {
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: session.name,
        plain: successPlain,
        result: "ok",
        state: resolution.state?.rawValue
      )
    }
    return resourceOutcome(
      resource: .listeningMode,
      deviceName: session.name,
      plain: "no-op",
      exitCode: 3,
      result: "no-op",
      state: resolution.state?.rawValue
    )
  }

  private static func deviceResolutionFailureOutcome(
    for command: CLICommand,
    plain: String,
    error: String
  ) -> CommandOutcome {
    if case .status = command {
      return StatusCommand.noDeviceOutcome()
    }
    if case .supportReport = command {
      return SupportReportCommand.noDeviceOutcome()
    }
    guard let resource = command.resource else {
      preconditionFailure("version does not require a device")
    }
    let extra: [String: Any]
    if case .listeningModeList = command {
      extra = ["supportedListeningModes": [String]()]
    } else {
      extra = [:]
    }
    return resourceOutcome(
      resource: resource,
      deviceName: nil,
      plain: plain,
      exitCode: 1,
      result: "error",
      state: nil,
      error: error,
      extra: extra
    )
  }

  private static func resourceOutcome(
    resource: CLIResource,
    deviceName: String?,
    plain: String,
    exitCode: Int32 = 0,
    result: String,
    state: String?,
    error: String? = nil,
    extra: [String: Any] = [:]
  ) -> CommandOutcome {
    var payload = extra
    payload["device"] = deviceName ?? NSNull()
    payload["result"] = result
    payload[resource.stateKey] = state ?? NSNull()
    if let error {
      payload["error"] = error
    }
    return CommandOutcome(
      plain: plain,
      exitCode: exitCode,
      payload: payload
    )
  }
}
