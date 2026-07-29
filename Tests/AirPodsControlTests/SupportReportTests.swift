import Darwin
import Foundation

func testSupportReportContentsAndPrivacy() {
  let device = FakeCompatibleAudioDevice(
    name: "",
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
    cliOutput.contains("BTHeadphones76,8231 · product 0x2027"),
    "CLI report has the model ID with its decoded Bluetooth product ID"
  )
  check(
    cliOutput.contains("Off, Transparency, Noise cancellation"),
    "CLI report has readable advertised capabilities"
  )
  check(
    !cliOutput.contains("Other modes"),
    "CLI report omits an empty other-modes row"
  )
  check(
    cliOutput.contains("Available · recognized mode"),
    "CLI report says the mode query answers without exposing the mode"
  )
  check(
    cliOutput.contains("Available · not tested"),
    "CLI report says exposed setters were not tested"
  )
  check(
    cliOutput.contains("Supported"),
    "CLI report has advertised Conversation Awareness support"
  )
  check(
    cliOutput.contains("CA query"),
    "CLI report includes Conversation Awareness query availability"
  )
  check(
    cliOutput.contains("CA setter"),
    "CLI report includes Conversation Awareness setter availability"
  )
  check(cliOutput.contains("26.1.0"), "report has normalized macOS version")
  check(cliOutput.contains(VERSION), "report has CLI version")
  check(!cliOutput.contains("Firmware"), "report omits firmware")
  check(!cliOutput.contains("Connection state"), "report omits connection state")
  check(
    !cliOutput.contains("Current listening mode"),
    "report omits the current listening-mode value"
  )
  check(
    !cliOutput.contains("Conversation Awareness state"),
    "report omits the Conversation Awareness state value"
  )
  check(
    !cliOutput.contains("###") && !cliOutput.contains("`"),
    "CLI report uses terminal-native formatting rather than Markdown"
  )
  for excluded in ["serial", "MAC address", "account", "device name", "raw dump"] {
    check(
      !cliOutput.lowercased().contains(excluded.lowercased()),
      "report omits excluded field \(excluded)"
    )
  }
  check(device.listeningModeSetCount == 0, "report does not write listening mode")
  check(
    device.conversationAwarenessSetCount == 0,
    "report does not write Conversation Awareness"
  )
  check(
    report?.githubIssueDraft.title == "[Compatibility] AirPods Pro 3 on macOS 26.1.0",
    "the issue title names the resolved model"
  )

  let invocation = try! parseInvocation(["support-report"])
  let outcome = CommandExecution.execute(invocation) { _, _ in device }
  check(outcome.exitCode == 0, "supported-device command path succeeds")
  check(outcome.supportReportIssueDraft != nil, "supported-device command path creates an issue draft")
  check(
    outcome.supportReportOutput.contains(
      "Review complete. Nothing has been submitted to GitHub."
    ),
    "the CLI report carries its local-only completion note"
  )
  check(
    outcome.supportReportIssueDraft?.report.hasPrefix(
      "#### Device\n\n- Model: AirPods Pro 3"
    ) == true,
    "the issue field starts with the same Device section as the CLI"
  )
  let issueReport = outcome.supportReportIssueDraft?.report ?? ""
  let sectionNames = ["#### Device", "#### Capabilities", "#### Write tests"]
  let sectionOffsets = sectionNames.compactMap {
    issueReport.range(of: $0)?.lowerBound
  }
  check(
    sectionOffsets.count == sectionNames.count
      && sectionOffsets == sectionOffsets.sorted(),
    "the issue field follows the CLI section order"
  )
  check(
    issueReport.contains("#### Write tests\n\n- Status: not run"),
    "the issue field reports skipped write tests inside their own section"
  )
  check(
    !issueReport.contains("### Compatibility report"),
    "the issue field lets the form supply its own compatibility heading"
  )
  check(
    outcome.supportReportIssueDraft?.report.contains("Created locally by") == false
      && outcome.supportReportIssueDraft?.report.contains("Notes (optional)") == false,
    "the issue field omits local-only and user-authored form sections"
  )
}

