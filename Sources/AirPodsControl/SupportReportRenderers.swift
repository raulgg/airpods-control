import Darwin
import Foundation

struct SupportReportTerminalRenderOptions {
  let colorEnabled: Bool
  let width: Int

  static let plain = SupportReportTerminalRenderOptions(
    colorEnabled: false,
    width: 88
  )
}

enum SupportReportTerminalRenderer {
  private enum Tone {
    case heading
    case positive
    case caution
    case negative
    case muted
  }

  static func render(
    _ document: SupportReportDocument,
    options: SupportReportTerminalRenderOptions = .plain
  ) -> String {
    var lines: [String] = [
      styled("Compatibility report", tone: .heading, options: options),
      styled(String(repeating: "═", count: 44), tone: .heading, options: options),
      "",
      styled("Device", tone: .heading, options: options),
      row(
        "Model",
        document.device.modelName ?? "Not recognized by this CLI version",
        options: options
      ),
      row(
        "Identifier",
        terminalModelIdentifier(document.device),
        options: options
      ),
      row("Family", document.device.family.rawValue, options: options),
      row("macOS", document.device.macOS, options: options),
      row("airpods-control", document.device.cliVersion, options: options),
      "",
      styled("Capabilities", tone: .heading, options: options),
      row(
        "Listening modes",
        terminalListeningModes(document.capabilities.listeningModes),
        options: options
      ),
    ]

    if !document.capabilities.otherListeningModes.isEmpty {
      lines.append(
        row(
          "Other modes",
          document.capabilities.otherListeningModes.rendered(),
          options: options
        )
      )
    }
    lines.append(
      contentsOf: [
        row(
          "Mode query",
          terminalListeningModeQuery(document.capabilities.listeningModeQuery),
          options: options
        ),
        row(
          "Mode setter",
          terminalSetter(document.capabilities.listeningModeSetter),
          options: options
        ),
        row(
          "Conversation Awareness",
          terminalCapability(document.capabilities.conversationAwarenessSupport),
          options: options
        ),
        row(
          "CA query",
          terminalQuery(document.capabilities.conversationAwarenessQuery),
          options: options
        ),
        row(
          "CA setter",
          terminalSetter(document.capabilities.conversationAwarenessSetter),
          options: options
        ),
        "",
        styled("Write tests", tone: .heading, options: options),
      ]
    )

    switch document.writeTests {
    case .notRun:
      lines.append(row("Status", "NOT RUN", tone: .muted, options: options))
    case let .ran(results):
      for result in results {
        let verdict = terminalVerdict(result)
        lines.append(
          row(
            terminalOperation(result.operation),
            verdict.text,
            tone: verdict.tone,
            options: options
          )
        )
      }
      if let signal = document.interruptedBySignal {
        lines.append(
          row(
            "Interruption",
            "INTERRUPTED · \(signalName(signal)); remaining tests skipped",
            tone: .negative,
            options: options
          )
        )
      }
      lines.append(
        row(
          "Summary",
          terminalSummary(document.summary),
          options: options
        )
      )
      let restoration = terminalRestoration(document.restoration)
      lines.append(
        row(
          "Restoration",
          restoration.text,
          tone: restoration.tone,
          options: options
        )
      )
    }

    lines.append(contentsOf: [
      "",
      styled(
        "Review complete. Nothing has been submitted to GitHub.",
        tone: .muted,
        options: options
      ),
    ])
    return lines.joined(separator: "\n")
  }

  private static func terminalModelIdentifier(
    _ device: SupportReportDocument.Device
  ) -> String {
    guard let productID = device.bluetoothProductID else {
      return device.modelIdentifier
    }
    return "\(device.modelIdentifier) · product \(productID)"
  }

  private static func terminalListeningModes(_ modes: [ListeningMode]) -> String {
    modes.isEmpty
      ? "Unavailable / not reported"
      : modes.map(\.displayName).joined(separator: ", ")
  }

  private static func terminalListeningModeQuery(
    _ query: SupportReportListeningModeQuery
  ) -> String {
    switch query {
    case .recognized: return "Available · recognized mode"
    case .unrecognized: return "Available · unrecognized mode"
    case .unavailable: return "Unavailable / not reported"
    }
  }

  private static func terminalCapability(
    _ support: SupportReportCapabilitySupport
  ) -> String {
    switch support {
    case .supported: return "Supported"
    case .notSupported: return "Not supported"
    case .unavailable: return "Unavailable / not reported"
    }
  }

  private static func terminalQuery(
    _ availability: SupportReportQueryAvailability
  ) -> String {
    switch availability {
    case .available: return "Available"
    case .unavailable: return "Unavailable / not reported"
    }
  }

  private static func terminalSetter(
    _ status: SupportReportDocument.SetterStatus
  ) -> String {
    switch status {
    case .notExposed: return "Not exposed"
    case .exposedNotTested: return "Available · not tested"
    case .exposedTested: return "Available · tested below"
    }
  }

