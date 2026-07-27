// Consented write tests for support-report. Each test uses the same bounded
// write-and-readback machinery as the operational commands, ordered so the
// last listening-mode write restores the initial mode.

import SignalMonitor

final class SupportReportTerminationMonitor {
  private var isDisarmed = false
  private var disarmedSignal: Int32?

  init?() {
    guard airpods_control_signal_monitor_install() == 0 else { return nil }
  }

  var caughtSignal: Int32? {
    let signalNumber = airpods_control_signal_monitor_caught_signal()
    return signalNumber == 0 ? nil : signalNumber
  }

  func disarm() -> Int32? {
    guard !isDisarmed else { return disarmedSignal }
    let signalNumber = airpods_control_signal_monitor_disarm()
    disarmedSignal = signalNumber == 0 ? nil : signalNumber
    isDisarmed = true
    return disarmedSignal
  }

  deinit {
    _ = disarm()
  }
}

struct SupportReportWriteTestPlan {
  let initialListeningMode: ListeningMode?
  let listeningModes: [ListeningMode]
  let modeTestsSkippedReason: String?
  let initialConversationAwareness: Bool?
  let conversationAwarenessSkippedReason: String?

  var listeningModeTargets: [ListeningMode] {
    guard modeTestsSkippedReason == nil, let initialListeningMode else { return [] }
    return listeningModes.filter { $0 != initialListeningMode }
  }

  var willTestListeningModes: Bool {
    !listeningModeTargets.isEmpty
  }

  var willTestConversationAwareness: Bool {
    conversationAwarenessSkippedReason == nil
  }

  var hasWrites: Bool {
    willTestListeningModes || willTestConversationAwareness
  }

  static func make(device: any CompatibleAudioDevice) -> SupportReportWriteTestPlan {
    let advertised = Set(device.availableListeningModes())
    let orderedModes = ListeningMode.allCases.filter { advertised.contains($0) }
    let initialMode = device.currentListeningMode()

    let modeSkipReason: String?
    if !device.canSetListeningMode() {
      modeSkipReason = "setter not exposed"
    } else if orderedModes.isEmpty {
      modeSkipReason = "no recognized advertised modes"
    } else if initialMode == nil {
      modeSkipReason = "initial state unreadable, nothing written"
    } else if let initialMode, !advertised.contains(initialMode) {
      modeSkipReason = "initial mode is not advertised, nothing written"
    } else if let initialMode,
              !orderedModes.contains(where: { $0 != initialMode })
    {
      modeSkipReason = "no alternate recognized advertised modes"
    } else {
      modeSkipReason = nil
    }

    let initialCA = device.conversationAwarenessState()
    let caSkipReason: String?
    switch device.supportsConversationAwareness() {
    case .some(false):
      caSkipReason = "not supported"
    case .none:
      caSkipReason = "capability unavailable"
    case .some(true):
      if !device.canSetConversationAwareness() {
        caSkipReason = "setter not exposed"
      } else if initialCA == nil {
        caSkipReason = "initial state unreadable, nothing written"
      } else {
        caSkipReason = nil
      }
    }

    return SupportReportWriteTestPlan(
      initialListeningMode: initialMode,
      listeningModes: orderedModes,
      modeTestsSkippedReason: modeSkipReason,
      initialConversationAwareness: initialCA,
      conversationAwarenessSkippedReason: caSkipReason
    )
  }
}

struct SupportReportWriteTestResults {
  struct ModeResult {
    let mode: ListeningMode
    let setterAccepted: Bool
    let verified: Bool
    let inferredOffFallback: Bool
    let observed: ListeningMode?
  }

  let initialListeningMode: ListeningMode?
  let modeResults: [ModeResult]
  let listeningModeRestorationResult: ModeResult?
  let modeTestsSkippedReason: String?
  let modeTestsStoppedAfterSetterError: Bool
  let initialModeTestSkipped: Bool
  let listeningModeRestored: Bool?
  let finalListeningMode: ListeningMode?

