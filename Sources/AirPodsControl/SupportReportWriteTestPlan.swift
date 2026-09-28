enum SupportReportCapabilityPlan<Payload> {
  case skipped(reason: String)
  case willTest(Payload)
}

struct ListeningModeWriteTestPlan {
  let initial: ListeningMode
  let advertised: [ListeningMode]

  var targets: [ListeningMode] {
    // The already-current first probe is the captured initial mode; restoration
    // demonstrates it later. Keep it when it sits later in the sequence so an
    // Off fallback cannot skip a real Transparency transition.
    if advertised.first == initial {
      return Array(advertised.dropFirst())
    }
    return advertised
  }
}

struct SupportReportWriteTestPlan {
  let listeningModes: SupportReportCapabilityPlan<ListeningModeWriteTestPlan>
  let conversationAwareness: SupportReportCapabilityPlan<Bool>

  var listeningModeTargets: [ListeningMode] {
    switch listeningModes {
    case .skipped:
      return []
    case let .willTest(payload):
      return payload.targets
    }
  }

  var willTestListeningModes: Bool {
    if case .willTest = listeningModes { return true }
    return false
  }

  var willTestConversationAwareness: Bool {
    if case .willTest = conversationAwareness { return true }
    return false
  }

  // Preserves the more specific reasons already recorded by planning.
  func skippingAll(reason: String) -> SupportReportWriteTestPlan {
    SupportReportWriteTestPlan(
      listeningModes: Self.skipIfTesting(listeningModes, reason: reason),
      conversationAwareness: Self.skipIfTesting(conversationAwareness, reason: reason)
    )
  }

  static func make(device: any CompatibleAudioDevice) -> SupportReportWriteTestPlan {
    let advertised = Set(device.availableListeningModes())
    // Off may fall back to Transparency. Probe stronger modes first so that
    // fallback cannot make the Transparency write already-current.
    let orderedModes = Array(ListeningMode.allCases.reversed()).filter {
      advertised.contains($0)
    }
    let initialMode = device.currentListeningMode()
    let initialConversationAwareness = device.conversationAwarenessState()
    return SupportReportWriteTestPlan(
      listeningModes: listeningModePlan(
        device: device,
        advertised: advertised,
        orderedModes: orderedModes,
        initialMode: initialMode
      ),
      conversationAwareness: conversationAwarenessPlan(
        device: device,
        initialState: initialConversationAwareness
      )
    )
  }

  private static func skipIfTesting<Payload>(
    _ plan: SupportReportCapabilityPlan<Payload>,
    reason: String
  ) -> SupportReportCapabilityPlan<Payload> {
    switch plan {
    case .skipped:
      return plan
    case .willTest:
      return .skipped(reason: reason)
    }
  }

  private static func listeningModePlan(
    device: any CompatibleAudioDevice,
    advertised: Set<ListeningMode>,
    orderedModes: [ListeningMode],
    initialMode: ListeningMode?
  ) -> SupportReportCapabilityPlan<ListeningModeWriteTestPlan> {
    if !device.canSetListeningMode() {
      return .skipped(reason: "setter not exposed")
    }
    if orderedModes.isEmpty {
      return .skipped(reason: "no recognized advertised modes")
    }
    guard let initialMode else {
      return .skipped(reason: "initial state unreadable, nothing written")
    }
    if !advertised.contains(initialMode) {
      return .skipped(reason: "initial mode is not advertised, nothing written")
    }
    if !orderedModes.contains(where: { $0 != initialMode }) {
      return .skipped(reason: "no alternate recognized advertised modes")
    }
    return .willTest(
      ListeningModeWriteTestPlan(initial: initialMode, advertised: orderedModes)
    )
  }

  private static func conversationAwarenessPlan(
    device: any CompatibleAudioDevice,
    initialState: Bool?
  ) -> SupportReportCapabilityPlan<Bool> {
    switch device.supportsConversationAwareness() {
    case .some(false):
      return .skipped(reason: "not supported")
    case .none:
      return .skipped(reason: "capability unavailable")
    case .some(true):
      if !device.canSetConversationAwareness() {
        return .skipped(reason: "setter not exposed")
      }
      guard let initialState else {
        return .skipped(reason: "initial state unreadable, nothing written")
      }
      return .willTest(initialState)
    }
  }
}
