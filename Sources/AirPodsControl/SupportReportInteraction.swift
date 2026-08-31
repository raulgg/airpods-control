import Darwin
import Foundation

// Terminal prompts and browser launching for support-report. This is an I/O
// layer over finished command outcomes; it never builds report content.
enum SupportReportInteraction {
  static func requestWriteTestConsent(
    plan: SupportReportWriteTestPlan,
    inputIsInteractive: Bool = isatty(STDIN_FILENO) == 1,
    colorEnabled: Bool = terminalColorsEnabled(fileDescriptor: STDERR_FILENO),
    readResponse: () -> String? = { readLine() },
    writeError: (String) -> Void = { fputs($0, stderr) }
  ) -> Bool {
    guard let prompt = SupportReportConsentRenderer.render(
      plan,
      colorEnabled: colorEnabled
    ) else { return false }

    guard inputIsInteractive else {
      writeError(
        "Write tests skipped: standard input is not interactive. "
          + "Pass --with-write-tests to consent to them in scripts.\n\n"
      )
      return false
    }

    writeError(prompt)
    guard
      let response = readResponse()?.trimmingCharacters(in: .whitespacesAndNewlines),
      ["y", "yes"].contains(response.lowercased())
    else {
      writeError("Write tests skipped. The report below is read-only.\n\n")
      return false
    }
    writeError("\n")
    return true
  }

  static func present(
    outcome: CommandOutcome,
    inputIsInteractive: Bool = isatty(STDIN_FILENO) == 1,
    colorEnabled: Bool = terminalColorsEnabled(fileDescriptor: STDOUT_FILENO),
    terminalWidth: Int = 88,
    readResponse: () -> String? = { readLine() },
    openURL: (URL) -> Bool = openInDefaultBrowser,
    writeOutput: (String) -> Void = { print($0); fflush(stdout) },
    writeError: (String) -> Void = { fputs($0, stderr) }
  ) -> TerminalReason {
    guard let document = outcome.supportReport else {
      writeOutput(outcome.plain)
      return outcome.terminalReason
    }
    writeOutput(
      SupportReportTerminalRenderer.render(
        document,
        options: SupportReportTerminalRenderOptions(
          colorEnabled: colorEnabled,
          width: terminalWidth
        )
      )
    )
    guard document.interruptedBySignal == nil else {
      return outcome.terminalReason
    }

    let draft = SupportReportGitHubRenderer.render(document)
    let issueURL = SupportReportIssue.safeURL(for: draft)
    if !issueURL.prefilled {
      writeError(
        "\nThis report is too long for a prefilled GitHub URL. "
          + "Copy the GitHub report printed below.\n"
      )
      writeOutput(
        """

        GitHub report
        ─────────────
        \(draft.report)
        """
      )
    }

    guard inputIsInteractive else {
      writeError(
        "\nReview the report, then open this GitHub issue form manually "
          + "if you want to submit it:\n"
          + issueURL.url.absoluteString + "\n"
      )
      return outcome.terminalReason
    }

    let prompt = issueURL.prefilled
      ? "\nOpen the prefilled GitHub issue form in your browser? [y/N] "
      : "\nOpen the GitHub compatibility report form in your browser? [y/N] "
    writeError(prompt)
    guard let response = readResponse()?.trimmingCharacters(in: .whitespacesAndNewlines),
          ["y", "yes"].contains(response.lowercased())
    else {
      writeError("Not opened. The report remains above.\n")
      return outcome.terminalReason
    }

    if openURL(issueURL.url) {
      writeError("Opened the form in your browser. GitHub has not submitted it.\n")
    } else {
      writeError(
        "Could not open a browser. Open this URL manually:\n"
          + issueURL.url.absoluteString + "\n"
      )
    }
    return outcome.terminalReason
  }

  private static func terminalColorsEnabled(fileDescriptor: Int32) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return isatty(fileDescriptor) == 1
      && environment["NO_COLOR"] == nil
      && environment["TERM"] != "dumb"
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
