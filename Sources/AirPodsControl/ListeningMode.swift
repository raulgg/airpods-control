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

  // Cycle order for listening-mode cycle, matching the Apple listening-mode
  // control: Off, Transparency, Adaptive, Noise Cancellation. Off is first
  // only when the cycle set includes it; next skips modes absent from the set.
  static let cycleOrder: [ListeningMode] = [
    .off, .transparency, .adaptive, .noiseCancellation,
  ]

  static func next(
    current: ListeningMode?,
    within cycle: [ListeningMode],
    order: ListeningModeCycleOrder = .cycle
  ) -> ListeningMode {
    switch order {
    case .listed:
      guard let current, let start = cycle.firstIndex(of: current) else {
        return cycle[0]
      }
      return cycle[(start + 1) % cycle.count]
    case .cycle:
      guard let current, let start = cycleOrder.firstIndex(of: current) else {
        return cycle[0]
      }
      for step in 1...cycleOrder.count {
        let candidate = cycleOrder[(start + step) % cycleOrder.count]
        if cycle.contains(candidate) { return candidate }
      }
      return cycle[0]
    }
  }
}

enum ListeningModeCycleOrder: Equatable {
  case cycle
  case listed
}

enum ListeningModeCycleRequest: Equatable {
  case defaultCycle
  case subset([ListeningMode])
  case listed([ListeningMode])

  var modes: [ListeningMode]? {
    switch self {
    case .defaultCycle:
      return nil
    case let .subset(modes), let .listed(modes):
      return modes
    }
  }

  var order: ListeningModeCycleOrder {
    switch self {
    case .defaultCycle, .subset(_):
      return .cycle
    case .listed(_):
      return .listed
    }
  }
}

struct ListeningModeWriteResolution {
  let setterAccepted: Bool
  let verified: Bool
  let state: ListeningMode?
  let inferredOffFallback: Bool
  let probeDenied: Bool
}

// A non-idempotent command verifies only when the provider accepted the setter
// and its bounded readback reports the requested state. CommandExecution handles
// an already-current target before it invokes this resolver.
func resolveListeningModeWrite(
  requested: ListeningMode,
  setterAccepted: Bool,
  observed: ListeningMode?,
  transparencySupported: Bool,
  probeDenied: Bool = false
) -> ListeningModeWriteResolution {
  let verified = setterAccepted && observed == requested
  let inferredOffFallback =
    requested == .off
      && !verified
      && setterAccepted
      && transparencySupported
      && observed != .transparency
  return ListeningModeWriteResolution(
    setterAccepted: setterAccepted,
    verified: verified,
    state: inferredOffFallback ? .transparency : observed,
    inferredOffFallback: inferredOffFallback,
    probeDenied: probeDenied
  )
}
