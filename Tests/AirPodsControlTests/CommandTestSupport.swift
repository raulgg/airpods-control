import Foundation

@testable import AirPodsControlCore

extension CommandOutcome {
  // Keep existing unit tests on their convenient Foundation view while the
  // production command path remains typed as JSONValue.
  var payload: [String: Any] {
    jsonPayload.reduce(into: [String: Any]()) { result, entry in
      result[entry.key] = entry.value.foundationValue
    }
  }
}

func commandOutcome(
  _ arguments: [String],
  device: any CompatibleAudioDevice
) throws -> CommandOutcome {
  let invocation = try parseInvocation(arguments)
  return CommandExecution.execute(invocation) { _, _ in device }
}

extension FakeCompatibleAudioDevice: ListeningModeTransport {
  var listeningModeTransportKind: ListeningModeTransportKind { .av }
}

extension CommandExecution {
  static func execute(
    _ invocation: CLIInvocation,
    resolveDevice: (
      _ requestedName: String?,
      _ logger: DebugLogger
    ) -> (any CompatibleAudioDevice)?,
    supportReport: SupportReportCommand = SupportReportCommand()
  ) -> CommandOutcome {
    if ListeningModeCommand(invocation.command) != nil {
      return executeListeningMode(
        invocation,
        resolveSession: { command, requestedName, logger in
          guard let transport = resolveDevice(requestedName, logger)
            as? any ListeningModeTransport
          else { return .failed(.noDevice) }
          let name = transport.name ?? "Compatible device"
          let coordinator = ListeningModeCoordinator(
            candidates: [
              ListeningModeCandidate(
                displayName: name,
                selectableNames: [name],
                avTransport: transport,
                halTransport: nil,
                route: .unknown
              )
            ],
            logger: logger
          )
          return coordinator.resolve(
            command: command,
            named: requestedName,
            chooseAmbiguous: { _ in .unavailable }
          )
        }
      )
    }
    return execute(
      invocation,
      resolveDevices: { requestedName, _, logger in
        guard let device = resolveDevice(requestedName, logger) else {
          return .failed(.noDevice)
        }
        return .devices([device])
      },
      supportReport: supportReport
    )
  }
}
