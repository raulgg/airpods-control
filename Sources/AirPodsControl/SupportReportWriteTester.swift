// Consented write tests for support-report. Each test uses the same bounded
// write-and-readback machinery as the operational commands. Restoration still
// runs last when the device is not already in the captured initial mode.

import Darwin
import Foundation

private final class InterruptionLatch {
  private var latched: Int32?

  // The nil-to-signal transition is unique, so the notice is written exactly
  // once, before any restoration write that follows.
  func observe(
    interruptionSignal: () -> Int32?,
    announce: (Int32) -> Void
  ) -> Int32? {
    if latched == nil {
      latched = interruptionSignal()
      if let latched {
        announce(latched)
      }
    }
    return latched
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
    let latch = InterruptionLatch()
    func observeInterruption() -> Int32? {
      latch.observe(interruptionSignal: interruptionSignal) { signal in
        progress.interrupted(by: signal)
        writeError(interruptionNotice)
      }
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
    return SupportReportWriteTestResults(
      listeningModes: listeningModes,
      conversationAwareness: conversationAwareness,
      interruptedBySignal: observeInterruption()
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

    let restoration = restoreIfNeeded(
      current: device.currentListeningMode(),
      initial: initialMode,
      operation: .listeningModeRestoration,
      progress: progress
    ) {
      testListeningMode(
        initialMode, device: device, transparencySupported: transparencySupported
      )
    }
    let finalMode = device.currentListeningMode()
    return .ran(
      SupportReportWriteTestResults.ListeningModeTestRun(
        tests: tests,
        stoppedAfterSetterError: stoppedAfterSetterError,
        restoration: restoration,
        initialMode: initialMode,
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
    let restoration = restoreIfNeeded(
      current: toggled.observed,
      initial: initialState,
      operation: .conversationAwarenessRestoration,
      progress: progress
    ) {
      WriteAttempt(
        requested: initialState,
        observation: device.setConversationAwarenessAndReadBack(initialState)
      )
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

  private static func restoreIfNeeded<State: Equatable, Attempt>(
    current: State?,
    initial: State,
    operation: SupportReportWriteTestProgressOperation,
    progress: SupportReportWriteTestProgressReporter,
    restore: () -> Attempt
  ) -> RestorationOutcome<Attempt> {
    guard current != initial else {
      progress.skipped(operation)
      return .stateNeverChanged
    }
    progress.started(operation)
    return .attempted(restore())
  }

  private static func testListeningMode(
    _ target: ListeningMode,
    device: any CompatibleAudioDevice,
    transparencySupported: Bool
  ) -> SupportReportWriteTestResults.ListeningModeTest {
    // An earlier write can leave the device in a later target. The write is
    // still attempted, but its readback can then match without demonstrating
    // a transition.
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