func testSupportReportDocumentFeedsPureOutputAdapters() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: .fixture()
  )
  let snapshot = SupportReportSnapshot.capture(
    device: device,
    operatingSystemVersion: OperatingSystemVersion(
      majorVersion: 26,
      minorVersion: 1,
      patchVersion: 0
    )
  )!
  let document = SupportReportDocument.make(
    snapshot: snapshot,
    writeTests: SupportReportWriteTester.run(device: device)
  )
  let options = SupportReportTerminalRenderOptions(
    colorEnabled: false,
    width: 60
  )

  let firstTerminalOutput = SupportReportTerminalRenderer.render(
    document,
    options: options
  )
  let secondTerminalOutput = SupportReportTerminalRenderer.render(
    document,
    options: options
  )
  let firstIssueDraft = SupportReportGitHubRenderer.render(document)
  let secondIssueDraft = SupportReportGitHubRenderer.render(document)

  check(
    firstTerminalOutput == secondTerminalOutput,
    "the terminal adapter is deterministic for the same document"
  )
  check(
    firstIssueDraft.title == secondIssueDraft.title
      && firstIssueDraft.report == secondIssueDraft.report,
    "the GitHub adapter is deterministic for the same document"
  )
  check(
    document.summary.verified == 4
      && document.summary.inconclusive == 0
      && document.summary.errors == 0,
    "the document classifies verdicts before either renderer runs"
  )
  check(
    firstTerminalOutput.split(separator: "\n").allSatisfy { $0.count <= 60 },
    "the terminal adapter wraps its rows to the requested width"
  )
  check(
    !firstTerminalOutput.contains("`")
      && firstIssueDraft.report.contains("`listening-mode set off`"),
    "each adapter applies only its own output syntax"
  )
  check(
    firstIssueDraft.report.contains("#### Device")
      && firstIssueDraft.report.contains("#### Capabilities")
      && firstIssueDraft.report.contains(
        "#### Write tests\n\n- Status: run with consent"
      ),
    "the GitHub adapter mirrors the CLI sections with Markdown formatting"
  )

  let coloredTerminalOutput = SupportReportTerminalRenderer.render(
    document,
    options: SupportReportTerminalRenderOptions(
      colorEnabled: true,
      width: 60
    )
  )
  check(
    !firstTerminalOutput.contains("\u{001B}[")
      && coloredTerminalOutput.contains("\u{001B}["),
    "terminal color is an explicit rendering option"
  )
  check(
    SupportReportGitHubRenderer.render(document).report == firstIssueDraft.report,
    "terminal rendering options cannot affect the GitHub adapter"
  )
}

