import Darwin
import Foundation

enum SupportReportDeviceFamily: String {
  case airPods = "AirPods"
  case beats = "Beats (exploratory)"
}

enum SupportReportConnectionState: String {
  case connected = "connected"
}

struct SupportReportDeviceMetadata {
  let family: SupportReportDeviceFamily?
  let modelIdentifier: String?
  let firmwareVersion: String?
  let connectionState: SupportReportConnectionState
}

struct SupportReportIssueDraft {
  let title: String
  let body: String
}

struct SupportReport {
  static let repositoryIssuesURL =
    URL(string: "https://github.com/raulgg/airpods-control/issues/new")!
  static let issueTemplateName = "compatibility-report.md"
  static let maximumPrefilledURLLength = 6_000

  let markdown: String
  let issueDraft: SupportReportIssueDraft

  static func make(
    device: any CompatibleAudioDevice,
    operatingSystemVersion: OperatingSystemVersion =
      ProcessInfo.processInfo.operatingSystemVersion
  ) -> SupportReport? {
    let metadata = device.supportReportMetadata()
    guard let family = metadata.family,
          let modelIdentifier = metadata.modelIdentifier
    else {
      return nil
    }

    let listeningModes = device.availableListeningModes()
    let listeningModesValue = listeningModes.isEmpty
      ? "unavailable/not reported"
      : listeningModes.map(\.rawValue).joined(separator: ", ")
    let listeningModeState = device.currentListeningMode()?.rawValue ?? "unavailable"
    let conversationAwarenessSupport: String
    switch device.supportsConversationAwareness() {
    case .some(true): conversationAwarenessSupport = "supported"
    case .some(false): conversationAwarenessSupport = "not supported"
    case .none: conversationAwarenessSupport = "unavailable/not reported"
    }
    let conversationAwarenessState: String
    switch device.conversationAwarenessState() {
    case .some(true): conversationAwarenessState = "on"
    case .some(false): conversationAwarenessState = "off"
    case .none: conversationAwarenessState = "unavailable"
    }

    let firmware = metadata.firmwareVersion ?? "unavailable/not reported"
    let macOS = [
      operatingSystemVersion.majorVersion,
      operatingSystemVersion.minorVersion,
      operatingSystemVersion.patchVersion,
    ].map(String.init).joined(separator: ".")

    let markdown = """
    ### Compatibility report

    - Device family: \(family.rawValue)
    - Model identifier: \(modelIdentifier)
    - Firmware: \(firmware)
    - Connection state: \(metadata.connectionState.rawValue)
    - Advertised known listening modes: \(listeningModesValue)
    - Current listening mode: \(listeningModeState)
    - Conversation Awareness capability: \(conversationAwarenessSupport)
    - Conversation Awareness state: \(conversationAwarenessState)
    - macOS: \(macOS)
    - airpods-control: \(VERSION)

    _Created locally by `airpods-control support-report`. Check it before submitting._
    """

    return SupportReport(
      markdown: markdown,
      issueDraft: SupportReportIssueDraft(
        title: "[Compatibility] \(family.rawValue) on macOS \(macOS)",
        body: markdown
      )
    )
  }

  static func normalizedMetadataValue(_ value: String?, maximumLength: Int) -> String? {
    guard let value else { return nil }
    let normalized = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let allowedCharacters = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: " .,_()+-/")
    )
    guard !normalized.isEmpty,
          normalized.count <= maximumLength,
          normalized.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) })
    else {
      return nil
    }
    return normalized
  }

  static func family(for modelIdentifier: String?) -> SupportReportDeviceFamily? {
    guard let modelIdentifier else { return nil }
    let normalized = modelIdentifier.lowercased()
    if normalized.contains("airpods") {
      return .airPods
    }
    if normalized.contains("beats") {
      return .beats
    }
    return nil
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

enum SupportReportInteraction {
  static func present(
    outcome: CommandOutcome,
    inputIsInteractive: Bool = isatty(STDIN_FILENO) == 1,
    readResponse: () -> String? = { readLine() },
    openURL: (URL) -> Bool = openInDefaultBrowser,
    writeOutput: (String) -> Void = { print($0) },
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
