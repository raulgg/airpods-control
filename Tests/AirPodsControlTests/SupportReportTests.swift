import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Support report rendering")
struct SupportReportTests {
  @Test("Renders advertised capabilities without private device data or writes")
  func supportReportContentsAndPrivacy() throws {
    let privateDeviceName = "PRIVATE-DEVICE-NAME-SENTINEL-7D09E9"
    let device = FakeCompatibleAudioDevice(
      name: privateDeviceName,
      listeningModes: [.off, .transparency, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false,
      reportMetadata: .fixture()
    )
    let report = passiveSupportReport(
      device: device,
      operatingSystemVersion: OperatingSystemVersion(
        majorVersion: 26,
        minorVersion: 1,
        patchVersion: 0
      )
    )

    #expect(report != nil, "an identifiable AirPods device produces a report")
    let cliOutput = report?.terminalOutput ?? ""
    #expect(cliOutput.contains("AirPods Pro 3"), "report resolves the model name")
    #expect(
      cliOutput.contains("Off, Transparency, Noise cancellation"),
      "CLI report has readable advertised capabilities"
    )
    #expect(cliOutput.contains("26.1.0"), "report has normalized macOS version")
    #expect(
      !cliOutput.contains("Current listening mode"),
      "report omits the current listening-mode value"
    )
    #expect(
      !cliOutput.contains("Conversation Awareness state"),
      "report omits the Conversation Awareness state value"
    )
    // Seed private source data and assert on the value, not renderer wording.
    // Add another sentinel here if a future adapter boundary gains a new private
    // source; selector/read-count tests remain responsible for proving it is not
    // read in production.
    let issueDraft = report?.githubIssueDraft
    let renderedSurfaces = [
      ("terminal", cliOutput),
      ("GitHub title", issueDraft?.title ?? ""),
      ("GitHub report", issueDraft?.report ?? ""),
    ]
    for (surface, rendered) in renderedSurfaces {
      #expect(
        !rendered.lowercased().contains(privateDeviceName.lowercased()),
        "the \(surface) output omits the private device-name sentinel"
      )
    }
    #expect(device.listeningModeSetCount == 0, "report does not write listening mode")
    #expect(
      device.conversationAwarenessSetCount == 0,
      "report does not write Conversation Awareness"
    )
    #expect(
      device.inEarPlacementStatusReadCount == 0,
      "report does not read ear placement"
    )
    let invocation = try parseInvocation(["support-report"])
    let outcome = CommandExecution.execute(invocation) { _, _ in device }
    #expect(outcome.supportReportIssueDraft != nil, "supported-device command path creates an issue draft")
  }

  @Test("Preserves unavailable metadata and partial-report titles")
  func supportReportUnavailableValuesAndIdentification() throws {
    let unavailable = FakeCompatibleAudioDevice(
      listeningModes: [],
      listeningMode: nil,
      conversationAwarenessSupported: nil,
      conversationAwarenessEnabled: nil,
      reportMetadata: .fixture(
        family: .beats,
        modelIdentifier: "BeatsTest1,1",
        listeningModeQueryAnswered: false
      )
    )
    unavailable.exposesListeningModeSetter = false
    unavailable.exposesConversationAwarenessSetter = false
    let snapshot = SupportReportSnapshot.capture(device: unavailable)
    #expect(snapshot.family == .beats, "the snapshot preserves the exploratory family")
    #expect(snapshot.modelName == nil, "an unmapped identifier invents no model")
    #expect(snapshot.listeningModes.isEmpty, "missing advertised modes stay empty")
    guard case .unavailable = snapshot.listeningModeQuery else {
      Issue.record("an unanswered listening-mode query stays unavailable")
      return
    }
    guard case .unavailable = snapshot.conversationAwarenessSupport else {
      Issue.record("missing Conversation Awareness support stays unavailable")
      return
    }
    #expect(
      snapshot.listeningModeSetterExposed == false
        && snapshot.conversationAwarenessSetterExposed == false,
      "unexposed setters remain absent from the snapshot"
    )

    let unidentified = FakeCompatibleAudioDevice(
      reportMetadata: .fixture(
        family: nil,
        modelIdentifier: nil,
        listeningModeQueryAnswered: false
      )
    )
    let unidentifiedSnapshot = SupportReportSnapshot.capture(device: unidentified)
    #expect(unidentifiedSnapshot.family == nil, "missing family remains unavailable")
    #expect(
      unidentifiedSnapshot.modelIdentifier == nil,
      "missing model identifier remains unavailable"
    )

    let invocation = try parseInvocation(["support-report"])
    let outcome = CommandExecution.execute(invocation) { _, _ in unidentified }
    #expect(outcome.supportReportIssueDraft != nil, "a partial report can be reviewed")
    #expect(
      outcome.supportReportIssueDraft?.title.contains("unidentified Apple audio device") == true,
      "a partial report uses a generic issue title"
    )
  }

  @Test("Escapes device-controlled text for terminal and GitHub")
  func supportReportEscapesDeviceControlledTextPerAdapter() throws {
    let hostile = FakeCompatibleAudioDevice(
      reportMetadata: .fixture(
        modelIdentifier: "airpods www.evil.example/x",
        unrecognizedListeningModes: ["www.evil.example/mode"]
      )
    )
    let report = passiveSupportReport(device: hostile)
    let cliOutput = report?.terminalOutput ?? ""
    let issueReport = report?.githubIssueDraft.report ?? ""
    #expect(
      cliOutput.contains("Identifier               airpods www.evil.example/x"),
      "terminal output renders normalized model text without Markdown"
    )
    #expect(
      cliOutput.contains("Other modes              www.evil.example/mode"),
      "terminal output renders normalized mode text without Markdown"
    )
    #expect(
      issueReport.contains("Model identifier: `airpods www.evil.example/x`"),
      "the GitHub adapter fences device-controlled model text"
    )
    #expect(
      issueReport.contains("Other advertised listening modes: `www.evil.example/mode`"),
      "the GitHub adapter fences device-controlled mode text"
    )

    let unnormalized = FakeCompatibleAudioDevice(
      reportMetadata: .fixture(
        modelIdentifier: "airpods` [CLICK](http://evil.example) `x"
      )
    )
    let unnormalizedReport = SupportReportDocument.make(
      snapshot: SupportReportSnapshot.capture(device: unnormalized)
    )
    #expect(
      unnormalizedReport.device.modelIdentifier == nil,
      "capture drops metadata that escapes the allowlist"
    )
    #expect(
      !unnormalizedReport.terminalOutput.contains("CLICK"),
      "partial report never renders rejected model metadata"
    )

    let hostileModes = FakeCompatibleAudioDevice(
      reportMetadata: .fixture(
        unrecognizedListeningModes: ["mode` [CLICK](http://evil.example) `x"]
      )
    )
    let hostileModesReport = passiveSupportReport(device: hostileModes)
    #expect(
      hostileModesReport?.terminalOutput.contains("Other modes") == false,
      "the terminal adapter omits an empty other-modes row"
    )
    #expect(
      hostileModesReport?.githubIssueDraft.report.contains(
        "Other advertised listening modes: none"
      ) == true,
      "the GitHub adapter reports that rejected mode names were dropped"
    )
  }

  @Test(
    "Normalizes model metadata and rejects unsafe values",
    arguments: [
      MetadataCase("whitespace", "  AirPodsPro2,1   (USB-C) ", "AirPodsPro2,1 (USB-C)"),
      MetadataCase("Markdown punctuation", "AirPodsPro2,1\n- account: exposed", nil),
      MetadataCase("overlong value", String(repeating: "A", count: 81), nil),
      MetadataCase("combining accent", "AirPods Pro\u{0301}", nil),
      MetadataCase(
        "long invisible combining-mark run",
        "AirPods" + String(repeating: "\u{034F}", count: 200_000),
        nil
      ),
    ]
  )
  func normalizesMetadata(_ example: MetadataCase) {
    #expect(
      SupportReportSnapshot.normalizedMetadataValue(example.input, maximumLength: 80)
        == example.expected
    )
  }

  struct MetadataCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let input: String
    let expected: String?

    init(_ name: String, _ input: String, _ expected: String?) {
      self.testDescription = name
      self.input = input
      self.expected = expected
    }
  }

  @Test("Prefills reviewed issue fields with safe URL fallbacks")
  func supportReportIssueURL() throws {
    let draft = SupportReportIssueDraft(
      title: "[Compatibility] AirPods",
      report: "- Model identifier: AirPodsTest1,1"
    )
    let selected = SupportReportIssue.safeURL(for: draft)
    let components = URLComponents(url: selected.url, resolvingAgainstBaseURL: false)
    let query = Dictionary(
      uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )
    #expect(selected.prefilled, "concise report uses a prefilled issue URL")
    #expect(query["title"] == draft.title, "issue URL prefills the title")
    #expect(
      query[SupportReportIssue.reportFieldID] == draft.report,
      "issue URL prefills the reviewed report field by its form ID"
    )
    #expect(query["body"] == nil, "issue URL does not bypass the form with a body parameter")

    let oversized = SupportReportIssueDraft(
      title: draft.title,
      report: String(repeating: "x", count: SupportReportIssue.maximumPrefilledURLLength)
    )
    let fallback = SupportReportIssue.safeURL(for: oversized)
    let fallbackQuery = URLComponents(
      url: fallback.url,
      resolvingAgainstBaseURL: false
    )?.queryItems
    #expect(!fallback.prefilled, "overlong issue URL uses a safe local fallback")
    #expect(
      fallbackQuery?.first(where: { $0.name == "title" })?.value == draft.title,
      "fallback retains the concise dynamic title"
    )
    #expect(
      fallbackQuery?.first(where: { $0.name == SupportReportIssue.reportFieldID }) == nil,
      "fallback omits only the overlong report field"
    )

    let plusDraft = SupportReportIssueDraft(
      title: "[Compatibility] Beats Studio Buds + on macOS 26.1.0",
      report: "- Model: Beats Studio Buds +"
    )
    let plusSelection = SupportReportIssue.safeURL(for: plusDraft)
    #expect(plusSelection.prefilled, "a draft containing plus signs still prefills")
    let encodedQuery = URLComponents(
      url: plusSelection.url,
      resolvingAgainstBaseURL: false
    )?.percentEncodedQuery ?? ""
    #expect(
      !encodedQuery.contains("+"),
      "the prefilled query never carries a literal plus sign"
    )

    let encodedReport = encodedQuery
      .components(separatedBy: "&")
      .first { $0.hasPrefix("\(SupportReportIssue.reportFieldID)=") }
      .map { String($0.dropFirst("\(SupportReportIssue.reportFieldID)=".count)) } ?? ""
    let formDecodedReport = encodedReport
      .replacingOccurrences(of: "+", with: " ")
      .removingPercentEncoding
    #expect(
      formDecodedReport == plusDraft.report,
      "GitHub's form decoding restores the reviewed report exactly"
    )
  }

  @Test("Requires confirmation before opening the reviewed issue URL")
  func supportReportRequiresConfirmationBeforeOpening() throws {
    let device = FakeCompatibleAudioDevice(
      listeningModes: [.transparency, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false,
      reportMetadata: .fixture()
    )
    let document = try #require(passiveSupportReport(device: device))
    let draft = document.githubIssueDraft
    let localReport = document.terminalOutput
    let outcome = CommandOutcome(
      plain: "",
      supportReport: document
    )
    var openCount = 0
    var output = [String]()

    _ = SupportReportInteraction.present(
      outcome: outcome,
      inputIsInteractive: true,
      colorEnabled: false,
      readResponse: { "no" },
      openURL: { _ in
        openCount += 1
        return true
      },
      writeOutput: { output.append($0) },
      writeError: { _ in }
    )
    #expect(openCount == 0, "declining confirmation never opens a browser")
    #expect(output == [localReport], "interaction prints the local report for review first")

    var openedURL: URL?
    _ = SupportReportInteraction.present(
      outcome: outcome,
      inputIsInteractive: true,
      colorEnabled: false,
      readResponse: { "yes" },
      openURL: { url in
        openCount += 1
        openedURL = url
        return true
      },
      writeOutput: { _ in },
      writeError: { _ in }
    )
    #expect(openCount == 1, "affirmative confirmation opens exactly one issue form")
    #expect(
      openedURL == SupportReportIssue.safeURL(for: draft).url,
      "affirmative confirmation opens exactly the reviewed issue URL"
    )
    #expect(
      openedURL?.host == SupportReportIssue.repositoryIssuesURL.host,
      "the opened URL stays on github.com"
    )
    #expect(
      openedURL?.path == SupportReportIssue.repositoryIssuesURL.path,
      "the opened URL stays on the project's new-issue path"
    )

    var noninteractiveReadCount = 0
    _ = SupportReportInteraction.present(
      outcome: outcome,
      inputIsInteractive: false,
      colorEnabled: false,
      readResponse: {
        noninteractiveReadCount += 1
        return "yes"
      },
      openURL: { _ in
        openCount += 1
        return true
      },
      writeOutput: { _ in },
      writeError: { _ in }
    )
    #expect(noninteractiveReadCount == 0, "noninteractive use does not request confirmation")
    #expect(openCount == 1, "noninteractive use never opens a browser automatically")

    let noDevice = CommandOutcome(
      plain: "No identifiable device.",
      terminalReason: .noDevice
    )
    var readCount = 0
    _ = SupportReportInteraction.present(
      outcome: noDevice,
      inputIsInteractive: true,
      readResponse: {
        readCount += 1
        return "yes"
      },
      openURL: { _ in
        openCount += 1
        return true
      },
      writeOutput: { _ in },
      writeError: { _ in }
    )
    #expect(readCount == 0, "no-device path does not ask about issue creation")
    #expect(openCount == 1, "no-device path never opens an issue URL")
  }

  @Test("Prints the reviewed form field when the issue URL is too long")
  func supportReportPrintsPasteReadyFormFallback() throws {
    let baseDocument = try #require(passiveSupportReport(
      device: FakeCompatibleAudioDevice(reportMetadata: .fixture())
    ))
    let oversizedDocument = SupportReportDocument(
      device: SupportReportDocument.Device(
        family: baseDocument.device.family,
        modelName: baseDocument.device.modelName,
        modelIdentifier: String(
          repeating: "x",
          count: SupportReportIssue.maximumPrefilledURLLength
        ),
        bluetoothProductID: nil,
        macOS: baseDocument.device.macOS,
        cliVersion: baseDocument.device.cliVersion
      ),
      capabilities: baseDocument.capabilities,
      writeTests: baseDocument.writeTests,
      restoration: baseDocument.restoration,
      interruptedBySignal: nil
    )
    let draft = oversizedDocument.githubIssueDraft
    let localReport = oversizedDocument.terminalOutput
    let outcome = CommandOutcome(
      plain: "",
      supportReport: oversizedDocument
    )
    var output: [String] = []
    var errors: [String] = []

    _ = SupportReportInteraction.present(
      outcome: outcome,
      inputIsInteractive: false,
      colorEnabled: false,
      readResponse: {
        Issue.record("an overlong noninteractive report never reads input")
        return nil
      },
      openURL: { _ in
        Issue.record("an overlong noninteractive report never opens a browser")
        return false
      },
      writeOutput: { output.append($0) },
      writeError: { errors.append($0) }
    )

    #expect(output.first == localReport, "fallback still prints the local report first")
    #expect(
      output.last?.contains("GitHub report") == true
        && output.last?.contains(draft.report) == true,
      "fallback prints the exact GitHub form field for manual copying"
    )
    #expect(
      errors.joined().contains("too long for a prefilled GitHub URL"),
      "fallback explains why the form field was not prefilled"
    )
  }
}