  let initialConversationAwareness: Bool?
  let conversationAwarenessSetterAccepted: Bool?
  let conversationAwarenessRestorationSetterAccepted: Bool?
  let conversationAwarenessRestorationVerified: Bool?
  let conversationAwarenessToggleVerified: Bool?
  let conversationAwarenessSkippedReason: String?
  let conversationAwarenessRestored: Bool?
  let finalConversationAwareness: Bool?
  var interruptedBySignal: Int32?

  var fullyRestored: Bool {
    listeningModeRestored != false && conversationAwarenessRestored != false
  }
}

enum SupportReportWriteTester {
  static func run(device: any CompatibleAudioDevice) -> SupportReportWriteTestResults {
    run(plan: SupportReportWriteTestPlan.make(device: device), device: device)
  }

  static func run(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice,
    interruptionSignal: () -> Int32? = { nil }
  ) -> SupportReportWriteTestResults {
    let initialMode = plan.initialListeningMode
    let advertised = Set(plan.listeningModes)
    var interruptedBySignal: Int32?
    func observeInterruption() {
      guard interruptedBySignal == nil else { return }
      interruptedBySignal = interruptionSignal()
    }

    var modeResults: [SupportReportWriteTestResults.ModeResult] = []
    var modeRestorationResult: SupportReportWriteTestResults.ModeResult?
    var modeSkipReason = plan.modeTestsSkippedReason
    var modeTestsStoppedAfterSetterError = false
    var initialModeTestSkipped = false
    observeInterruption()
    if modeSkipReason == nil, interruptedBySignal != nil {
      modeSkipReason = "interrupted before test"
    }
    if modeSkipReason == nil, !device.canSetListeningMode() {
      modeSkipReason = "setter no longer exposed, nothing written"
    }
    if modeSkipReason == nil {
      let currentlyAdvertised = Set(device.availableListeningModes())
      if !Set(plan.listeningModes).isSubset(of: currentlyAdvertised) {
        modeSkipReason =
          "planned listening modes are no longer advertised, nothing written"
      }
    }
    if modeSkipReason == nil,
       device.currentListeningMode() != initialMode
    {
      modeSkipReason = "initial state changed after planning, nothing written"
    }
    if modeSkipReason == nil, let initialMode {
      for target in plan.listeningModeTargets {
        observeInterruption()
        if interruptedBySignal != nil { break }
        let result = testListeningMode(
          target,
          device: device,
          transparencySupported: advertised.contains(.transparency)
        )
        modeResults.append(result)
        if !result.setterAccepted {
          modeTestsStoppedAfterSetterError = true
          break
        }
        observeInterruption()
        if interruptedBySignal != nil { break }
      }

      if device.currentListeningMode() != initialMode {
        modeRestorationResult = testListeningMode(
          initialMode,
          device: device,
          transparencySupported: advertised.contains(.transparency)
        )
      } else if plan.listeningModes.contains(initialMode) {
        initialModeTestSkipped = true
      }
    }
    let finalMode = device.currentListeningMode()
    observeInterruption()
    let modeRestored: Bool? =
      modeSkipReason == nil ? finalMode == initialMode : nil

    let initialCA = plan.initialConversationAwareness
    var caSkipReason = plan.conversationAwarenessSkippedReason
    var caSetterAccepted: Bool?
    var caRestorationSetterAccepted: Bool?
    var caRestorationVerified: Bool?
    var caToggleVerified: Bool?
    observeInterruption()
    if caSkipReason == nil, interruptedBySignal != nil {
      caSkipReason = "interrupted before test"
    }
    if caSkipReason == nil,
       device.supportsConversationAwareness() != true
         || !device.canSetConversationAwareness()
    {
      caSkipReason = "capability or setter no longer exposed, nothing written"
    }
    if caSkipReason == nil {
      let currentCA = device.conversationAwarenessState()
      observeInterruption()
      if interruptedBySignal != nil {
        caSkipReason = "interrupted before test"
      } else if currentCA != initialCA {
        caSkipReason = "initial state changed after planning, nothing written"
      }
    }
    observeInterruption()
    if caSkipReason == nil, interruptedBySignal != nil {
      caSkipReason = "interrupted before test"
    }
    if caSkipReason == nil, let initialCA {
      let toggled = device.setConversationAwarenessAndReadBack(!initialCA)
      caSetterAccepted = toggled.setterAccepted
      observeInterruption()
      if toggled.observed != initialCA {
        let restored = device.setConversationAwarenessAndReadBack(initialCA)
        caRestorationSetterAccepted = restored.setterAccepted
        caRestorationVerified = restored.observed == initialCA
        caToggleVerified = toggled.setterAccepted
          && toggled.observed == !initialCA
          && restored.setterAccepted
          && restored.observed == initialCA
      } else {
        caToggleVerified = false
      }
    }
    let finalCA = device.conversationAwarenessState()
    observeInterruption()
    let caRestored: Bool? =
      caSkipReason == nil ? finalCA == initialCA : nil

    return SupportReportWriteTestResults(
      initialListeningMode: initialMode,
      modeResults: modeResults,
      listeningModeRestorationResult: modeRestorationResult,
      modeTestsSkippedReason: modeSkipReason,
      modeTestsStoppedAfterSetterError: modeTestsStoppedAfterSetterError,
      initialModeTestSkipped: initialModeTestSkipped,
      listeningModeRestored: modeRestored,
      finalListeningMode: finalMode,
      initialConversationAwareness: initialCA,
      conversationAwarenessSetterAccepted: caSetterAccepted,
      conversationAwarenessRestorationSetterAccepted: caRestorationSetterAccepted,
      conversationAwarenessRestorationVerified: caRestorationVerified,
      conversationAwarenessToggleVerified: caToggleVerified,
      conversationAwarenessSkippedReason: caSkipReason,
      conversationAwarenessRestored: caRestored,
      finalConversationAwareness: finalCA,
      interruptedBySignal: interruptedBySignal
    )
  }

