import Darwin
import Foundation

struct SupportReportIssueDraft {
  let title: String
  let body: String
}

// The rendered support-report document: the local markdown and the GitHub
// issue draft, produced in one pass from a pre-write snapshot and the
// write-test results, if any ran.
struct SupportReport {
  static let repositoryIssuesURL =
    URL(string: "https://github.com/raulgg/airpods-control/issues/new")!
  static let issueTemplateName = "compatibility-report.md"
  static let maximumPrefilledURLLength = 6_000

  let markdown: String
  let issueDraft: SupportReportIssueDraft

  static func render(
    _ snapshot: SupportReportSnapshot,
    writeTests: SupportReportWriteTestResults? = nil
  ) -> SupportReport {
    let setterTested = writeTests != nil
    let listeningModeSetter = setterValue(
      snapshot.listeningModeSetterExposed, tested: setterTested
    )
    let conversationAwarenessSetter = setterValue(
      snapshot.conversationAwarenessSetterExposed, tested: setterTested
    )
    let writeTestsSummaryLine = writeTests == nil ? "\n- Write tests: not run" : ""
    let renderedWriteTestsSection = writeTests.map {
      "\n\n" + writeTestsSection($0)
    } ?? ""
    let localRestorationStatus = writeTests.map {
      "\n\nInitial state restored: \(restoredValue($0))"
    } ?? ""

    let compatibilityReport = """
    ### Compatibility report

    - Device family: \(snapshot.family.rawValue)
    - Model: \(snapshot.model)
    - Model identifier: \(snapshot.modelIdentifier)
    - Advertised known listening modes: \(snapshot.listeningModes)
    - Other advertised listening modes: \(snapshot.otherModes)
    - Listening-mode query: \(snapshot.listeningModeQuery)
    - Listening-mode setter: \(listeningModeSetter)
    - Conversation Awareness capability: \(snapshot.conversationAwarenessSupport)
    - Conversation Awareness query: \(snapshot.conversationAwarenessQuery)
    - Conversation Awareness setter: \(conversationAwarenessSetter)\(writeTestsSummaryLine)
    - macOS: \(snapshot.macOS)
    - airpods-control: \(VERSION)
    """
    let markdown = compatibilityReport + renderedWriteTestsSection
      + localRestorationStatus
      + "\n\nCreated locally by `airpods-control support-report`. Check it before submitting."
    let issueBody = compatibilityReport + renderedWriteTestsSection + """


    ### Notes (optional)

    Add any other compatibility details that are safe to publish.
    """

    return SupportReport(
      markdown: markdown,
      issueDraft: SupportReportIssueDraft(
        title: "[Compatibility] \(snapshot.titleSubject) on macOS \(snapshot.macOS)",
        body: issueBody
      )
    )
  }

  private static func setterValue(_ exposed: Bool, tested: Bool) -> String {
    guard exposed else { return "not exposed" }
    return tested ? "exposed (see write tests)" : "exposed, not tested by this report"
  }

  private static func writeTestsSection(
    _ results: SupportReportWriteTestResults
  ) -> String {
    var lines: [String] = []
    switch results.listeningModes {
    case let .skipped(reason):
      lines.append("- `listening-mode set`: skipped (\(reason))")
    case let .ran(run):
      for test in run.tests {
        lines.append(
          "- `listening-mode set \(test.mode.rawValue)`: \(modeVerdict(test))"
        )
      }
      if run.stoppedAfterSetterError {
        lines.append("- Remaining listening-mode tests: skipped after setter error")
      }
      switch run.restoration {
      case let .attempted(restoration):
        lines.append(
          "- `listening-mode set \(restoration.mode.rawValue)`: "
            + modeVerdict(restoration)
        )
      case .stateNeverChanged:
        // Deliberately unnamed: the report is pasted publicly and must not
        // disclose which mode the device was in.
        lines.append(
          "- `listening-mode set` (captured initial mode): "
            + "skipped (state never changed from initial)"
        )
      }
    }
    switch results.conversationAwareness {
    case let .skipped(reason):
      lines.append("- `conversation-awareness set`: skipped (\(reason))")
    case let .ran(run):
      lines.append(
        "- `conversation-awareness set`: \(conversationAwarenessVerdict(run))"
      )
    }
    let section = "### Write tests (run with consent)\n\n" + lines.joined(separator: "\n")
    let interruption = results.interruptedBySignal.map {
      "\n\nWrite tests interrupted by \(signalName($0)); "
        + "remaining exploratory writes skipped."
    } ?? ""
    return section + interruption
  }

  private static func modeVerdict(
    _ test: SupportReportWriteTestResults.ListeningModeTest
  ) -> String {
    if !test.write.setterAccepted {
      return "setter error"
    }
    if test.write.verified {
      return test.targetAlreadyCurrent
        ? "verified (already in this state; no transition demonstrated)"
        : "verified"
    }
    if test.inferredOffFallback {
      return "no-op (expected Transparency fallback)"
    }
    return "no-op"
  }

  private static func conversationAwarenessVerdict(
    _ run: SupportReportWriteTestResults.ConversationAwarenessTestRun
  ) -> String {
    guard run.toggle.setterAccepted else { return "setter error" }
    switch run.restoration {
    case .stateNeverChanged:
      // The accepted toggle never moved the readback, so there was no round
      // trip to verify.
      return "no-op"
    case let .attempted(restoration):
      guard restoration.setterAccepted else { return "restoration setter error" }
      guard restoration.verified else { return "restoration no-op" }
      return run.toggle.verified ? "verified round trip" : "no-op"
    }
  }

  private static func restoredValue(_ results: SupportReportWriteTestResults) -> String {
    var anythingWritten = false
    var problems: [String] = []
    if case let .ran(run) = results.listeningModes {
      anythingWritten = true
      if !run.restored {
        problems.append(
          "listening mode is now \(run.finalMode?.rawValue ?? "unknown")"
        )
      }
    }
    if case let .ran(run) = results.conversationAwareness {
      anythingWritten = true
      if !run.restored {
        let state = run.finalState.map { $0 ? "on" : "off" } ?? "unknown"
        problems.append("Conversation Awareness is now \(state)")
      }
    }
    guard anythingWritten else { return "nothing was written" }
    guard !problems.isEmpty else { return "yes" }
    return "no, " + problems.joined(separator: "; ")
      + ". Restore manually in System Settings."
  }

  private static func signalName(_ signalNumber: Int32) -> String {
    switch signalNumber {
    case SIGHUP: return "SIGHUP"
    case SIGINT: return "SIGINT"
    case SIGTERM: return "SIGTERM"
    default: return "signal \(signalNumber)"
    }
  }

  static func issueURL(for draft: SupportReportIssueDraft, includeBody: Bool) -> URL? {
    var components = URLComponents(
      url: repositoryIssuesURL,
      resolvingAgainstBaseURL: false
    )
    var queryItems = [
      URLQueryItem(name: "template", value: issueTemplateName),
    ]
    if includeBody {
      queryItems.append(URLQueryItem(name: "title", value: draft.title))
      queryItems.append(URLQueryItem(name: "body", value: draft.body))
    }
    components?.queryItems = queryItems
    let encodedQuery = components?.percentEncodedQuery
    components?.percentEncodedQuery = encodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return components?.url
  }

  static func safeIssueURL(for draft: SupportReportIssueDraft) -> (url: URL, prefilled: Bool) {
    if let prefilled = issueURL(for: draft, includeBody: true),
       prefilled.absoluteString.count <= maximumPrefilledURLLength
    {
      return (prefilled, true)
    }
    return (issueURL(for: draft, includeBody: false)!, false)
  }
}
