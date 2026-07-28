// Consented write tests for support-report. Each test uses the same bounded
// write-and-readback machinery as the operational commands, ordered so the
// last listening-mode write restores the initial mode.

import Darwin
import Foundation
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

  // Marks every capability that would still run as skipped for the given
  // reason, preserving the more specific reasons recorded by planning.
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

// One bounded write-and-readback attempt: whether the setter accepted the
// request and whether the state observed within the settling window matched
// the requested value.
struct WriteAttempt<State: Equatable> {
  let setterAccepted: Bool
  let verified: Bool
  let observed: State?
}

extension WriteAttempt {
  init(requested: State, observation: DeviceWriteObservation<State>) {
    self.init(
      setterAccepted: observation.setterAccepted,
      verified: observation.observed == requested,
      observed: observation.observed
    )
  }
}

// The exclusive outcome of one capability's write tests: either nothing was
// written for the stated reason, or the tests ran and produced a result.
enum CapabilityWriteTestOutcome<Run> {
  case skipped(reason: String)
  case ran(Run)
}

// Whether a capability's state needed a restoration write after its tests.
enum RestorationOutcome<Attempt> {
  // The readback never left the captured initial state, so no restoration
  // write ran.
  case stateNeverChanged
  case attempted(Attempt)
}

struct SupportReportWriteTestResults {
  // One tested listening mode: the write attempt plus the context needed to
  // qualify its verdict.
  struct ListeningModeTest {
    let mode: ListeningMode
    let write: WriteAttempt<ListeningMode>
    // The state read immediately before this write already equaled the
    // target (for example after an Off write fell back to Transparency), so
    // a matching readback demonstrates no transition.
    let targetAlreadyCurrent: Bool
    let inferredOffFallback: Bool
  }

  struct ListeningModeTestRun {
    let tests: [ListeningModeTest]
    let stoppedAfterSetterError: Bool
    // The restoration write doubles as the initial mode's own test, so a
    // state that never changed also leaves the initial mode undemonstrated.
    let restoration: RestorationOutcome<ListeningModeTest>
    let finalMode: ListeningMode?
    let restored: Bool
  }

  struct ConversationAwarenessTestRun {
    let toggle: WriteAttempt<Bool>
    let restoration: RestorationOutcome<WriteAttempt<Bool>>
    let finalState: Bool?
    let restored: Bool
  }

  let listeningModes: CapabilityWriteTestOutcome<ListeningModeTestRun>
  let conversationAwareness: CapabilityWriteTestOutcome<ConversationAwarenessTestRun>
  let interruptedBySignal: Int32?

  var fullyRestored: Bool {
    Self.restored(listeningModes, \.restored)
      && Self.restored(conversationAwareness, \.restored)
  }

  // A skipped capability wrote nothing, so it cannot fail restoration.
  private static func restored<Run>(
    _ outcome: CapabilityWriteTestOutcome<Run>,
    _ restored: (Run) -> Bool
  ) -> Bool {
    switch outcome {
    case .skipped: return true
    case let .ran(run): return restored(run)
    }
  }

  // Records a signal that surfaced only after the final checkpoint, when
  // every write and restoration attempt had already finished.
  func recordingLateSignal(_ signalNumber: Int32?) -> SupportReportWriteTestResults {
    guard interruptedBySignal == nil, let signalNumber else { return self }
    return SupportReportWriteTestResults(
      listeningModes: listeningModes,
      conversationAwareness: conversationAwareness,
      interruptedBySignal: signalNumber
    )
  }
}

enum SupportReportWriteTester {
  // Announced on stderr so an interrupted run shows feedback before the
  // remaining holds and restoration writes, without touching the stdout
  // report contract.
  static let interruptionNotice =
    "Interrupt caught; restoring initial settings...\n"

  // Each accepted mode write is held so a wearer can hear the change before
  // the next write — the "about two seconds" promised by the consent prompt
  // and the docs.
  static let listeningModeHold: TimeInterval = 2

  static func run(device: any CompatibleAudioDevice) -> SupportReportWriteTestResults {
    run(plan: SupportReportWriteTestPlan.make(device: device), device: device)
  }

  static func run(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice,
    interruptionSignal: () -> Int32? = { nil },
    writeError: (String) -> Void = { fputs($0, stderr) }
  ) -> SupportReportWriteTestResults {
    var interruptedBySignal: Int32?
    // Checkpoint: polls for a termination signal until one is latched. The
    // nil guard makes the nil-to-signal transition unique, so the notice is
    // written exactly once, before any restoration write that follows.
    func observeInterruption() -> Int32? {
      if interruptedBySignal == nil {
        interruptedBySignal = interruptionSignal()
        if interruptedBySignal != nil {
          writeError(interruptionNotice)
        }
      }
      return interruptedBySignal
    }

    let listeningModes = testListeningModes(
      plan: plan, device: device, observeInterruption: observeInterruption
    )
    let conversationAwareness = testConversationAwareness(
      plan: plan, device: device, observeInterruption: observeInterruption
    )
    // A signal arriving during the last writes is still latched and
    // announced even though no test remains to observe it.
    _ = observeInterruption()
    return SupportReportWriteTestResults(
      listeningModes: listeningModes,
      conversationAwareness: conversationAwareness,
      interruptedBySignal: interruptedBySignal
    )
  }

  static func runInterruptibly(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice,
    writeError: (String) -> Void = { fputs($0, stderr) }
  ) -> SupportReportWriteTestResults {
    guard let monitor = SupportReportTerminationMonitor() else {
      return run(
        plan: plan.skippingAll(
          reason: "termination-signal monitor unavailable, nothing written"
        ),
        device: device
      )
    }
    let results = run(
      plan: plan,
      device: device,
      interruptionSignal: { monitor.caughtSignal },
      writeError: writeError
    )
    // A signal first surfaced by disarm arrived after the final checkpoint,
    // when every write and restoration attempt had already finished, so no
    // restoration notice is written for it.
    return results.recordingLateSignal(monitor.disarm())
  }