  private static func terminalOperation(
    _ operation: SupportReportDocument.WriteTestResult.Operation
  ) -> String {
    switch operation {
    case let .listeningMode(mode): return mode.displayName
    case let .listeningModeRestoration(mode): return mode.displayName
    case .listeningModes: return "Listening modes"
    case .capturedInitialListeningMode: return "Captured initial mode"
    case .remainingListeningModes: return "Remaining mode tests"
    case .conversationAwareness: return "Conversation Awareness"
    case .conversationAwarenessRestoration: return "CA restoration"
    }
  }

  private static func terminalVerdict(
    _ result: SupportReportDocument.WriteTestResult
  ) -> (text: String, tone: Tone) {
    let rendered = terminalVerdict(result.verdict)
    guard case .listeningModeRestoration = result.operation else { return rendered }
    switch result.verdict {
    case .skipped:
      return rendered
    default:
      return (rendered.text + " · restore", rendered.tone)
    }
  }

  private static func terminalVerdict(
    _ verdict: SupportReportDocument.WriteTestResult.Verdict
  ) -> (text: String, tone: Tone) {
    switch verdict {
    case .verified:
      return ("VERIFIED", .positive)
    case let .inconclusive(reason):
      return ("INCONCLUSIVE · \(reason)", .caution)
    case let .noOp(reason):
      let suffix = reason.map { " · \($0)" } ?? ""
      return ("NO-OP\(suffix)", .caution)
    case .setterError:
      return ("SETTER ERROR", .negative)
    case let .skipped(reason):
      return ("SKIPPED · \(reason)", .muted)
    }
  }

  private static func terminalSummary(_ summary: SupportReportDocument.Summary) -> String {
    var parts: [String] = []
    let values = [
      (summary.verified, "verified"),
      (summary.inconclusive, "inconclusive"),
      (summary.noOp, "no-op"),
      (summary.errors, "error"),
      (summary.skipped, "skipped"),
    ]
    for (count, label) in values where count > 0 {
      let plural = label == "error" && count != 1 ? "errors" : label
      parts.append("\(count) \(plural)")
    }
    return parts.isEmpty ? "No results" : parts.joined(separator: " · ")
  }

  private static func terminalRestoration(
    _ restoration: SupportReportDocument.Restoration
  ) -> (text: String, tone: Tone) {
    switch restoration {
    case .notRun:
      return ("NOT RUN", .muted)
    case .nothingWritten:
      return ("NOT NEEDED · nothing was written", .muted)
    case .restored:
      return ("RESTORED", .positive)
    case let .failed(problems):
      let details = problems.map(terminalRestorationProblem).joined(separator: "; ")
      return (
        "NOT RESTORED · \(details). Restore manually in System Settings.",
        .negative
      )
    }
  }

  private static func terminalRestorationProblem(
    _ problem: SupportReportDocument.RestorationProblem
  ) -> String {
    switch problem {
    case let .listeningMode(mode):
      return "listening mode is now \(mode?.displayName ?? "unknown")"
    case let .conversationAwareness(enabled):
      let state = enabled.map { $0 ? "on" : "off" } ?? "unknown"
      return "Conversation Awareness is now \(state)"
    }
  }

  private static func row(
    _ label: String,
    _ value: String,
    tone: Tone? = nil,
    options: SupportReportTerminalRenderOptions
  ) -> String {
    let labelWidth = 24
    let prefix = "  " + label.padding(
      toLength: labelWidth,
      withPad: " ",
      startingAt: 0
    ) + " "
    let continuation = String(repeating: " ", count: prefix.count)
    let valueWidth = max(24, max(60, options.width) - prefix.count)
    return wrapped(value, width: valueWidth).enumerated().map { index, line in
      let rendered = tone.map {
        styled(line, tone: $0, options: options)
      } ?? line
      return (index == 0 ? prefix : continuation) + rendered
    }.joined(separator: "\n")
  }

  private static func wrapped(_ value: String, width: Int) -> [String] {
    guard value.count > width else { return [value] }
    var lines: [String] = []
    var current = ""
    for word in value.split(separator: " ").map(String.init) {
      if current.isEmpty {
        current = word
      } else if current.count + 1 + word.count <= width {
        current += " " + word
      } else {
        lines.append(current)
        current = word
      }
    }
    if !current.isEmpty { lines.append(current) }
    return lines.isEmpty ? [""] : lines
  }

  private static func styled(
    _ value: String,
    tone: Tone,
    options: SupportReportTerminalRenderOptions
  ) -> String {
    guard options.colorEnabled else { return value }
    let code: String
    switch tone {
    case .heading: code = "1;36"
    case .positive: code = "1;32"
    case .caution: code = "1;33"
    case .negative: code = "1;31"
    case .muted: code = "2"
    }
    return "\u{001B}[\(code)m\(value)\u{001B}[0m"
  }
}

