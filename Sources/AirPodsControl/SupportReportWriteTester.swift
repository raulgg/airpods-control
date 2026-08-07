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

enum CapabilityWriteTestOutcome<Run> {
  case skipped(reason: String)
  case ran(Run)
}

enum RestorationOutcome<Attempt> {
  // The readback never left the initial state, so no restoration write ran.
  case stateNeverChanged
  case attempted(Attempt)
}

struct SupportReportWriteTestResults {
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
  // On stderr: an interrupted run needs feedback before the remaining holds
  // and restoration writes, and stdout carries the report.
  static let interruptionNotice =
    "Interrupt caught; restoring initial settings...\n"

  // Held so a wearer hears each change: the "about two seconds" the consent
  // prompt and the docs promise.
  static let listeningModeHold: TimeInterval = 2

  static func run(
    device: any CompatibleAudioDevice,
    progress: @escaping (SupportReportWriteTestProgressEvent) -> Void = { _ in }
  ) -> SupportReportWriteTestResults {
    run(
      plan: SupportReportWriteTestPlan.make(device: device),
      device: device,
      progress: progress
    )
  }

  static func run(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice,
    interruptionSignal: () -> Int32? = { nil },
    writeError: (String) -> Void = { fputs($0, stderr) },
    progress: @escaping (SupportReportWriteTestProgressEvent) -> Void = { _ in }
  ) -> SupportReportWriteTestResults {
    reportingProgress(for: plan, to: progress) { reporter in
      execute(
        plan: plan,
        device: device,
        interruptionSignal: interruptionSignal,
        writeError: writeError,
        progress: reporter
      )
    }
  }

