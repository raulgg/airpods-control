import Darwin

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
  // No restoration write ran because the device already held the initial
  // mode. Earlier probes may still have changed state and returned here.
  case stateNeverChanged
  case attempted(Attempt)
}

struct SupportReportWriteTestResults {
  struct ListeningModeTest {
    let mode: ListeningMode
    let write: WriteAttempt<ListeningMode>
    // The state read immediately before this write already equaled the
    // target (for example after an earlier write landed on this mode), so a
    // matching readback demonstrates no transition.
    let targetAlreadyCurrent: Bool
    let inferredOffFallback: Bool
  }

  struct ListeningModeTestRun {
    let tests: [ListeningModeTest]
    let stoppedAfterSetterError: Bool
    // Restoration is skipped when the device already holds the initial mode.
    // That leaves the initial mode undemonstrated unless an earlier probe
    // already showed a real transition into it.
    let restoration: RestorationOutcome<ListeningModeTest>
    let initialMode: ListeningMode
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
