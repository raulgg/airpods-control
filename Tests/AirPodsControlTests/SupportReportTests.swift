import Foundation

func testSupportReportContentsAndPrivacy() {
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

  check(report != nil, "an identifiable AirPods device produces a report")
  let cliOutput = report?.terminalOutput ?? ""
  check(cliOutput.contains("AirPods Pro 3"), "report resolves the model name")
  check(
    cliOutput.contains("Off, Transparency, Noise cancellation"),
    "CLI report has readable advertised capabilities"
  )
  check(cliOutput.contains("26.1.0"), "report has normalized macOS version")
  check(
    !cliOutput.contains("Current listening mode"),
    "report omits the current listening-mode value"
  )
  check(
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
    check(
      !rendered.lowercased().contains(privateDeviceName.lowercased()),
      "the \(surface) output omits the private device-name sentinel"
    )
  }
  check(device.listeningModeSetCount == 0, "report does not write listening mode")
  check(
    device.conversationAwarenessSetCount == 0,
    "report does not write Conversation Awareness"
  )
  check(
    device.inEarPlacementStatusReadCount == 0,
    "report does not read ear placement"
  )
  let invocation = try! parseInvocation(["support-report"])
  let outcome = CommandExecution.execute(invocation) { _, _ in device }
  check(outcome.exitCode == 0, "supported-device command path succeeds")
  check(outcome.supportReportIssueDraft != nil, "supported-device command path creates an issue draft")
}

