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
  static func execute(
    _ invocation: CLIInvocation,
    resolveDevice: (
      _ requestedName: String?,
      _ logger: DebugLogger
    ) -> (any CompatibleAudioDevice)?,
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

    guard let device = resolveDevice(invocation.requestedDeviceName, logger) else {
      return noDeviceOutcome(for: invocation.command)
    }

    switch invocation.command {
    case .version:
      preconditionFailure("version handled before device resolution")

    case let .supportReport(writeTestsPreference):
      return supportReport.outcome(writeTests: writeTestsPreference, device: device)

    case .listeningModeGet:
      let mode = device.currentListeningMode()
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: device.name,
        plain: mode?.rawValue ?? "unknown",
        result: "ok",
        state: mode?.rawValue
      )

    case .listeningModeList:
      let current = device.currentListeningMode()
      let availableModes = Set(device.availableListeningModes())
      let modes = ListeningMode.allCases.filter { availableModes.contains($0) }
      let tokens = modes.map(\.rawValue)
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: device.name,
        plain: tokens.joined(separator: ","),
        result: "ok",
        state: current?.rawValue,
        extra: ["supportedListeningModes": tokens]
      )

    case let .listeningModeSet(mode):
      let current = device.currentListeningMode()
      let availableModes = Set(device.availableListeningModes())

      guard availableModes.contains(mode), device.canSetListeningMode() else {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: device.name,
          plain: "unsupported",
          exitCode: 4,
          result: "error",
          state: current?.rawValue,
          error: "unsupported"
        )
      }

      if current == mode {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: device.name,
          plain: "ok",
          result: "ok",
          state: mode.rawValue
        )
      }

      let observation = device.setListeningModeAndReadBack(mode)
      let resolution = resolveListeningModeWrite(
        requested: mode,
        setterAccepted: observation.setterAccepted,
        observed: observation.observed,
        transparencySupported: availableModes.contains(.transparency)
      )
      if resolution.inferredOffFallback {
        logger.debug("verify.listening_mode.inferred_off_fallback", true)
      }

      if resolution.verified {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: device.name,
          plain: "ok",
          result: "ok",
          state: resolution.state?.rawValue
        )
      }
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: device.name,
        plain: "no-op",
        exitCode: 3,
        result: "no-op",
        state: resolution.state?.rawValue
      )

    case let .listeningModeCycle(requested):
      let current = device.currentListeningMode()
      let availableModes = Set(device.availableListeningModes())
      let base = requested ?? ListeningMode.allCases.filter { $0 != .off }
      let cycleModes = base.filter { availableModes.contains($0) }

      guard cycleModes.count >= 2, device.canSetListeningMode() else {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: device.name,
          plain: "unsupported",
          exitCode: 4,
          result: "error",
          state: current?.rawValue,
          error: "unsupported"
        )
      }

      let target = ListeningMode.next(current: current, within: cycleModes)
      logger.debug("cycle.set", cycleModes.map(\.rawValue).joined(separator: ","))
      logger.debug("cycle.target", target.rawValue)

      let observation = device.setListeningModeAndReadBack(target)
      let resolution = resolveListeningModeWrite(
        requested: target,
        setterAccepted: observation.setterAccepted,
        observed: observation.observed,
        transparencySupported: availableModes.contains(.transparency)
      )
      if resolution.inferredOffFallback {
        logger.debug("verify.listening_mode.inferred_off_fallback", true)
      }

      if resolution.verified {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: device.name,
          plain: target.rawValue,
          result: "ok",
          state: resolution.state?.rawValue
        )
      }
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: device.name,
        plain: "no-op",
        exitCode: 3,
        result: "no-op",
        state: resolution.state?.rawValue
      )

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

  private static func noDeviceOutcome(for command: CLICommand) -> CommandOutcome {
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
      plain: "no-device",
      exitCode: 1,
      result: "error",
      state: nil,
      error: "no-device",
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
