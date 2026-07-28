import Darwin
import Foundation

enum SupportReportDeviceFamily: String {
  case airPods = "AirPods"
  case beats = "Beats (exploratory)"
  case unknownApple = "Apple or Beats (unidentified, exploratory)"
}

struct SupportReportDeviceMetadata {
  let family: SupportReportDeviceFamily?
  let modelIdentifier: String?
  let unrecognizedListeningModes: [String]
  let listeningModeQueryAnswered: Bool
}

struct SupportReportProduct {
  let family: SupportReportDeviceFamily
  let modelName: String?
  let bluetoothProductID: Int?
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
  static let maximumModelIdentifierLength = 80
  static let maximumUnrecognizedListeningModeLength = 80
  static let maximumUnrecognizedListeningModeCount = 6

  let markdown: String
  let issueDraft: SupportReportIssueDraft
  private let renderInputs: RenderInputs

  private struct RenderInputs {
    let family: SupportReportDeviceFamily
    let model: String
    let modelIdentifier: String
    let listeningModes: String
    let otherModes: String
    let listeningModeQuery: String
    let listeningModeSetterExposed: Bool
    let conversationAwarenessSupport: String
    let conversationAwarenessQuery: String
    let conversationAwarenessSetterExposed: Bool
    let macOS: String
    let titleSubject: String
  }

  static func make(
    device: any CompatibleAudioDevice,
    writeTests: SupportReportWriteTestResults? = nil,
    operatingSystemVersion: OperatingSystemVersion =
      ProcessInfo.processInfo.operatingSystemVersion
  ) -> SupportReport? {
    let metadata = device.supportReportMetadata()
    guard let family = metadata.family,
          let modelIdentifier = normalizedMetadataValue(
            metadata.modelIdentifier,
            maximumLength: maximumModelIdentifierLength
          )
    else {
      return nil
    }

    let availableModes = Set(device.availableListeningModes())
    let listeningModes = ListeningMode.allCases.filter { availableModes.contains($0) }
    let listeningModesValue = listeningModes.isEmpty
      ? "unavailable/not reported"
      : listeningModes.map(\.rawValue).joined(separator: ", ")

    let listeningModeQuery: String
    if device.currentListeningMode() != nil {
      listeningModeQuery = "answers with a recognized mode"
    } else if metadata.listeningModeQueryAnswered {
      listeningModeQuery = "answers with an unrecognized mode"
    } else {
      listeningModeQuery = "unavailable/not reported"
    }

    let conversationAwarenessSupport: String
    switch device.supportsConversationAwareness() {
    case .some(true): conversationAwarenessSupport = "supported"
    case .some(false): conversationAwarenessSupport = "not supported"
    case .none: conversationAwarenessSupport = "unavailable/not reported"
    }
    let conversationAwarenessQuery = device.conversationAwarenessState() != nil
      ? "answers"
      : "unavailable/not reported"

    let resolvedProduct = product(for: metadata.modelIdentifier)
    let model = resolvedProduct?.modelName ?? "not recognized by this CLI version"
    let modelIdentifierValue: String
    if let productID = resolvedProduct?.bluetoothProductID {
      modelIdentifierValue =
        "`\(modelIdentifier)` (Bluetooth product ID \(hexProductID(productID)))"
    } else {
      modelIdentifierValue = "`\(modelIdentifier)`"
    }
    let otherModes = unrecognizedListeningModesValue(metadata.unrecognizedListeningModes)

    let macOS = [
      operatingSystemVersion.majorVersion,
      operatingSystemVersion.minorVersion,
      operatingSystemVersion.patchVersion,
    ].map(String.init).joined(separator: ".")

    let renderInputs = RenderInputs(
      family: family,
      model: model,
      modelIdentifier: modelIdentifierValue,
      listeningModes: listeningModesValue,
      otherModes: otherModes,
      listeningModeQuery: listeningModeQuery,
      listeningModeSetterExposed: device.canSetListeningMode(),
      conversationAwarenessSupport: conversationAwarenessSupport,
      conversationAwarenessQuery: conversationAwarenessQuery,
      conversationAwarenessSetterExposed: device.canSetConversationAwareness(),
      macOS: macOS,
      titleSubject: resolvedProduct?.modelName ?? family.rawValue
    )
    return render(renderInputs, writeTests: writeTests)
  }

  func including(writeTests: SupportReportWriteTestResults) -> SupportReport {
    Self.render(renderInputs, writeTests: writeTests)
  }