  static func runInterruptibly(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice
  ) -> SupportReportWriteTestResults {
    guard let monitor = SupportReportTerminationMonitor() else {
      let reason = "termination-signal monitor unavailable, nothing written"
      let skippedPlan = SupportReportWriteTestPlan(
        initialListeningMode: plan.initialListeningMode,
        listeningModes: plan.listeningModes,
        modeTestsSkippedReason: plan.willTestListeningModes
          ? reason : plan.modeTestsSkippedReason,
        initialConversationAwareness: plan.initialConversationAwareness,
        conversationAwarenessSkippedReason:
          plan.willTestConversationAwareness
            ? reason : plan.conversationAwarenessSkippedReason
      )
      return run(plan: skippedPlan, device: device)
    }
    var results = run(
      plan: plan,
      device: device,
      interruptionSignal: { monitor.caughtSignal }
    )
    results.interruptedBySignal =
      results.interruptedBySignal ?? monitor.disarm()
    return results
  }

  private static func testListeningMode(
    _ target: ListeningMode,
    device: any CompatibleAudioDevice,
    transparencySupported: Bool
  ) -> SupportReportWriteTestResults.ModeResult {
    let observation = device.setListeningModeAndReadBack(target)
    device.waitForListeningModeEffect()
    let settledMode = device.currentListeningMode()
    let resolution = resolveListeningModeWrite(
      requested: target,
      setterAccepted: observation.setterAccepted,
      observed: settledMode,
      transparencySupported: transparencySupported
    )
    return SupportReportWriteTestResults.ModeResult(
      mode: target,
      setterAccepted: observation.setterAccepted,
      verified: resolution.verified,
      inferredOffFallback: resolution.inferredOffFallback,
      observed: resolution.state
    )
  }
}
