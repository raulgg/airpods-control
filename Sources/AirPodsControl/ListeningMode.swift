enum ListeningMode: String, CaseIterable {
  case off
  case transparency
  case adaptive
  case noiseCancellation = "noise-cancellation"

  private static let aliases: [String: ListeningMode] = [
    "anc": .noiseCancellation,
    "nc": .noiseCancellation,
    "trans": .transparency,
    "automatic": .adaptive,
    "auto": .adaptive,
  ]

  init?(token: String) {
    guard let mode = ListeningMode(rawValue: token) ?? Self.aliases[token] else {
      return nil
    }
    self = mode
  }

  var displayName: String {
    switch self {
    case .off: return "Off"
    case .transparency: return "Transparency"
    case .adaptive: return "Adaptive"
    case .noiseCancellation: return "Noise cancellation"
    }
  }

  static func next(current: ListeningMode?, within cycle: [ListeningMode]) -> ListeningMode {
    guard let current, let start = allCases.firstIndex(of: current) else {
      return cycle[0]
    }
    for step in 1...allCases.count {
      let candidate = allCases[(start + step) % allCases.count]
      if cycle.contains(candidate) { return candidate }
    }
    return cycle[0]
  }
}

struct ListeningModeWriteResolution {
  let verified: Bool
  let state: ListeningMode?
  let inferredOffFallback: Bool
}

// A non-idempotent command verifies only when the provider accepted the setter
// and its bounded readback reports the requested state. CommandExecution handles
// an already-current target before it invokes this resolver.
func resolveListeningModeWrite(
  requested: ListeningMode,
  setterAccepted: Bool,
  observed: ListeningMode?,
  transparencySupported: Bool
) -> ListeningModeWriteResolution {
  let verified = setterAccepted && observed == requested
  let inferredOffFallback =
    requested == .off
    && !verified
    && setterAccepted
    && transparencySupported
    && observed != .transparency
  return ListeningModeWriteResolution(
    verified: verified,
    state: inferredOffFallback ? .transparency : observed,
    inferredOffFallback: inferredOffFallback
  )
}