func testSupportReportUnavailableValuesAndIdentification() {
  let unavailable = FakeCompatibleAudioDevice(
    name: "",
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
  let report = passiveSupportReport(device: unavailable)
  let cliOutput = report?.terminalOutput ?? ""
  check(report != nil, "an identifiable Beats device produces an exploratory report")
  check(cliOutput.contains("Beats (exploratory)"), "Beats report is marked exploratory")
  check(
    cliOutput.contains("Model                    Not recognized by this CLI version"),
    "an unmapped identifier keeps the model explicit"
  )
  check(
    report?.githubIssueDraft.report.contains(
      "- Model: not recognized by this CLI version"
    ) == true,
    "each renderer words the unresolved model in its own register"
  )
  check(
    cliOutput.contains("Identifier               BeatsTest1,1"),
    "a marketing-style identifier carries no Bluetooth product ID"
  )
  check(
    cliOutput.contains("Listening modes          Unavailable / not reported"),
    "missing advertised modes are explicit"
  )
  check(
    cliOutput.contains("Mode query               Unavailable / not reported"),
    "an unanswered mode query is explicit"
  )
  check(
    cliOutput.contains("Mode setter              Not exposed"),
    "a missing mode setter is explicit"
  )
  check(
    cliOutput.contains("Conversation Awareness   Unavailable / not reported"),
    "missing capability is explicit"
  )
  check(
    cliOutput.contains("CA query                 Unavailable / not reported"),
    "an unanswered Conversation Awareness query is explicit"
  )
  check(
    cliOutput.contains("CA setter                Not exposed"),
    "a missing Conversation Awareness setter is explicit"
  )

  let unidentified = FakeCompatibleAudioDevice(
    name: "",
    reportMetadata: .fixture(
      family: nil,
      modelIdentifier: nil,
      listeningModeQueryAnswered: false
    )
  )
  check(
    SupportReportSnapshot.capture(device: unidentified) == nil,
    "unidentifiable hardware does not produce an issue report"
  )

  let invocation = try! parseInvocation(["support-report"])
  let outcome = CommandExecution.execute(invocation) { _, _ in unidentified }
  check(outcome.exitCode == 1, "a connected but unidentifiable device exits one")
  check(
    outcome.supportReportOutput.contains("could not be identified"),
    "a connected but unidentifiable device explains the metadata failure"
  )
  check(
    outcome.supportReportOutput.contains("template=compatibility-report.yml"),
    "a connected but unidentifiable device gets a manual filing instruction"
  )
  check(
    !outcome.supportReportOutput.contains("Connect AirPods"),
    "a connected but unidentifiable device gets no reconnect advice"
  )
  check(outcome.supportReportIssueDraft == nil, "a connected but unidentifiable device offers no issue")
}

func testSupportReportEscapesDeviceControlledTextPerAdapter() {
  let hostile = FakeCompatibleAudioDevice(
    name: "",
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
    name: "",
    reportMetadata: .fixture(
      modelIdentifier: "airpods` [CLICK](http://evil.example) `x"
    )
  )
  check(
    SupportReportSnapshot.capture(device: unnormalized) == nil,
    "capture itself rejects metadata that escapes the allowlist"
  )

  let hostileModes = FakeCompatibleAudioDevice(
    name: "",
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

func testSupportReportUnrecognizedListeningModes() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency],
    listeningMode: nil,
    reportMetadata: .fixture(
      unrecognizedListeningModes: ["AVOutputDeviceBluetoothListeningModeHearingAid"]
    )
  )
  let report = passiveSupportReport(device: device)
  let cliOutput = report?.terminalOutput ?? ""
  check(
    cliOutput.contains(
      "Other modes              AVOutputDeviceBluetoothListeningModeHearingAid"
    ),
    "an unrecognized advertised mode is readable in terminal output"
  )
  check(
    cliOutput.contains("Mode query               Available · unrecognized mode"),
    "an answered but unmapped mode query is distinguished from silence"
  )
  check(
    report?.githubIssueDraft.report.contains(
      "Other advertised listening modes: `AVOutputDeviceBluetoothListeningModeHearingAid`"
    ) == true,
    "the GitHub adapter fences an unrecognized advertised mode"
  )

  let noisy = FakeCompatibleAudioDevice(
    name: "",
    reportMetadata: .fixture(unrecognizedListeningModes: (1...8).map { "Mode\($0)" })
  )
  let noisyOutput = passiveSupportReport(device: noisy)?.terminalOutput ?? ""
  check(
    noisyOutput.contains("Mode6, and 2 more"),
    "overlong unrecognized-mode lists are capped with an explicit count"
  )
  check(
    !noisyOutput.contains("Mode7"),
    "capped unrecognized modes are not listed individually"
  )

  let exact = FakeCompatibleAudioDevice(
    name: "",
    reportMetadata: .fixture(unrecognizedListeningModes: (1...6).map { "Mode\($0)" })
  )
  let exactOutput = passiveSupportReport(device: exact)?.terminalOutput ?? ""
  check(
    exactOutput.contains("Mode1, Mode2, Mode3, Mode4, Mode5, Mode6"),
    "exactly six unrecognized modes are all listed"
  )
  check(
    !exactOutput.contains("more"),
    "exactly six unrecognized modes carry no overflow suffix"
  )
}

