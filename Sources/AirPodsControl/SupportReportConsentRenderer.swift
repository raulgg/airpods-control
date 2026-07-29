import Foundation

enum SupportReportConsentRenderer {
  static func render(
    _ plan: SupportReportWriteTestPlan,
    colorEnabled: Bool = false
  ) -> String? {
    var rows: [(String, String)] = []
    if plan.willTestListeningModes, let initialMode = plan.initialListeningMode {
      rows.append(
        (
          "Listening modes",
          plan.listeningModeTargets.map(\.rawValue).joined(separator: ", ")
            + " (about 2s each)"
        )
      )
      rows.append(("Restore mode", initialMode.rawValue))
    }
    if plan.willTestConversationAwareness {
      rows.append(("Conversation Awareness", "toggle and restore"))
    }
    guard !rows.isEmpty else { return nil }

    var lines = [
      styled("Write tests", code: "1;36", enabled: colorEnabled),
      styled(String(repeating: "─", count: 44), code: "1;36", enabled: colorEnabled),
      "Plan",
    ]
    lines.append(
      contentsOf: rows.map { label, value in
        "  " + label.padding(toLength: 24, withPad: " ", startingAt: 0) + " " + value
      }
    )
    lines.append(contentsOf: [
      "",
      "Caution   Changes are audible. Do not run these tests during a call.",
      "Safety    A setting is skipped if it changes before testing.",
      "Restore   Captured settings are restored when possible; failures are reported.",
      "",
      "Run write tests? [y/N] ",
    ])
    return lines.joined(separator: "\n")
  }

  private static func styled(
    _ value: String,
    code: String,
    enabled: Bool
  ) -> String {
    enabled ? "\u{001B}[\(code)m\(value)\u{001B}[0m" : value
  }
}
