import Foundation

// Off gating switches exhaustively over this enum instead of testing for nil,
// so a new case has to state whether it grants a privileged Off write.
enum ListeningModeOffPermission {
  case authorized(ListeningModeAllowOffAuthorization)
  case probe
}

struct ListeningModePreflightFacts {
  let observedAt: Date?
  let stateObservation: ListeningModeStateObservation
  let availabilityObservation: ListeningModeAvailabilityObservation

  var availableModes: [ListeningMode] {
    ListeningModePreflightPolicy.normalizedModes(from: availabilityObservation)
  }
}

enum ListeningModePreflightPolicy {
  static func normalizedModes(
    from observation: ListeningModeAvailabilityObservation
  ) -> [ListeningMode] {
    let modes: [ListeningMode]
    switch observation {
    case let .value(value), let .partial(value): modes = value
    case .unavailable, .readError: return []
    }
    let advertised = Set(modes)
    return ListeningMode.allCases.filter { advertised.contains($0) }
  }

  static func commandExplicitlyTargetsOff(_ command: ListeningModeCommand) -> Bool {
    switch command {
    case .set(.off): return true
    case let .cycle(requested): return requested?.contains(.off) == true
    case .get, .list, .set: return false
    }
  }

  static func commandMayUseAllowOffCache(_ command: ListeningModeCommand) -> Bool {
    switch command {
    case .list:
      return true
    case .set(.off):
      return true
    case .cycle(let requested):
      return requested?.contains(.off) == true
    case .get, .set:
      return false
    }
  }

  static func availabilityBlocksCachedAllowOff(
    _ availability: ListeningModeAvailabilityObservation,
    transportKind: ListeningModeTransportKind,
    command: ListeningModeCommand
  ) -> Bool {
    guard transportKind == .av,
          commandMayUseAllowOffCache(command),
          case .value(let modes) = availability
    else { return false }
    return !modes.contains(.off)
  }

  static func effectiveModes(
    availableModes: [ListeningMode],
    offPermission: ListeningModeOffPermission?
  ) -> [ListeningMode] {
    switch offPermission {
    case .authorized, .probe:
      let advertised = Set(availableModes).union([.off])
      return ListeningMode.allCases.filter { advertised.contains($0) }
    case .none:
      return availableModes
    }
  }
}

enum ListeningModeCyclePolicy {
  static func supportedModes(
    requested: [ListeningMode]?,
    available: [ListeningMode]
  ) -> [ListeningMode] {
    let base = requested ?? ListeningMode.allCases.filter { $0 != .off }
    return base.filter { available.contains($0) }
  }
}
