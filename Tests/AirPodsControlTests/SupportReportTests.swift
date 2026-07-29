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
  let markdown = report?.markdown ?? ""
  check(markdown.contains("Model: AirPods Pro 3"), "report resolves the model name")
  check(
    markdown.contains(
      "Model identifier: `BTHeadphones76,8231` (Bluetooth product ID 0x2027)"
    ),
    "report has the model ID with its decoded Bluetooth product ID"
  )
  check(
    markdown.contains(
      "Advertised known listening modes: off, transparency, noise-cancellation"
    ),
    "report has canonical advertised capabilities"
  )
  check(
    markdown.contains("Other advertised listening modes: none"),
    "report is explicit when every advertised mode is recognized"
  )
  check(
    markdown.contains("Listening-mode query: answers with a recognized mode"),
    "report says the mode query answers without exposing the mode"
  )
  check(
    markdown.contains("Listening-mode setter: exposed, not tested by this report"),
    "report says the mode setter is exposed without writing"
  )
  check(
    markdown.contains("Conversation Awareness capability: supported"),
    "report has advertised Conversation Awareness support"
  )
  check(
    markdown.contains("Conversation Awareness query: answers"),
    "report says the Conversation Awareness query answers without exposing the state"
  )
  check(
    markdown.contains(
      "Conversation Awareness setter: exposed, not tested by this report"
    ),
    "report says the Conversation Awareness setter is exposed without writing"
  )
  check(markdown.contains("macOS: 26.1.0"), "report has normalized macOS version")
  check(markdown.contains("airpods-control: \(VERSION)"), "report has CLI version")
  check(!markdown.contains("Firmware:"), "report omits firmware")
  check(!markdown.contains("Connection state:"), "report omits connection state")
  check(
    !markdown.contains("Current listening mode:"),
    "report omits the current listening-mode value"
  )
  check(
    !markdown.contains("Conversation Awareness state:"),
    "report omits the Conversation Awareness state value"
  )
  for excluded in ["serial", "MAC address", "account", "device name", "raw dump"] {
    check(
      !markdown.lowercased().contains(excluded.lowercased()),
      "report omits excluded field \(excluded)"
    )
  }
  check(device.listeningModeSetCount == 0, "report does not write listening mode")
  check(
    device.conversationAwarenessSetCount == 0,
    "report does not write Conversation Awareness"
  )
  check(
    report?.issueDraft.title == "[Compatibility] AirPods Pro 3 on macOS 26.1.0",
    "the issue title names the resolved model"
  )

  let invocation = try! parseInvocation(["support-report"])
  let outcome = CommandExecution.execute(invocation) { _, _ in device }
  check(outcome.exitCode == 0, "supported-device command path succeeds")
  check(outcome.issueDraft != nil, "supported-device command path creates an issue draft")
  check(
    outcome.plain.contains(
      "Created locally by `airpods-control support-report`. Check it before submitting."
    ),
    "the local report carries its local-only footer"
  )
  check(
    outcome.issueDraft?.report.hasPrefix("- Device family: AirPods") == true,
    "the issue field starts with the generated compatibility details"
  )
  check(
    outcome.issueDraft?.report.contains("### Compatibility report") == false,
    "the issue field lets the form supply its compatibility heading"
  )
  check(
    outcome.issueDraft?.report.contains("Created locally by") == false
      && outcome.issueDraft?.report.contains("Notes (optional)") == false,
    "the issue field omits local-only and user-authored form sections"
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
  let markdown = report?.markdown ?? ""
  check(report != nil, "an identifiable Beats device produces an exploratory report")
  check(markdown.contains("Beats (exploratory)"), "Beats report is marked exploratory")
  check(
    markdown.contains("Model: not recognized by this CLI version"),
    "an unmapped identifier keeps the model explicit"
  )
  check(
    markdown.contains("Model identifier: `BeatsTest1,1`\n"),
    "a marketing-style identifier carries no Bluetooth product ID"
  )
  check(
    markdown.contains("Advertised known listening modes: unavailable/not reported"),
    "missing advertised modes are explicit"
  )
  check(
    markdown.contains("Listening-mode query: unavailable/not reported"),
    "an unanswered mode query is explicit"
  )
  check(
    markdown.contains("Listening-mode setter: not exposed"),
    "a missing mode setter is explicit"
  )
  check(
    markdown.contains("Conversation Awareness capability: unavailable/not reported"),
    "missing capability is explicit"
  )
  check(
    markdown.contains("Conversation Awareness query: unavailable/not reported"),
    "an unanswered Conversation Awareness query is explicit"
  )
  check(
    markdown.contains("Conversation Awareness setter: not exposed"),
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
    outcome.plain.contains("could not be identified"),
    "a connected but unidentifiable device explains the metadata failure"
  )
  check(
    outcome.plain.contains("template=compatibility-report.yml"),
    "a connected but unidentifiable device gets a manual filing instruction"
  )
  check(
    !outcome.plain.contains("Connect AirPods"),
    "a connected but unidentifiable device gets no reconnect advice"
  )
  check(outcome.issueDraft == nil, "a connected but unidentifiable device offers no issue")
}