  private static func execute(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice,
    interruptionSignal: () -> Int32?,
    writeError: (String) -> Void,
    progress: SupportReportWriteTestProgressReporter
  ) -> SupportReportWriteTestResults {
    var interruptedBySignal: Int32?
    // The nil guard makes the nil-to-signal transition unique, so the notice
    // is written exactly once, before any restoration write that follows.
    func observeInterruption() -> Int32? {
      if interruptedBySignal == nil {
        interruptedBySignal = interruptionSignal()
        if let interruptedBySignal {
          progress.interrupted(by: interruptedBySignal)
          writeError(interruptionNotice)
        }
      }
      return interruptedBySignal
    }

    let listeningModes = testListeningModes(
      plan: plan,
      device: device,
      observeInterruption: observeInterruption,
      progress: progress
    )
    let conversationAwareness = testConversationAwareness(
      plan: plan,
      device: device,
      observeInterruption: observeInterruption,
      progress: progress
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
    writeError: (String) -> Void = { fputs($0, stderr) },
    progress: @escaping (SupportReportWriteTestProgressEvent) -> Void = { _ in }
  ) -> SupportReportWriteTestResults {
    reportingProgress(for: plan, to: progress) { reporter in
      guard let monitor = SupportReportTerminationMonitor() else {
        return execute(
          plan: plan.skippingAll(
            reason: "termination-signal monitor unavailable, nothing written"
          ),
          device: device,
          interruptionSignal: { nil },
          writeError: writeError,
          progress: reporter
        )
      }
      let results = execute(
        plan: plan,
        device: device,
        interruptionSignal: { monitor.caughtSignal },
        writeError: writeError,
        progress: reporter
      )
      // A signal first surfaced by disarm arrived after the final checkpoint,
      // when every write and restoration attempt had already finished, so no
      // restoration notice is written for it.
      return results.recordingLateSignal(monitor.disarm())
    }
  }

  private static func reportingProgress(
    for plan: SupportReportWriteTestPlan,
    to report: @escaping (SupportReportWriteTestProgressEvent) -> Void,
    _ run: (SupportReportWriteTestProgressReporter) -> SupportReportWriteTestResults
  ) -> SupportReportWriteTestResults {
    let reporter = SupportReportWriteTestProgressReporter(plan: plan, report: report)
    reporter.preparing()
    defer { reporter.finished() }
    let results = run(reporter)
    if !results.fullyRestored {
      reporter.restorationFailed()
    }
    return results
  }

  // Revalidates the consented plan against the live device before writing.
  private static func testListeningModes(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice,
    observeInterruption: () -> Int32?,
    progress: SupportReportWriteTestProgressReporter
  ) -> CapabilityWriteTestOutcome<SupportReportWriteTestResults.ListeningModeTestRun> {
    func skipped(_ reason: String) -> CapabilityWriteTestOutcome<
      SupportReportWriteTestResults.ListeningModeTestRun
    > {
      progress.skippedListeningModes()
      return .skipped(reason: reason)
    }

    if let reason = plan.modeTestsSkippedReason {
      return skipped(reason)
    }
    if observeInterruption() != nil {
      return skipped("interrupted before test")
    }
    guard device.canSetListeningMode() else {
      return skipped("setter no longer exposed, nothing written")
    }
    guard Set(plan.listeningModes).isSubset(of: Set(device.availableListeningModes()))
    else {
      return skipped("planned listening modes are no longer advertised, nothing written")
    }
    guard device.currentListeningMode() == plan.initialListeningMode else {
      return skipped("initial state changed after planning, nothing written")
    }
    guard let initialMode = plan.initialListeningMode else {
      // make() never plans mode tests without a readable initial mode.
      return skipped("initial state unreadable, nothing written")
    }

    let transparencySupported = plan.listeningModes.contains(.transparency)
    var tests: [SupportReportWriteTestResults.ListeningModeTest] = []
    var stoppedAfterSetterError = false
    for target in plan.listeningModeTargets {
      if observeInterruption() != nil { break }
      progress.started(.listeningMode(target))
      let test = testListeningMode(
        target, device: device, transparencySupported: transparencySupported
      )
      tests.append(test)
      if !test.write.setterAccepted {
        stoppedAfterSetterError = true
        _ = observeInterruption()
        break
      }
      if observeInterruption() != nil { break }
    }
    let untestedTargets = plan.listeningModeTargets.dropFirst(tests.count)
    progress.skipped(untestedTargets.map { .listeningMode($0) })

    let restoration: RestorationOutcome<SupportReportWriteTestResults.ListeningModeTest>
    if device.currentListeningMode() != initialMode {
      progress.started(.listeningModeRestoration)
      restoration = .attempted(
        testListeningMode(
          initialMode, device: device, transparencySupported: transparencySupported
        )
      )
    } else {
      progress.skipped(.listeningModeRestoration)
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

  // Revalidates the consented plan against the live device before writing.
  private static func testConversationAwareness(
    plan: SupportReportWriteTestPlan,
    device: any CompatibleAudioDevice,
    observeInterruption: () -> Int32?,
    progress: SupportReportWriteTestProgressReporter
  ) -> CapabilityWriteTestOutcome<
    SupportReportWriteTestResults.ConversationAwarenessTestRun
  > {
    func skipped(_ reason: String) -> CapabilityWriteTestOutcome<
      SupportReportWriteTestResults.ConversationAwarenessTestRun
    > {
      progress.skippedConversationAwareness()
      return .skipped(reason: reason)
    }

    if let reason = plan.conversationAwarenessSkippedReason {
      return skipped(reason)
    }
    if observeInterruption() != nil {
      return skipped("interrupted before test")
    }
    guard device.supportsConversationAwareness() == true,
          device.canSetConversationAwareness()
    else {
      return skipped("capability or setter no longer exposed, nothing written")
    }
    let currentState = device.conversationAwarenessState()
    if observeInterruption() != nil {
      return skipped("interrupted before test")
    }
    guard currentState == plan.initialConversationAwareness else {
      return skipped("initial state changed after planning, nothing written")
    }
    guard let initialState = plan.initialConversationAwareness else {
      // make() never plans this test without a readable initial state.
      return skipped("initial state unreadable, nothing written")
    }

    progress.started(.conversationAwareness)
    let toggled = device.setConversationAwarenessAndReadBack(!initialState)
    _ = observeInterruption()
    let restoration: RestorationOutcome<WriteAttempt<Bool>>
    if toggled.observed != initialState {
      progress.started(.conversationAwarenessRestoration)
      restoration = .attempted(
        WriteAttempt(
          requested: initialState,
          observation: device.setConversationAwarenessAndReadBack(initialState)
        )
      )
    } else {
      progress.skipped(.conversationAwarenessRestoration)
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
