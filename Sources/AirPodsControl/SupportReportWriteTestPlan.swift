struct SupportReportWriteTestPlan {
  let initialListeningMode: ListeningMode?
  let listeningModes: [ListeningMode]
  let modeTestsSkippedReason: String?
  let initialConversationAwareness: Bool?
  let conversationAwarenessSkippedReason: String?

  var listeningModeTargets: [ListeningMode] {
    guard modeTestsSkippedReason == nil, let initialListeningMode else { return [] }
    // The already-current first probe is the captured initial mode; restoration
    // demonstrates it later. Keep it when it sits later in the sequence so an
    // Off fallback cannot skip a real Transparency transition.
    if listeningModes.first == initialListeningMode {
      return Array(listeningModes.dropFirst())
    }
    return listeningModes
  }

  var willTestListeningModes: Bool {
    !listeningModeTargets.isEmpty
  }

  var willTestConversationAwareness: Bool {
    conversationAwarenessSkippedReason == nil
  }

  // Preserves the more specific reasons already recorded by planning.
  func skippingAll(reason: String) -> SupportReportWriteTestPlan {
    SupportReportWriteTestPlan(
      initialListeningMode: initialListeningMode,
      listeningModes: listeningModes,
      modeTestsSkippedReason: willTestListeningModes
        ? reason : modeTestsSkippedReason,
      initialConversationAwareness: initialConversationAwareness,
      conversationAwarenessSkippedReason: willTestConversationAwareness
        ? reason : conversationAwarenessSkippedReason
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
      initialListeningMode: initialMode,
      listeningModes: orderedModes,
      modeTestsSkippedReason: listeningModeSkipReason(
        device: device,
        advertised: advertised,
        orderedModes: orderedModes,
        initialMode: initialMode
      ),
      initialConversationAwareness: initialConversationAwareness,
      conversationAwarenessSkippedReason: conversationAwarenessSkipReason(
        device: device,
        initialState: initialConversationAwareness
      )
    )
  }

  private static func listeningModeSkipReason(
    device: any CompatibleAudioDevice,
    advertised: Set<ListeningMode>,
    orderedModes: [ListeningMode],
    initialMode: ListeningMode?
  ) -> String? {
    if !device.canSetListeningMode() {
      return "setter not exposed"
    }
    if orderedModes.isEmpty {
      return "no recognized advertised modes"
    }
    if initialMode == nil {
      return "initial state unreadable, nothing written"
    }
    if let initialMode, !advertised.contains(initialMode) {
      return "initial mode is not advertised, nothing written"
    }
    if let initialMode, !orderedModes.contains(where: { $0 != initialMode }) {
      return "no alternate recognized advertised modes"
    }
    return nil
  }

  private static func conversationAwarenessSkipReason(
    device: any CompatibleAudioDevice,
    initialState: Bool?
  ) -> String? {
    switch device.supportsConversationAwareness() {
    case .some(false):
      return "not supported"
    case .none:
      return "capability unavailable"
    case .some(true):
      if !device.canSetConversationAwareness() {
        return "setter not exposed"
      }
      if initialState == nil {
        return "initial state unreadable, nothing written"
      }
      return nil
    }
  }
}