  // Revalidates the consented plan against the live device, walks the
  // noninitial advertised modes, and restores the initial mode if the state
  // moved. Early returns keep skipping and running mutually exclusive.
  private static func testListeningModes(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice,
    observeInterruption: () -> Int32?
  ) -> CapabilityWriteTestOutcome<SupportReportWriteTestResults.ListeningModeTestRun> {
    if let reason = plan.modeTestsSkippedReason {
      return .skipped(reason: reason)
    }
    if observeInterruption() != nil {
      return .skipped(reason: "interrupted before test")
    }
    guard device.canSetListeningMode() else {
      return .skipped(reason: "setter no longer exposed, nothing written")
    }
    guard Set(plan.listeningModes).isSubset(of: Set(device.availableListeningModes()))
    else {
      return .skipped(
        reason: "planned listening modes are no longer advertised, nothing written"
      )
    }
    guard device.currentListeningMode() == plan.initialListeningMode else {
      return .skipped(
        reason: "initial state changed after planning, nothing written"
      )
    }
    guard let initialMode = plan.initialListeningMode else {
      // make() never plans mode tests without a readable initial mode.
      return .skipped(reason: "initial state unreadable, nothing written")
    }

    let transparencySupported = plan.listeningModes.contains(.transparency)
    var tests: [SupportReportWriteTestResults.ListeningModeTest] = []
    var stoppedAfterSetterError = false
    for target in plan.listeningModeTargets {
      if observeInterruption() != nil { break }
      let test = testListeningMode(
        target, device: device, transparencySupported: transparencySupported
      )
      tests.append(test)
      if !test.write.setterAccepted {
        stoppedAfterSetterError = true
        break
      }
      if observeInterruption() != nil { break }
    }

    let restoration: RestorationOutcome<SupportReportWriteTestResults.ListeningModeTest>
    if device.currentListeningMode() != initialMode {
      restoration = .attempted(
        testListeningMode(
          initialMode, device: device, transparencySupported: transparencySupported
        )
      )
    } else {
      restoration = .stateNeverChanged
    }
    let finalMode = device.currentListeningMode()
    return .ran(
      SupportReportWriteTestResults.ListeningModeTestRun(
        tests: tests,
        stoppedAfterSetterError: stoppedAfterSetterError,
        restoration: restoration,
        finalMode: finalMode,
        restored: finalMode == initialMode
      )
    )
  }

  // Revalidates the consented plan, toggles Conversation Awareness away from
  // the captured initial state, and writes it back if the state moved.
  private static func testConversationAwareness(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice,
    observeInterruption: () -> Int32?
  ) -> CapabilityWriteTestOutcome<
    SupportReportWriteTestResults.ConversationAwarenessTestRun
  > {
    if let reason = plan.conversationAwarenessSkippedReason {
      return .skipped(reason: reason)
    }
    if observeInterruption() != nil {
      return .skipped(reason: "interrupted before test")
    }
    guard device.supportsConversationAwareness() == true,
          device.canSetConversationAwareness()
    else {
      return .skipped(
        reason: "capability or setter no longer exposed, nothing written"
      )
    }
    let currentState = device.conversationAwarenessState()
    if observeInterruption() != nil {
      return .skipped(reason: "interrupted before test")
    }
    guard currentState == plan.initialConversationAwareness else {
      return .skipped(
        reason: "initial state changed after planning, nothing written"
      )
    }
    guard let initialState = plan.initialConversationAwareness else {
      // make() never plans this test without a readable initial state.
      return .skipped(reason: "initial state unreadable, nothing written")
    }

    let toggled = device.setConversationAwarenessAndReadBack(!initialState)
    _ = observeInterruption()
    let restoration: RestorationOutcome<WriteAttempt<Bool>>
    if toggled.observed != initialState {
      restoration = .attempted(
        WriteAttempt(
          requested: initialState,
          observation: device.setConversationAwarenessAndReadBack(initialState)
        )
      )
    } else {
      restoration = .stateNeverChanged
    }
    let finalState = device.conversationAwarenessState()
    return .ran(
      SupportReportWriteTestResults.ConversationAwarenessTestRun(
        toggle: WriteAttempt(requested: !initialState, observation: toggled),
        restoration: restoration,
        finalState: finalState,
        restored: finalState == initialState
      )
    )
  }

  private static func testListeningMode(
    _ target: ListeningMode,
    device: any CompatibleAudioDevice,
    transparencySupported: Bool
  ) -> SupportReportWriteTestResults.ListeningModeTest {
    // An earlier write can leave the device in a later target (for example
    // Off falling back to Transparency). The write is still attempted, but
    // its readback can then match without demonstrating a transition.
    let modeBeforeWrite = device.currentListeningMode()
    let observation = device.setListeningModeAndReadBack(target)
    device.settle(for: listeningModeHold)
    let settledMode = device.currentListeningMode()
    let resolution = resolveListeningModeWrite(
      requested: target,
      setterAccepted: observation.setterAccepted,
      observed: settledMode,
      transparencySupported: transparencySupported
    )
    return SupportReportWriteTestResults.ListeningModeTest(
      mode: target,
      write: WriteAttempt(
        setterAccepted: observation.setterAccepted,
        verified: resolution.verified,
        observed: resolution.state
      ),
      targetAlreadyCurrent: modeBeforeWrite == target,
      inferredOffFallback: resolution.inferredOffFallback
    )
  }
}
