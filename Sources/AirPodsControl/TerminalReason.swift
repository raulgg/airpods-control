import Foundation

enum TerminalReason: Equatable {
  case success
  case noDevice
  case badArgs
  case noOp
  case unsupported
  case readError
  case unavailable
  case stateUncertain
  case ambiguousDevice
  case caughtSignal(Int32)

  var exitCode: Int32 {
    switch self {
    case .success: return 0
    case .noDevice: return 1
    case .badArgs: return 2
    case .noOp: return 3
    case .unsupported: return 4
    case .readError: return 5
    case .unavailable: return 6
    case .stateUncertain: return 7
    case .ambiguousDevice: return 8
    case let .caughtSignal(signal): return 128 + signal
    }
  }

  var token: String {
    switch self {
    case .success: return "success"
    case .noDevice: return "no-device"
    case .badArgs: return "bad-args"
    case .noOp: return "no-op"
    case .unsupported: return "unsupported"
    case .readError: return "read-error"
    case .unavailable: return "unavailable"
    case .stateUncertain: return "state-uncertain"
    case .ambiguousDevice: return "ambiguous-device"
    case .caughtSignal: return "interrupted"
    }
  }

  func addingEnvelope(to data: [String: Any]) -> [String: Any] {
    let reservedKeys = ["result", "error", "signal"]
    precondition(
      reservedKeys.allSatisfy { data[$0] == nil },
      "command data must not contain terminal envelope keys"
    )

    var payload = data
    switch self {
    case .success:
      payload["result"] = "ok"
    case .noOp:
      payload["result"] = "no-op"
    case let .caughtSignal(signal):
      payload["result"] = "interrupted"
      payload["signal"] = signal
    case .noDevice, .badArgs, .unsupported, .readError,
      .unavailable, .stateUncertain, .ambiguousDevice:
      payload["result"] = "error"
      payload["error"] = token
    }
    return payload
  }
}