  private static func render(
    _ inputs: RenderInputs,
    writeTests: SupportReportWriteTestResults?
  ) -> SupportReport {
    let setterTested = writeTests != nil
    let listeningModeSetter = setterValue(
      inputs.listeningModeSetterExposed, tested: setterTested
    )
    let conversationAwarenessSetter = setterValue(
      inputs.conversationAwarenessSetterExposed, tested: setterTested
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

    - Device family: \(inputs.family.rawValue)
    - Model: \(inputs.model)
    - Model identifier: \(inputs.modelIdentifier)
    - Advertised known listening modes: \(inputs.listeningModes)
    - Other advertised listening modes: \(inputs.otherModes)
    - Listening-mode query: \(inputs.listeningModeQuery)
    - Listening-mode setter: \(listeningModeSetter)
    - Conversation Awareness capability: \(inputs.conversationAwarenessSupport)
    - Conversation Awareness query: \(inputs.conversationAwarenessQuery)
    - Conversation Awareness setter: \(conversationAwarenessSetter)\(writeTestsSummaryLine)
    - macOS: \(inputs.macOS)
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
        title: "[Compatibility] \(inputs.titleSubject) on macOS \(inputs.macOS)",
        body: issueBody
      ),
      renderInputs: inputs
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
    if let reason = results.modeTestsSkippedReason {
      lines.append("- `listening-mode set`: skipped (\(reason))")
    } else {
      for result in results.modeResults {
        lines.append(
          "- `listening-mode set \(result.mode.rawValue)`: \(modeVerdict(result))"
        )
      }
      if results.modeTestsStoppedAfterSetterError {
        lines.append("- Remaining listening-mode tests: skipped after setter error")
      }
      if let restoration = results.listeningModeRestorationResult {
        lines.append(
          "- `listening-mode set \(restoration.mode.rawValue)`: "
            + modeVerdict(restoration)
        )
      }
      if results.initialModeTestSkipped {
        // Deliberately unnamed: the report is pasted publicly and must not
        // disclose which mode the device was in.
        lines.append(
          "- `listening-mode set` (captured initial mode): "
            + "skipped (state never changed from initial)"
        )
      }
    }
    if let reason = results.conversationAwarenessSkippedReason {
      lines.append("- `conversation-awareness set`: skipped (\(reason))")
    } else {
      let verdict: String
      if results.conversationAwarenessSetterAccepted == false {
        verdict = "setter error"
      } else if results.conversationAwarenessRestorationSetterAccepted == false {
        verdict = "restoration setter error"
      } else if results.conversationAwarenessRestorationVerified == false {
        verdict = "restoration no-op"
      } else if results.conversationAwarenessToggleVerified == true {
        verdict = "verified round trip"
      } else {
        verdict = "no-op"
      }
      lines.append("- `conversation-awareness set`: \(verdict)")
    }
    let section = "### Write tests (run with consent)\n\n" + lines.joined(separator: "\n")
    let interruption = results.interruptedBySignal.map {
      "\n\nWrite tests interrupted by \(signalName($0)); "
        + "remaining exploratory writes skipped."
    } ?? ""
    return section + interruption
  }

  private static func modeVerdict(
    _ result: SupportReportWriteTestResults.ModeResult
  ) -> String {
    if !result.setterAccepted {
      return "setter error"
    }
    if result.verified {
      return result.targetAlreadyCurrent
        ? "verified (already in this state; no transition demonstrated)"
        : "verified"
    }
    if result.inferredOffFallback {
      return "no-op (expected Transparency fallback)"
    }
    return "no-op"
  }

  private static func restoredValue(_ results: SupportReportWriteTestResults) -> String {
    let nothingTested = results.modeTestsSkippedReason != nil
      && results.conversationAwarenessSkippedReason != nil
    if nothingTested { return "nothing was written" }
    guard !results.fullyRestored else { return "yes" }
    var problems: [String] = []
    if results.listeningModeRestored == false {
      problems.append(
        "listening mode is now \(results.finalListeningMode?.rawValue ?? "unknown")"
      )
    }
    if results.conversationAwarenessRestored == false {
      let state =
        results.finalConversationAwareness.map { $0 ? "on" : "off" } ?? "unknown"
      problems.append("Conversation Awareness is now \(state)")
    }
    return "no, " + problems.joined(separator: "; ")
      + ". Restore manually in System Settings."
  }

  private static func signalName(_ signalNumber: Int32) -> String {
    switch signalNumber {
    case SIGINT: return "SIGINT"
    case SIGTERM: return "SIGTERM"
    default: return "signal \(signalNumber)"
    }
  }

  private static func unrecognizedListeningModesValue(_ rawModes: [String]) -> String {
    let normalized = rawModes.compactMap {
      normalizedMetadataValue(
        $0,
        maximumLength: maximumUnrecognizedListeningModeLength
      )
    }
    guard !normalized.isEmpty else { return "none" }
    let listed = normalized.prefix(maximumUnrecognizedListeningModeCount)
    let overflow = normalized.count - listed.count
    let suffix = overflow > 0 ? ", and \(overflow) more" : ""
    return listed.map { "`\($0)`" }.joined(separator: ", ") + suffix
  }

  static func hexProductID(_ productID: Int) -> String {
    "0x" + String(format: "%04X", productID)
  }