enum SupportReportGitHubRenderer {
  static func render(_ document: SupportReportDocument) -> SupportReportIssueDraft {
    var lines = [
      "#### Device",
      "",
      "- Model: "
        + (document.device.modelName ?? "not recognized by this CLI version"),
      "- Model identifier: \(githubModelIdentifier(document.device))",
      "- Device family: \(document.device.family.rawValue)",
      "- macOS: \(document.device.macOS)",
      "- airpods-control: \(document.device.cliVersion)",
      "",
      "#### Capabilities",
      "",
      "- Advertised known listening modes: "
        + githubListeningModes(document.capabilities.listeningModes),
      "- Other advertised listening modes: "
        + githubOtherModes(document.capabilities.otherListeningModes),
      "- Listening-mode query: "
        + githubListeningModeQuery(document.capabilities.listeningModeQuery),
      "- Listening-mode setter: "
        + githubSetter(document.capabilities.listeningModeSetter),
      "- Conversation Awareness capability: "
        + githubCapability(document.capabilities.conversationAwarenessSupport),
      "- Conversation Awareness query: "
        + githubQuery(document.capabilities.conversationAwarenessQuery),
      "- Conversation Awareness setter: "
        + githubSetter(document.capabilities.conversationAwarenessSetter),
      "",
      "#### Write tests",
      "",
    ]

    switch document.writeTests {
    case .notRun:
      lines.append("- Status: not run")
    case let .ran(results):
      lines.append("- Status: run with consent")
      lines.append("")
      lines.append(contentsOf: results.map(githubWriteTestResult))
      if let signal = document.interruptedBySignal {
        lines.append("")
        lines.append(
          "Write tests interrupted by \(signalName(signal)); "
            + "remaining exploratory writes skipped."
        )
      }
    }

    // An unresolved model falls back to the family so the title still says
    // what kind of device the report is about.
    let subject = document.device.modelName ?? document.device.family.rawValue
    return SupportReportIssueDraft(
      title: "[Compatibility] \(subject) on macOS \(document.device.macOS)",
      report: lines.joined(separator: "\n")
    )
  }

  private static func githubModelIdentifier(
    _ device: SupportReportDocument.Device
  ) -> String {
    let identifier = "`\(device.modelIdentifier)`"
    guard let productID = device.bluetoothProductID else { return identifier }
    return "\(identifier) (Bluetooth product ID \(productID))"
  }

  private static func githubListeningModes(_ modes: [ListeningMode]) -> String {
    modes.isEmpty
      ? "unavailable/not reported"
      : modes.map(\.rawValue).joined(separator: ", ")
  }

  private static func githubOtherModes(
    _ modes: SupportReportOtherListeningModes
  ) -> String {
    modes.isEmpty ? "none" : modes.rendered { "`\($0)`" }
  }

  private static func githubListeningModeQuery(
    _ query: SupportReportListeningModeQuery
  ) -> String {
    switch query {
    case .recognized: return "answers with a recognized mode"
    case .unrecognized: return "answers with an unrecognized mode"
    case .unavailable: return "unavailable/not reported"
    }
  }

  private static func githubCapability(
    _ support: SupportReportCapabilitySupport
  ) -> String {
    switch support {
    case .supported: return "supported"
    case .notSupported: return "not supported"
    case .unavailable: return "unavailable/not reported"
    }
  }

  private static func githubQuery(
    _ availability: SupportReportQueryAvailability
  ) -> String {
    switch availability {
    case .available: return "answers"
    case .unavailable: return "unavailable/not reported"
    }
  }

  private static func githubSetter(
    _ status: SupportReportDocument.SetterStatus
  ) -> String {
    switch status {
    case .notExposed: return "not exposed"
    case .exposedNotTested: return "exposed, not tested by this report"
    case .exposedTested: return "exposed (see write tests)"
    }
  }

  private static func githubWriteTestResult(
    _ result: SupportReportDocument.WriteTestResult
  ) -> String {
    let operation: String
    switch result.operation {
    case let .listeningMode(mode):
      operation = "`listening-mode set \(mode.rawValue)`"
    case let .listeningModeRestoration(mode):
      operation = "`listening-mode set \(mode.rawValue)` (restore)"
    case .listeningModes:
      operation = "`listening-mode set`"
    case .capturedInitialListeningMode:
      operation = "`listening-mode set` (captured initial mode)"
    case .remainingListeningModes:
      operation = "Remaining listening-mode tests"
    case .conversationAwareness:
      operation = "`conversation-awareness set`"
    case .conversationAwarenessRestoration:
      operation = "`conversation-awareness set` (restore)"
    }

    return "- \(operation): \(githubVerdict(result.verdict))"
  }

  private static func githubVerdict(
    _ verdict: SupportReportDocument.WriteTestResult.Verdict
  ) -> String {
    switch verdict {
    case .verified: return "verified"
    case let .inconclusive(reason): return "inconclusive (\(reason))"
    case let .noOp(reason):
      return reason.map { "no-op (\($0))" } ?? "no-op"
    case .setterError: return "setter error"
    case let .skipped(reason): return "skipped (\(reason))"
    }
  }
}

private func signalName(_ signalNumber: Int32) -> String {
  switch signalNumber {
  case SIGHUP: return "SIGHUP"
  case SIGINT: return "SIGINT"
  case SIGTERM: return "SIGTERM"
  default: return "signal \(signalNumber)"
  }
}
