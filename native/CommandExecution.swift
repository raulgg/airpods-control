import Darwin
import Foundation

struct CommandOutcome {
  let plain: String
  let exitCode: Int32
  let payload: [String: Any]

  init(
    plain: String,
    exitCode: Int32 = 0,
    payload: [String: Any]
  ) {
    self.plain = plain
    self.exitCode = exitCode
    self.payload = payload
  }
}

enum CommandExecution {
  static func execute(
    _ invocation: CLIInvocation,
    resolveDevice: (
      _ requestedName: String?,
      _ logger: DebugLogger
    ) -> AudioDevice?
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

    case .listeningModeGet:
      let mode = canonicalListeningMode(device.currentListeningMode())
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: device.name,
        plain: mode ?? "unknown",
        result: "ok",
        state: mode
      )

    case .listeningModeList:
      let current = canonicalListeningMode(device.currentListeningMode())
      let availableModes = Set(device.availableListeningModes())
      let tokens = modeTokenOrder.filter { token in
        tokenToAV[token].map { availableModes.contains($0) } ?? false
      }
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: device.name,
        plain: tokens.joined(separator: ","),
        result: "ok",
        state: current,
        extra: ["supportedListeningModes": tokens]
      )

    case let .listeningModeSet(token, avMode):
      let currentRaw = device.currentListeningMode()
      let current = canonicalListeningMode(currentRaw)
      let availableModes = Set(device.availableListeningModes())

      guard availableModes.contains(avMode), device.canSetListeningMode() else {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: device.name,
          plain: "unsupported",
          exitCode: 4,
          result: "error",
          state: current,
          error: "unsupported"
        )
      }

      if currentRaw == avMode {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: device.name,
          plain: "ok",
          result: "ok",
          state: token
        )
      }

      let outcome = device.setListeningModeAndReadBack(avMode)
      let resolution = resolveListeningModeWrite(
        requestedToken: token,
        setterAccepted: outcome.setterAccepted,
        observedRawMode: outcome.observedRawMode,
        transparencySupported: availableModes.contains(tokenToAV["transparency"]!)
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
          state: resolution.state
        )
      }
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: device.name,
        plain: "no-op",
        exitCode: 3,
        result: "no-op",
        state: resolution.state
      )

    case let .listeningModeCycle(requested):
      let currentRaw = device.currentListeningMode()
      let current = canonicalListeningMode(currentRaw)
      let availableModes = Set(device.availableListeningModes())
      let base = requested ?? modeTokenOrder.filter { $0 != "off" }
      let cycleTokens = base.filter { token in
        tokenToAV[token].map { availableModes.contains($0) } ?? false
      }

      guard cycleTokens.count >= 2, device.canSetListeningMode() else {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: device.name,
          plain: "unsupported",
          exitCode: 4,
          result: "error",
          state: current,
          error: "unsupported"
        )
      }

      let targetToken = nextCycleMode(current: current, cycleTokens: cycleTokens)
      let targetAV = tokenToAV[targetToken]!
      logger.debug("cycle.set", cycleTokens.joined(separator: ","))
      logger.debug("cycle.target", targetToken)

      let outcome = device.setListeningModeAndReadBack(targetAV)
      let resolution = resolveListeningModeWrite(
        requestedToken: targetToken,
        setterAccepted: outcome.setterAccepted,
        observedRawMode: outcome.observedRawMode,
        transparencySupported: availableModes.contains(tokenToAV["transparency"]!)
      )
      if resolution.inferredOffFallback {
        logger.debug("verify.listening_mode.inferred_off_fallback", true)
      }

      if resolution.verified {
        return resourceOutcome(
          resource: .listeningMode,
          deviceName: device.name,
          plain: targetToken,
          result: "ok",
          state: resolution.state
        )
      }
      return resourceOutcome(
        resource: .listeningMode,
        deviceName: device.name,
        plain: "no-op",
        exitCode: 3,
        result: "no-op",
        state: resolution.state
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

      let outcome = setAndObserveConversationAwareness(
        device: device,
        target: target,
        logger: logger
      )
      let observed = outcome.observed.map { $0 ? "on" : "off" }
      if outcome.verified {
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

  private static func setAndObserveConversationAwareness(
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
}