func testSupportReportUnavailableValuesAndIdentification() {
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
  check(snapshot.family == .beats, "the snapshot preserves the exploratory family")
  check(snapshot.modelName == nil, "an unmapped identifier invents no model")
  check(snapshot.listeningModes.isEmpty, "missing advertised modes stay empty")
  if case .unavailable = snapshot.listeningModeQuery {
    check(true, "an unanswered listening-mode query stays unavailable")
  } else {
    check(false, "an unanswered listening-mode query stays unavailable")
  }
  if case .unavailable = snapshot.conversationAwarenessSupport {
    check(true, "missing Conversation Awareness support stays unavailable")
  } else {
    check(false, "missing Conversation Awareness support stays unavailable")
  }
  check(
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
  check(unidentifiedSnapshot.family == nil, "missing family remains unavailable")
  check(
    unidentifiedSnapshot.modelIdentifier == nil,
    "missing model identifier remains unavailable"
  )

  let invocation = try! parseInvocation(["support-report"])
  let outcome = CommandExecution.execute(invocation) { _, _ in unidentified }
  check(outcome.exitCode == 0, "a connected unidentified device produces a partial report")
  check(outcome.payload["error"] == nil, "a partial report is not an error")
  check(outcome.supportReportIssueDraft != nil, "a partial report can be reviewed")
  check(
    outcome.supportReportIssueDraft?.title.contains("unidentified Apple audio device") == true,
    "a partial report uses a generic issue title"
  )
}

func testSupportReportEscapesDeviceControlledTextPerAdapter() {
  let hostile = FakeCompatibleAudioDevice(
    reportMetadata: .fixture(
      modelIdentifier: "airpods www.evil.example/x",
      unrecognizedListeningModes: ["www.evil.example/mode"]
    )
  )
  let report = passiveSupportReport(device: hostile)
  let cliOutput = report?.terminalOutput ?? ""
  let issueReport = report?.githubIssueDraft.report ?? ""
  check(
    cliOutput.contains("Identifier               airpods www.evil.example/x"),
    "terminal output renders normalized model text without Markdown"
  )
  check(
    cliOutput.contains("Other modes              www.evil.example/mode"),
    "terminal output renders normalized mode text without Markdown"
  )
  check(
    issueReport.contains("Model identifier: `airpods www.evil.example/x`"),
    "the GitHub adapter fences device-controlled model text"
  )
  check(
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
  check(
    unnormalizedReport.device.modelIdentifier == nil,
    "capture drops metadata that escapes the allowlist"
  )
  check(
    !unnormalizedReport.terminalOutput.contains("CLICK"),
    "partial report never renders rejected model metadata"
  )

  let hostileModes = FakeCompatibleAudioDevice(
    reportMetadata: .fixture(
      unrecognizedListeningModes: ["mode` [CLICK](http://evil.example) `x"]
    )
  )
  let hostileModesReport = passiveSupportReport(device: hostileModes)
  check(
    hostileModesReport?.terminalOutput.contains("Other modes") == false,
    "the terminal adapter omits an empty other-modes row"
  )
  check(
    hostileModesReport?.githubIssueDraft.report.contains(
      "Other advertised listening modes: none"
    ) == true,
    "the GitHub adapter reports that rejected mode names were dropped"
  )
}

func testSupportReportMetadataNormalization() {
  check(
    SupportReportSnapshot.normalizedMetadataValue(
      "  AirPodsPro2,1   (USB-C) ",
      maximumLength: 80
    ) == "AirPodsPro2,1 (USB-C)",
    "model metadata trims and collapses whitespace"
  )
  check(
    SupportReportSnapshot.normalizedMetadataValue(
      "AirPodsPro2,1\n- account: exposed",
      maximumLength: 80
    ) == nil,
    "model metadata rejects Markdown punctuation outside the allowlist"
  )
  check(
    SupportReportSnapshot.normalizedMetadataValue(
      String(repeating: "A", count: 81),
      maximumLength: 80
    ) == nil,
    "model metadata rejects overlong values"
  )
  check(
    SupportReportSnapshot.normalizedMetadataValue("AirPods Pro\u{0301}", maximumLength: 80) == nil,
    "model metadata rejects non-ASCII combining marks"
  )
  check(
    SupportReportSnapshot.normalizedMetadataValue(
      "AirPods" + String(repeating: "\u{034F}", count: 200_000),
      maximumLength: 80
    ) == nil,
    "model metadata rejects invisible combining-mark runs of any length"
  )
}

func testSupportReportIssueURL() {
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
  check(selected.prefilled, "concise report uses a prefilled issue URL")
  check(query["title"] == draft.title, "issue URL prefills the title")
  check(
    query[SupportReportIssue.reportFieldID] == draft.report,
    "issue URL prefills the reviewed report field by its form ID"
  )
  check(query["body"] == nil, "issue URL does not bypass the form with a body parameter")

  let oversized = SupportReportIssueDraft(
    title: draft.title,
    report: String(repeating: "x", count: SupportReportIssue.maximumPrefilledURLLength)
  )
  let fallback = SupportReportIssue.safeURL(for: oversized)
  let fallbackQuery = URLComponents(
    url: fallback.url,
    resolvingAgainstBaseURL: false
  )?.queryItems
  check(!fallback.prefilled, "overlong issue URL uses a safe local fallback")
  check(
    fallbackQuery?.first(where: { $0.name == "title" })?.value == draft.title,
    "fallback retains the concise dynamic title"
  )
  check(
    fallbackQuery?.first(where: { $0.name == SupportReportIssue.reportFieldID }) == nil,
    "fallback omits only the overlong report field"
  )

  let plusDraft = SupportReportIssueDraft(
    title: "[Compatibility] Beats Studio Buds + on macOS 26.1.0",
    report: "- Model: Beats Studio Buds +"
  )
  let plusSelection = SupportReportIssue.safeURL(for: plusDraft)
  check(plusSelection.prefilled, "a draft containing plus signs still prefills")
  let encodedQuery = URLComponents(
    url: plusSelection.url,
    resolvingAgainstBaseURL: false
  )?.percentEncodedQuery ?? ""
  check(
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
  check(
    formDecodedReport == plusDraft.report,
    "GitHub's form decoding restores the reviewed report exactly"
  )
}

func testSupportReportRequiresConfirmationBeforeOpening() {
  let device = FakeCompatibleAudioDevice(
    listeningModes: [.transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture()
  )
  let document = passiveSupportReport(device: device)!
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
  check(openCount == 0, "declining confirmation never opens a browser")
  check(output == [localReport], "interaction prints the local report for review first")

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
  check(openCount == 1, "affirmative confirmation opens exactly one issue form")
  check(
    openedURL == SupportReportIssue.safeURL(for: draft).url,
    "affirmative confirmation opens exactly the reviewed issue URL"
  )
  check(
    openedURL?.host == SupportReportIssue.repositoryIssuesURL.host,
    "the opened URL stays on github.com"
  )
  check(
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
  check(noninteractiveReadCount == 0, "noninteractive use does not request confirmation")
  check(openCount == 1, "noninteractive use never opens a browser automatically")

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
  check(readCount == 0, "no-device path does not ask about issue creation")
  check(openCount == 1, "no-device path never opens an issue URL")
}

func testSupportReportPrintsPasteReadyFormFallback() {
  let baseDocument = passiveSupportReport(
    device: FakeCompatibleAudioDevice(reportMetadata: .fixture())
  )!
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
      check(false, "an overlong noninteractive report never reads input")
      return nil
    },
    openURL: { _ in
      check(false, "an overlong noninteractive report never opens a browser")
      return false
    },
    writeOutput: { output.append($0) },
    writeError: { errors.append($0) }
  )

  check(output.first == localReport, "fallback still prints the local report first")
  check(
    output.last?.contains("GitHub report") == true
      && output.last?.contains(draft.report) == true,
    "fallback prints the exact GitHub form field for manual copying"
  )
  check(
    errors.joined().contains("too long for a prefilled GitHub URL"),
    "fallback explains why the form field was not prefilled"
  )
}

func runSupportReportTests() {
  testSupportReportContentsAndPrivacy()
  testSupportReportUnavailableValuesAndIdentification()
  testSupportReportEscapesDeviceControlledTextPerAdapter()
  testSupportReportMetadataNormalization()
  testSupportReportIssueURL()
  testSupportReportRequiresConfirmationBeforeOpening()
  testSupportReportPrintsPasteReadyFormFallback()
}