  static func normalizedMetadataValue(_ value: String?, maximumLength: Int) -> String? {
    guard let value else { return nil }
    let normalized = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let allowedCharacters = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,_()+-/"
    )
    guard !normalized.isEmpty,
          normalized.unicodeScalars.count <= maximumLength,
          normalized.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) })
    else {
      return nil
    }
    return normalized
  }

  private static let appleVendorID = 76
  private static let bluetoothModelIDPrefix = "BTHeadphones"

  // Product IDs and model names from MagicPodsCore's AapModelIds table,
  // cross-checked against AirPodsDesktop's AppleCP.cpp, librepods, and
  // The Apple Wiki. Names follow docs/compatibility.md:
  // https://github.com/steam3d/MagicPodsCore/blob/main/src/sdk/aap/enums/AapModelIds.h
  private static let appleAudioProducts:
    [Int: (family: SupportReportDeviceFamily, name: String)] = [
      0x2002: (.airPods, "AirPods 1"),
      0x200A: (.airPods, "AirPods Max 1 (Lightning)"),
      0x200E: (.airPods, "AirPods Pro 1"),
      0x200F: (.airPods, "AirPods 2"),
      0x2013: (.airPods, "AirPods 3"),
      0x2014: (.airPods, "AirPods Pro 2 (Lightning)"),
      0x2019: (.airPods, "AirPods 4"),
      0x201B: (.airPods, "AirPods 4 (ANC)"),
      0x201F: (.airPods, "AirPods Max 1 (USB-C)"),
      0x2024: (.airPods, "AirPods Pro 2 (USB-C)"),
      0x2027: (.airPods, "AirPods Pro 3"),
      0x202D: (.airPods, "AirPods Max 2"),
      0x2003: (.beats, "Powerbeats3"),
      0x2005: (.beats, "BeatsX"),
      0x2006: (.beats, "Beats Solo3"),
      0x2009: (.beats, "Beats Studio3 Wireless"),
      0x200B: (.beats, "Powerbeats Pro"),
      0x200C: (.beats, "Beats Solo Pro"),
      0x200D: (.beats, "Powerbeats 4"),
      0x2010: (.beats, "Beats Flex"),
      0x2011: (.beats, "Beats Studio Buds"),
      0x2012: (.beats, "Beats Fit Pro"),
      0x2016: (.beats, "Beats Studio Buds +"),
      0x2017: (.beats, "Beats Studio Pro"),
      0x201D: (.beats, "Powerbeats Pro 2"),
      0x2025: (.beats, "Beats Solo 4"),
      0x2026: (.beats, "Beats Solo Buds"),
      0x202F: (.beats, "Powerbeats Fit"),
    ]

  static func family(for modelIdentifier: String?) -> SupportReportDeviceFamily? {
    product(for: modelIdentifier)?.family
  }

  static func product(for modelIdentifier: String?) -> SupportReportProduct? {
    guard let modelIdentifier else { return nil }
    if let bluetoothIDs = bluetoothIdentifiers(for: modelIdentifier) {
      guard bluetoothIDs.vendorID == appleVendorID else { return nil }
      guard let known = appleAudioProducts[bluetoothIDs.productID] else {
        return SupportReportProduct(
          family: .unknownApple,
          modelName: nil,
          bluetoothProductID: bluetoothIDs.productID
        )
      }
      return SupportReportProduct(
        family: known.family,
        modelName: known.name,
        bluetoothProductID: bluetoothIDs.productID
      )
    }
    let normalized = modelIdentifier.lowercased()
    if normalized.contains("airpods") {
      return SupportReportProduct(
        family: .airPods, modelName: nil, bluetoothProductID: nil
      )
    }
    if normalized.contains("beats") {
      return SupportReportProduct(
        family: .beats, modelName: nil, bluetoothProductID: nil
      )
    }
    return nil
  }

  private static func bluetoothIdentifiers(
    for modelIdentifier: String
  ) -> (vendorID: Int, productID: Int)? {
    let prefix = modelIdentifier.prefix(bluetoothModelIDPrefix.count)
    guard prefix.lowercased() == bluetoothModelIDPrefix.lowercased() else { return nil }
    let fields = modelIdentifier.dropFirst(prefix.count).components(separatedBy: ",")
    guard fields.count == 2,
          let vendorID = decimalIdentifier(fields[0]),
          let productID = decimalIdentifier(fields[1])
    else {
      return nil
    }
    return (vendorID, productID)
  }

  // Bluetooth vendor and product IDs are 16-bit. Larger fields would also
  // truncate in the %04X hex rendering, so reject them outright.
  private static let maximumBluetoothIdentifierValue = 0xFFFF

  private static func decimalIdentifier(_ field: String) -> Int? {
    guard !field.isEmpty,
          field.allSatisfy({ $0.isASCII && $0.isNumber }),
          let value = Int(field),
          value <= maximumBluetoothIdentifierValue
    else {
      return nil
    }
    return value
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
    testing, the command makes a best-effort attempt to restore each captured
    initial setting. A setter error stops the remaining tests for that setting.
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
