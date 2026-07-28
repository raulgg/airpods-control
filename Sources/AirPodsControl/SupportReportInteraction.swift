import Darwin
import Foundation

// Terminal prompts and browser launching for support-report. This is an I/O
// layer over finished command outcomes; it never builds report content.
enum SupportReportInteraction {
  static func requestWriteTestConsent(
    plan: SupportReportWriteTestPlan,
    inputIsInteractive: Bool = isatty(STDIN_FILENO) == 1,
    readResponse: () -> String? = { readLine() },
    writeError: (String) -> Void = { fputs($0, stderr) }
  ) -> Bool {
    var actions: [String] = []
    if plan.willTestListeningModes, let initialMode = plan.initialListeningMode {
      actions.append(
        " - switch through advertised listening modes recognized by this CLI: "
          + plan.listeningModeTargets.map(\.rawValue).joined(separator: ", ")
          + " (holding each for about two seconds)"
      )
      actions.append(
        " - restore the captured initial listening mode "
          + "(\(initialMode.rawValue)) if needed"
      )
    }
    if plan.willTestConversationAwareness {
      actions.append(
        " - toggle Conversation Awareness away from the captured initial state and back"
      )
    }
    guard !actions.isEmpty else { return false }

    guard inputIsInteractive else {
      writeError(
        "Write tests skipped: standard input is not interactive. "
          + "Pass --with-write-tests to consent to them in scripts.\n\n"
      )
      return false
    }

    writeError("""
    This report can also test write support on your device:
    \(actions.joined(separator: "\n"))

    These tests may be disruptive: mode switches are audible, noise control
    changes while the device is worn, and Conversation Awareness toggles
    briefly. Do not run them during a call.

    After you confirm, the command will run only the checks listed above.
    If a setting changes while you answer, that setting is skipped. After
    testing, the command tries to restore each captured initial setting.
    A setter error stops the remaining tests for that setting.
    The report always states the restoration outcome and names the final state
    when restoration is unverified. Answer yes only if you accept this.

    Run the write tests? [y/N]\u{0020}
    """)
    guard
      let response = readResponse()?.trimmingCharacters(in: .whitespacesAndNewlines),
      ["y", "yes"].contains(response.lowercased())
    else {
      writeError("Write tests skipped. The report below is read-only.\n\n")
      return false
    }
    return true
  }

  static func present(
    outcome: CommandOutcome,
    inputIsInteractive: Bool = isatty(STDIN_FILENO) == 1,
    readResponse: () -> String? = { readLine() },
    openURL: (URL) -> Bool = openInDefaultBrowser,
    writeOutput: (String) -> Void = { print($0); fflush(stdout) },
    writeError: (String) -> Void = { fputs($0, stderr) }
  ) -> Int32 {
    writeOutput(outcome.plain)
    guard let draft = outcome.issueDraft else {
      return outcome.exitCode
    }

    let issueURL = SupportReport.safeIssueURL(for: draft)
    if !issueURL.prefilled {
      writeError(
        "\nThis report is too long for a prefilled GitHub URL. It is still printed above.\n"
      )
    }

    guard inputIsInteractive else {
      writeError(
        "\nReview the report, then open this GitHub issue draft manually "
          + "if you want to submit it:\n"
          + issueURL.url.absoluteString + "\n"
      )
      return outcome.exitCode
    }

    let prompt = issueURL.prefilled
      ? "\nOpen a prefilled GitHub issue in your browser? [y/N] "
      : "\nOpen the GitHub compatibility-report template in your browser? [y/N] "
    writeError(prompt)
    guard let response = readResponse()?.trimmingCharacters(in: .whitespacesAndNewlines),
          ["y", "yes"].contains(response.lowercased())
    else {
      writeError("Not opened. The report remains above.\n")
      return outcome.exitCode
    }

    if openURL(issueURL.url) {
      writeError("Opened the draft in your browser. GitHub has not submitted it.\n")
    } else {
      writeError(
        "Could not open a browser. Open this URL manually:\n"
          + issueURL.url.absoluteString + "\n"
      )
    }
    return outcome.exitCode
  }

  private static func openInDefaultBrowser(_ url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}