func testSupportReportFencesDeviceControlledText() {
  let hostile = FakeCompatibleAudioDevice(
    name: "",
    reportMetadata: .fixture(
      modelIdentifier: "airpods www.evil.example/x",
      unrecognizedListeningModes: ["www.evil.example/mode"]
    )
  )
  let markdown = passiveSupportReport(device: hostile)?.markdown ?? ""
  check(
    markdown.contains("Model identifier: `airpods www.evil.example/x`"),
    "device-controlled model text is fenced against markdown autolinks"
  )
  check(
    markdown.contains("Other advertised listening modes: `www.evil.example/mode`"),
    "device-controlled mode text is fenced against markdown autolinks"
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
  let hostileModesMarkdown = passiveSupportReport(device: hostileModes)?.markdown ?? ""
  check(
    hostileModesMarkdown.contains("Other advertised listening modes: none"),
    "a mode name that escapes the allowlist is dropped, not printed"
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
  let markdown = passiveSupportReport(device: device)?.markdown ?? ""
  check(
    markdown.contains(
      "Other advertised listening modes: `AVOutputDeviceBluetoothListeningModeHearingAid`"
    ),
    "an unrecognized advertised mode is reported verbatim and fenced"
  )
  check(
    markdown.contains("Listening-mode query: answers with an unrecognized mode"),
    "an answered but unmapped mode query is distinguished from silence"
  )

  let noisy = FakeCompatibleAudioDevice(
    name: "",
    reportMetadata: .fixture(unrecognizedListeningModes: (1...8).map { "Mode\($0)" })
  )
  let noisyMarkdown = passiveSupportReport(device: noisy)?.markdown ?? ""
  check(
    noisyMarkdown.contains("`Mode6`, and 2 more"),
    "overlong unrecognized-mode lists are capped with an explicit count"
  )
  check(
    !noisyMarkdown.contains("`Mode7`"),
    "capped unrecognized modes are not listed individually"
  )

  let exact = FakeCompatibleAudioDevice(
    name: "",
    reportMetadata: .fixture(unrecognizedListeningModes: (1...6).map { "Mode\($0)" })
  )
  let exactMarkdown = passiveSupportReport(device: exact)?.markdown ?? ""
  check(
    exactMarkdown.contains("`Mode1`, `Mode2`, `Mode3`, `Mode4`, `Mode5`, `Mode6`\n"),
    "exactly six unrecognized modes are all listed"
  )
  check(
    !exactMarkdown.contains("more"),
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
  let markdown = report?.markdown ?? ""
  check(
    markdown.contains("Device family: Apple or Beats (unidentified, exploratory)"),
    "an unlisted Apple product ID reports the exploratory family"
  )
  check(
    markdown.contains("Model: not recognized by this CLI version"),
    "an unlisted Apple product ID has no model name"
  )
  check(
    markdown.contains(
      "Model identifier: `BTHeadphones76,60000` (Bluetooth product ID 0xEA60)"
    ),
    "an unlisted Apple product ID still shows its decoded product ID"
  )
  check(
    report?.issueDraft.title
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
  let selected = SupportReport.safeIssueURL(for: draft)
  let components = URLComponents(url: selected.url, resolvingAgainstBaseURL: false)
  let query = Dictionary(
    uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
      item.value.map { (item.name, $0) }
    }
  )
  check(selected.prefilled, "concise report uses a prefilled issue URL")
  check(
    query["template"] == SupportReport.issueTemplateName,
    "issue URL selects the dedicated YAML form"
  )
  check(query["title"] == draft.title, "issue URL prefills the title")
  check(
    query[SupportReport.reportFieldID] == draft.report,
    "issue URL prefills the reviewed report field by its form ID"
  )
  check(query["body"] == nil, "issue URL does not bypass the form with a body parameter")

  let oversized = SupportReportIssueDraft(
    title: draft.title,
    report: String(repeating: "x", count: SupportReport.maximumPrefilledURLLength)
  )
  let fallback = SupportReport.safeIssueURL(for: oversized)
  let fallbackQuery = URLComponents(
    url: fallback.url,
    resolvingAgainstBaseURL: false
  )?.queryItems
  check(!fallback.prefilled, "overlong issue URL uses a safe local fallback")
  check(
    fallbackQuery?.first(where: { $0.name == "template" })?.value
      == SupportReport.issueTemplateName,
    "fallback still selects the compatibility template"
  )
  check(
    fallbackQuery?.first(where: { $0.name == "title" })?.value == draft.title,
    "fallback retains the concise dynamic title"
  )
  check(
    fallbackQuery?.first(where: { $0.name == SupportReport.reportFieldID }) == nil,
    "fallback omits only the overlong report field"
  )
}

func testSupportReportIssueURLEncodesPlusSigns() {
  let draft = SupportReportIssueDraft(
    title: "[Compatibility] Beats Studio Buds + on macOS 26.1.0",
    report: "- Model: Beats Studio Buds +"
  )
  let selected = SupportReport.safeIssueURL(for: draft)
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
    .first { $0.hasPrefix("\(SupportReport.reportFieldID)=") }
    .map { String($0.dropFirst("\(SupportReport.reportFieldID)=".count)) } ?? ""
  let formDecodedReport = encodedReport
    .replacingOccurrences(of: "+", with: " ")
    .removingPercentEncoding
  check(
    formDecodedReport == draft.report,
    "GitHub's form decoding restores the reviewed report exactly"
  )
}

func testSupportReportRequiresConfirmationBeforeOpening() {
  let draft = SupportReportIssueDraft(
    title: "[Compatibility] AirPods",
    report: "- Device family: AirPods"
  )
  let localReport = "### Compatibility report"
  let outcome = CommandOutcome(
    plain: localReport,
    payload: ["result": "ok"],
    issueDraft: draft
  )
  var openCount = 0
  var output = [String]()
  var errors = [String]()

  _ = SupportReportInteraction.present(
    outcome: outcome,
    inputIsInteractive: true,
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
    openedURL == SupportReport.safeIssueURL(for: draft).url,
    "affirmative confirmation opens exactly the reviewed issue URL"
  )
  check(
    openedURL?.host == SupportReport.repositoryIssuesURL.host,
    "the opened URL stays on github.com"
  )
  check(
    openedURL?.path == SupportReport.repositoryIssuesURL.path,
    "the opened URL stays on the project's new-issue path"
  )

  var noninteractiveReadCount = 0
  _ = SupportReportInteraction.present(
    outcome: outcome,
    inputIsInteractive: false,
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
  let draft = SupportReportIssueDraft(
    title: "[Compatibility] AirPods",
    report: String(repeating: "report ", count: SupportReport.maximumPrefilledURLLength)
  )
  let localReport = "### Compatibility report"
  let outcome = CommandOutcome(
    plain: localReport,
    payload: ["result": "ok"],
    issueDraft: draft
  )
  var output: [String] = []
  var errors: [String] = []

  _ = SupportReportInteraction.present(
    outcome: outcome,
    inputIsInteractive: false,
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
    output.last?.contains("Paste-ready GitHub report") == true
      && output.last?.contains(draft.report) == true,
    "fallback prints the exact GitHub form field for manual pasting"
  )
  check(
    errors.joined().contains("too long for a prefilled GitHub URL"),
    "fallback explains why the form field was not prefilled"
  )
}

func runSupportReportTests() {
  testSupportReportContentsAndPrivacy()
  testSupportReportUnavailableValuesAndIdentification()
  testSupportReportUnrecognizedListeningModes()
  testSupportReportUnknownAppleProduct()
  testSupportReportFencesDeviceControlledText()
  testSupportReportMetadataNormalization()
  testSupportReportIssueURL()
  testSupportReportIssueURLEncodesPlusSigns()
  testSupportReportRequiresConfirmationBeforeOpening()
  testSupportReportPrintsPasteReadyFormFallback()
}
