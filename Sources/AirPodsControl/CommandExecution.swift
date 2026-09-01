import Foundation

struct CommandOutcome {
  let plain: String
  let terminalReason: TerminalReason
  let data: [String: Any]
  let supportReport: SupportReportDocument?

  init(
    plain: String,
    terminalReason: TerminalReason = .success,
    data: [String: Any] = [:],
    supportReport: SupportReportDocument? = nil
  ) {
    self.plain = plain
    self.terminalReason = terminalReason
    self.data = data
    self.supportReport = supportReport
  }

  var exitCode: Int32 { terminalReason.exitCode }
  var payload: [String: Any] { terminalReason.addingEnvelope(to: data) }
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
    case let .failed(reason):
      return deviceResolutionFailureOutcome(
        for: invocation.command,
        reason: reason
      )
    }

    switch command {
    case .get:
      let mode: ListeningMode?
      switch session.stateObservation {
      case let .value(value): mode = value
      case .unknown: mode = nil
      case .unavailable:
        return listeningModeFailureOutcome(.unavailable, session: session)
      case .readError:
        return listeningModeFailureOutcome(.readError, session: session)
      }
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: session.name,
        plain: mode?.rawValue ?? "unknown",
        state: mode?.rawValue,
        extra: listeningModeExtra(for: session)
      )

    case .list:
      switch session.availabilityObservation {
      case .value, .partial: break
      case .unavailable, .none:
        return listeningModeFailureOutcome(.unavailable, session: session)
      case .readError:
        return listeningModeFailureOutcome(.readError, session: session)
      }
      let tokens = session.availableModes.map(\.rawValue)
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: session.name,
        plain: tokens.joined(separator: ","),
        state: session.currentMode?.rawValue,
        extra: listeningModeExtra(
          for: session,
          adding: ["supportedListeningModes": tokens]
        )
      )

    case .set(let target):
      guard let writePlan = session.writePlan else {
        return listeningModeFailureOutcome(.unavailable, session: session)
      }
      guard writePlan.canWrite(target) else {
        let reason: TerminalReason
        switch session.availabilityObservation {
        case .value: reason = .unsupported
        case .partial, .unavailable, .readError, .none: reason = .unavailable
        }
        return listeningModeFailureOutcome(reason, session: session)
      }

      if session.currentMode == target {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: session.name,
          plain: "ok",
          state: target.rawValue,
          extra: listeningModeExtra(for: session)
        )
      }

      return listeningModeWriteOutcome(
        target: target,
        successPlain: "ok",
        session: session,
        writePlan: writePlan,
        logger: logger
      )

    case .cycle(let requested):
      let base = requested ?? ListeningMode.allCases.filter { $0 != .off }
      let cycleModes = base.filter { session.availableModes.contains($0) }
      guard let writePlan = session.writePlan else {
        return listeningModeFailureOutcome(.unavailable, session: session)
      }
      guard cycleModes.count >= 2 else {
        let reason: TerminalReason
        switch session.availabilityObservation {
        case .value: reason = .unsupported
        case .partial, .unavailable, .readError, .none: reason = .unavailable
        }
        return listeningModeFailureOutcome(reason, session: session)
      }

      let target = ListeningMode.next(current: session.currentMode, within: cycleModes)
      logger.debug("cycle.set", cycleModes.map(\.rawValue).joined(separator: ","))
      logger.debug("cycle.target", target.rawValue)
      return listeningModeWriteOutcome(
        target: target,
        successPlain: target.rawValue,
        session: session,
        writePlan: writePlan,
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
    ) -> CommandDeviceResolution,
    supportReport: SupportReportCommand = SupportReportCommand()
  ) -> CommandOutcome {
    let logger = DebugLogger(enabled: invocation.debugEnabled)
    logger.debug("cli.command", invocation.command.debugName)
    logger.debug("cli.json", invocation.jsonOutput)
    logger.debug("cli.requested_device", invocation.requestedDeviceName)

    if case .version = invocation.command {
      return CommandOutcome(
        plain: VERSION,
        data: ["version": VERSION]
      )
    }

    let selectionPolicy: DeviceSelectionPolicy
    if case .status = invocation.command {
      selectionPolicy = .allOrExact
    } else {
      selectionPolicy = .singleOrExact
    }

    let resolution = resolveDevices(
      invocation.requestedDeviceName,
      selectionPolicy,
      logger
    )
    let devices: [any CompatibleAudioDevice]
    switch resolution {
    case let .devices(resolved):
      precondition(!resolved.isEmpty, "successful device resolution must not be empty")
      devices = resolved
    case let .failed(reason):
      return deviceResolutionFailureOutcome(for: invocation.command, reason: reason)
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
      let enabled: Bool
      switch device.readConversationAwarenessStatus() {
      case let .value(value): enabled = value
      case .unsupported:
        return conversationAwarenessFailure(.unsupported, device: device)
      case .unresolved:
        return conversationAwarenessFailure(.unavailable, device: device)
      case .readError:
        return conversationAwarenessFailure(.readError, device: device)
      }
      let state = enabled ? "on" : "off"
      return resourceOutcome(
        resource: .conversationAwareness,
        deviceName: device.name,
        plain: state,
        state: state
      )

    case let .conversationAwarenessSet(target):
      let current: Bool
      switch device.readConversationAwarenessStatus() {
      case let .value(value): current = value
      case .unsupported:
        return conversationAwarenessFailure(.unsupported, device: device)
      case .unresolved, .readError:
        return conversationAwarenessFailure(.unavailable, device: device)
      }
      guard device.canSetConversationAwareness() else {
        return conversationAwarenessFailure(.unavailable, device: device)
      }

      if current == target {
        let state = target ? "on" : "off"
        return resourceOutcome(
          resource: .conversationAwareness,
          deviceName: device.name,
          plain: "ok",
          state: state
        )
      }

      let observation = device.setConversationAwarenessAndReadBack(target)
      let observed = observation.observed.map { $0 ? "on" : "off" }
      guard observation.setterAccepted else {
        return resourceOutcome(
          resource: .conversationAwareness,
          deviceName: device.name,
          plain: TerminalReason.unavailable.token,
          terminalReason: .unavailable,
          state: observed
        )
      }
      if observation.observed == target {
        return resourceOutcome(
          resource: .conversationAwareness,
          deviceName: device.name,
          plain: "ok",
          state: observed
        )
      }
      return resourceOutcome(
        resource: .conversationAwareness,
        deviceName: device.name,
        plain: "no-op",
        terminalReason: .noOp,
        state: observed
      )
    }
  }

  private static func listeningModeFailureOutcome(
    _ reason: TerminalReason,
    session: ListeningModeSession
  ) -> CommandOutcome {
    precondition(
      reason == .unsupported || reason == .unavailable || reason == .readError
    )
    return resourceOutcome(
      resource: .listeningMode,
      deviceName: session.name,
      plain: reason.token,
      terminalReason: reason,
      state: session.currentMode?.rawValue,
      extra: listeningModeExtra(for: session)
    )
  }

  private static func conversationAwarenessFailure(
    _ reason: TerminalReason,
    device: any CompatibleAudioDevice
  ) -> CommandOutcome {
    return resourceOutcome(
      resource: .conversationAwareness,
      deviceName: device.name,
      plain: reason.token,
      terminalReason: reason,
      state: nil
    )
  }

  private static func listeningModeWriteOutcome(
    target: ListeningMode,
    successPlain: String,
    session: ListeningModeSession,
    writePlan: ListeningModeWritePlan,
    logger: DebugLogger
  ) -> CommandOutcome {
    let resolution = writePlan.execute(target)
    if resolution.inferredOffFallback {
      logger.debug("verify.listening_mode.inferred_off_fallback", true)
    }

    guard resolution.setterAccepted else {
      return listeningModeFailureOutcome(.unavailable, session: session)
    }
    if resolution.probeDenied {
      return listeningModeFailureOutcome(.unsupported, session: session)
    }
    if resolution.verified {
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: session.name,
        plain: successPlain,
        state: resolution.state?.rawValue,
        extra: listeningModeExtra(for: session)
      )
    }
    return resourceOutcome(
      resource: .listeningMode,
      deviceName: session.name,
      plain: "no-op",
      terminalReason: .noOp,
      state: resolution.state?.rawValue,
      extra: listeningModeExtra(for: session)
    )
  }

  private static func deviceResolutionFailureOutcome(
    for command: CLICommand,
    reason: TerminalReason
  ) -> CommandOutcome {
    precondition(
      reason == .noDevice || reason == .ambiguousDevice
        || reason == .unavailable || reason == .readError
    )
    if case .status = command {
      return StatusCommand.resolutionFailureOutcome(reason)
    }
    if case .supportReport = command {
      return SupportReportCommand.resolutionFailureOutcome(reason)
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
      plain: reason.token,
      terminalReason: reason,
      state: nil,
      extra: extra
    )
  }

  private static func resourceOutcome(
    resource: CLIResource,
    deviceName: String?,
    plain: String,
    terminalReason: TerminalReason = .success,
    state: String?,
    extra: [String: Any] = [:]
  ) -> CommandOutcome {
    var payload = extra
    payload["device"] = deviceName ?? NSNull()
    payload[resource.stateKey] = state ?? NSNull()
    return CommandOutcome(
      plain: plain,
      terminalReason: terminalReason,
      data: payload
    )
  }

  private static func listeningModeExtra(
    for session: ListeningModeSession,
    adding extra: [String: Any] = [:]
  ) -> [String: Any] {
    var result = extra
    guard let evidence = session.cachedAllowOffEvidence else {
      return result
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    result["allowOffAvailability"] = [
      "source": "cached-av-observation",
      "observedAt": formatter.string(from: evidence.observedAt),
      "expiresAt": formatter.string(from: evidence.expiresAt),
    ]
    return result
  }
}
