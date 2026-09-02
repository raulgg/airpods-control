import Foundation

// Shared data for the terminal and GitHub renderers. Values are filtered and
// interpreted before the document is built.
struct SupportReportDocument {
  struct Device {
    let family: SupportReportDeviceFamily
    let modelName: String?
    let modelIdentifier: String
    let bluetoothProductID: String?
    let macOS: String
    let cliVersion: String
  }

  struct Capabilities {
    let listeningModes: [ListeningMode]
    let otherListeningModes: SupportReportOtherListeningModes
    let listeningModeQuery: SupportReportListeningModeQuery
    let listeningModeSetter: SetterStatus
    let conversationAwarenessSupport: SupportReportCapabilitySupport
    let conversationAwarenessQuery: SupportReportQueryAvailability
    let conversationAwarenessSetter: SetterStatus
  }

  enum SetterStatus {
    case notExposed
    case exposedNotTested
    case exposedTested
  }

  enum WriteTests {
    case notRun
    case ran([WriteTestResult])

    var results: [WriteTestResult] {
      if case let .ran(results) = self { return results }
      return []
    }
  }

  struct WriteTestResult {
    enum Operation {
      case listeningMode(ListeningMode)
      case listeningModeRestoration(ListeningMode)
      case listeningModes
      case capturedInitialListeningMode
      case remainingListeningModes
      case conversationAwareness
      case conversationAwarenessRestoration
    }

    enum Verdict {
      case verified
      case inconclusive(reason: String)
      case noOp(reason: String?)
      case setterError
      case skipped(reason: String)
    }

    let operation: Operation
    let verdict: Verdict
  }

  enum RestorationProblem {
    case listeningMode(ListeningMode?)
    case conversationAwareness(Bool?)
  }

  enum Restoration {
    case notRun
    case nothingWritten
    case restored
    case failed([RestorationProblem])
  }

  struct Summary {
    var verified = 0
    var inconclusive = 0
    var noOp = 0
    var errors = 0
    var skipped = 0
  }

  let device: Device
  let capabilities: Capabilities
  let writeTests: WriteTests
  let restoration: Restoration
  let interruptedBySignal: Int32?

  var summary: Summary {
    writeTests.results.reduce(into: Summary()) { summary, result in
      switch result.verdict {
      case .verified:
        summary.verified += 1
      case .inconclusive:
        summary.inconclusive += 1
      case .noOp:
        summary.noOp += 1
      case .setterError:
        summary.errors += 1
      case .skipped:
        summary.skipped += 1
      }
    }
  }

  static func make(
    snapshot: SupportReportSnapshot,
    writeTests: SupportReportWriteTestResults? = nil
  ) -> SupportReportDocument {
    let setterTested = writeTests != nil
    let results = writeTests.map(writeTestResults) ?? []

    return SupportReportDocument(
      device: Device(
        family: snapshot.family,
        modelName: snapshot.modelName,
        modelIdentifier: snapshot.modelIdentifier,
        bluetoothProductID: snapshot.bluetoothProductID,
        macOS: snapshot.macOS,
        cliVersion: VERSION
      ),
      capabilities: Capabilities(
        listeningModes: snapshot.listeningModes,
        otherListeningModes: snapshot.otherListeningModes,
        listeningModeQuery: snapshot.listeningModeQuery,
        listeningModeSetter: setterStatus(
          exposed: snapshot.listeningModeSetterExposed,
          tested: setterTested
        ),
        conversationAwarenessSupport: snapshot.conversationAwarenessSupport,
        conversationAwarenessQuery: snapshot.conversationAwarenessQuery,
        conversationAwarenessSetter: setterStatus(
          exposed: snapshot.conversationAwarenessSetterExposed,
          tested: setterTested
        )
      ),
      writeTests: writeTests == nil ? .notRun : .ran(results),
      restoration: restoration(from: writeTests),
      interruptedBySignal: writeTests?.interruptedBySignal
    )
  }