func testSupportReportUnknownAppleProduct() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    reportMetadata: .fixture(
      family: .unknownApple,
      modelIdentifier: "BTHeadphones76,60000"
    )
  )
  let report = passiveSupportReport(
    device: device,
    operatingSystemVersion: OperatingSystemVersion(
      majorVersion: 26,
      minorVersion: 1,
      patchVersion: 0
    )
  )
  let cliOutput = report?.terminalOutput ?? ""
  check(
    cliOutput.contains("Family                   Apple or Beats (unidentified, exploratory)"),
    "an unlisted Apple product ID reports the exploratory family"
  )
  check(
    cliOutput.contains("Model                    Not recognized by this CLI version"),
    "an unlisted Apple product ID has no model name"
  )
  check(
    cliOutput.contains(
      "Identifier               BTHeadphones76,60000 · product 0xEA60"
    ),
    "an unlisted Apple product ID still shows its decoded product ID"
  )
  check(
    report?.githubIssueDraft.title
      == "[Compatibility] Apple or Beats (unidentified, exploratory) on macOS 26.1.0",
    "an unresolved model falls back to the family in the issue title"
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
  check(
    query["template"] == SupportReportIssue.templateName,
    "issue URL selects the dedicated YAML form"
  )
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
    fallbackQuery?.first(where: { $0.name == "template" })?.value
      == SupportReportIssue.templateName,
    "fallback still selects the compatibility template"
  )
  check(
    fallbackQuery?.first(where: { $0.name == "title" })?.value == draft.title,
    "fallback retains the concise dynamic title"
  )
  check(
    fallbackQuery?.first(where: { $0.name == SupportReportIssue.reportFieldID }) == nil,
    "fallback omits only the overlong report field"
  )
}

func testSupportReportIssueURLEncodesPlusSigns() {
  let draft = SupportReportIssueDraft(
    title: "[Compatibility] Beats Studio Buds + on macOS 26.1.0",
    report: "- Model: Beats Studio Buds +"
  )
  let selected = SupportReportIssue.safeURL(for: draft)
  check(selected.prefilled, "a draft containing plus signs still prefills")
  let encodedQuery = URLComponents(
    url: selected.url,
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
    formDecodedReport == draft.report,
    "GitHub's form decoding restores the reviewed report exactly"
  )
}

func testSupportReportRequiresConfirmationBeforeOpening() {
  let device = FakeCompatibleAudioDevice(
    name: "",
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
    payload: ["result": "ok"],
    supportReport: document
  )
  var openCount = 0
  var output = [String]()
  var errors = [String]()

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
    writeError: { errors.append($0) }
  )
  check(openCount == 0, "declining confirmation never opens a browser")
  check(output == [localReport], "interaction prints the local report for review first")
  check(errors.joined().contains("[y/N]"), "interaction explicitly asks before opening")

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
    exitCode: 1,
    payload: ["result": "error"]
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
    device: FakeCompatibleAudioDevice(name: "", reportMetadata: .fixture())
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
    payload: ["result": "ok"],
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
  testSupportReportDocumentFeedsPureOutputAdapters()
  testSupportReportUnavailableValuesAndIdentification()
  testSupportReportUnrecognizedListeningModes()
  testSupportReportUnknownAppleProduct()
  testSupportReportEscapesDeviceControlledTextPerAdapter()
  testSupportReportMetadataNormalization()
  testSupportReportIssueURL()
  testSupportReportIssueURLEncodesPlusSigns()
  testSupportReportRequiresConfirmationBeforeOpening()
  testSupportReportPrintsPasteReadyFormFallback()
}