  private static func setterStatus(exposed: Bool, tested: Bool) -> SetterStatus {
    guard exposed else { return .notExposed }
    return tested ? .exposedTested : .exposedNotTested
  }

  private static func writeTestResults(
    _ results: SupportReportWriteTestResults
  ) -> [WriteTestResult] {
    var rendered: [WriteTestResult] = []

    switch results.listeningModes {
    case let .skipped(reason):
      rendered.append(
        WriteTestResult(
          operation: .listeningModes,
          verdict: .skipped(reason: reason)
        )
      )
    case let .ran(run):
      rendered.append(
        contentsOf: run.tests.map {
          WriteTestResult(
            operation: .listeningMode($0.mode),
            verdict: modeVerdict($0)
          )
        }
      )
      if run.stoppedAfterSetterError {
        rendered.append(
          WriteTestResult(
            operation: .remainingListeningModes,
            verdict: .skipped(reason: "after setter error")
          )
        )
      }
      switch run.restoration {
      case let .attempted(restoration):
        rendered.append(
          WriteTestResult(
            operation: .listeningModeRestoration(restoration.mode),
            verdict: modeVerdict(restoration)
          )
        )
      case .stateNeverChanged:
        let demonstratedInitial = run.tests.contains { test in
          test.mode == run.initialMode
            && test.write.verified
            && !test.targetAlreadyCurrent
        }
        if !demonstratedInitial {
          // Deliberately unnamed: the report is pasted publicly and must not
          // disclose which mode the device was in when that mode was never
          // demonstrated. Off last can return here after real transitions.
          rendered.append(
            WriteTestResult(
              operation: .capturedInitialListeningMode,
              verdict: .skipped(reason: "already at initial mode; not demonstrated")
            )
          )
        }
      }
    }

    switch results.conversationAwareness {
    case let .skipped(reason):
      rendered.append(
        WriteTestResult(
          operation: .conversationAwareness,
          verdict: .skipped(reason: reason)
        )
      )
    case let .ran(run):
      // One row per write, as the listening-mode tests already do: a toggle
      // that verified stays visible even when its restoration then fails.
      rendered.append(
        WriteTestResult(
          operation: .conversationAwareness,
          verdict: writeVerdict(run.toggle)
        )
      )
      if case let .attempted(restoration) = run.restoration {
        rendered.append(
          WriteTestResult(
            operation: .conversationAwarenessRestoration,
            verdict: writeVerdict(restoration)
          )
        )
      }
    }

    return rendered
  }

  private static func modeVerdict(
    _ test: SupportReportWriteTestResults.ListeningModeTest
  ) -> WriteTestResult.Verdict {
    guard test.write.setterAccepted else { return .setterError }
    if test.write.verified {
      return test.targetAlreadyCurrent
        ? .inconclusive(reason: "already in this state; no transition demonstrated")
        : .verified
    }
    return .noOp(
      reason: test.inferredOffFallback ? "expected Transparency fallback" : nil
    )
  }

  private static func writeVerdict(_ write: WriteAttempt<Bool>) -> WriteTestResult.Verdict {
    guard write.setterAccepted else { return .setterError }
    return write.verified ? .verified : .noOp(reason: nil)
  }

  private static func restoration(
    from results: SupportReportWriteTestResults?
  ) -> Restoration {
    guard let results else { return .notRun }

    var anythingWritten = false
    var problems: [RestorationProblem] = []
    if case let .ran(run) = results.listeningModes {
      anythingWritten = true
      if !run.restored {
        problems.append(.listeningMode(run.finalMode))
      }
    }
    if case let .ran(run) = results.conversationAwareness {
      anythingWritten = true
      if !run.restored {
        problems.append(.conversationAwareness(run.finalState))
      }
    }

    guard anythingWritten else { return .nothingWritten }
    return problems.isEmpty ? .restored : .failed(problems)
  }
}
