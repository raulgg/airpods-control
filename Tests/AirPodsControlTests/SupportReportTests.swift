import Foundation

func testSupportReportContentsAndPrivacy() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "AirPodsProTest2,1",
      firmwareVersion: "7A1",
      connectionState: .connected
    )
  )
  let report = SupportReport.make(
    device: device,
    operatingSystemVersion: OperatingSystemVersion(
      majorVersion: 26,
      minorVersion: 1,
      patchVersion: 0
    )
  )

  check(report != nil, "an identifiable AirPods device produces a report")
  let markdown = report?.markdown ?? ""
  check(markdown.contains("Model identifier: `AirPodsProTest2,1`"), "report has model ID")
  check(markdown.contains("Firmware: `7A1`"), "report has exposed firmware")
  check(markdown.contains("Connection state: connected"), "report has connection state")
  check(
    markdown.contains(
      "Advertised known listening modes: off, transparency, noise-cancellation"
    ),
    "report has canonical advertised capabilities"
  )
  check(
    markdown.contains("Current listening mode: noise-cancellation"),
    "report has exposed current mode"
  )
  check(
    markdown.contains("Conversation Awareness capability: supported"),
    "report has advertised Conversation Awareness support"
  )
  check(
    markdown.contains("Conversation Awareness state: off"),
    "report has exposed Conversation Awareness state"
  )
  check(markdown.contains("macOS: 26.1.0"), "report has normalized macOS version")
  check(markdown.contains("airpods-control: \(VERSION)"), "report has CLI version")
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

  let invocation = try! parseInvocation(["support-report"])
  let outcome = CommandExecution.execute(invocation) { _, _ in device }
  check(outcome.exitCode == 0, "supported-device command path succeeds")
  check(outcome.issueDraft != nil, "supported-device command path creates an issue draft")
  check(
    outcome.plain == outcome.issueDraft?.body,
    "the reviewed local report exactly matches the prefilled body"
  )
}

func testSupportReportUnavailableValuesAndIdentification() {
  let unavailable = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    listeningMode: nil,
    conversationAwarenessSupported: nil,
    conversationAwarenessEnabled: nil,
    reportMetadata: SupportReportDeviceMetadata(
      family: .beats,
      modelIdentifier: "BeatsTest1,1",
      firmwareVersion: nil,
      connectionState: .connected
    )
  )
  let report = SupportReport.make(device: unavailable)
  let markdown = report?.markdown ?? ""
  check(report != nil, "an identifiable Beats device produces an exploratory report")
  check(markdown.contains("Beats (exploratory)"), "Beats report is marked exploratory")
  check(
    markdown.contains("Firmware: unavailable/not reported"),
    "missing firmware is explicit"
  )
  check(
    markdown.contains("Advertised known listening modes: unavailable/not reported"),
    "missing advertised modes are explicit"
  )
  check(
    markdown.contains("Conversation Awareness capability: unavailable/not reported"),
    "missing capability is explicit"
  )
  check(
    markdown.contains("Conversation Awareness state: unavailable"),
    "missing state is explicit"
  )

  let unidentified = FakeCompatibleAudioDevice(
    name: "",
    reportMetadata: SupportReportDeviceMetadata(
      family: nil,
      modelIdentifier: nil,
      firmwareVersion: nil,
      connectionState: .connected
    )
  )
  check(
    SupportReport.make(device: unidentified) == nil,
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
    outcome.plain.contains("template=compatibility-report.md"),
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
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "airpods www.evil.example/x",
      firmwareVersion: "www.evil.example",
      connectionState: .connected
    )
  )
  let markdown = SupportReport.make(device: hostile)?.markdown ?? ""
  check(
    markdown.contains("Model identifier: `airpods www.evil.example/x`"),
    "device-controlled model text is fenced against markdown autolinks"
  )
  check(
    markdown.contains("Firmware: `www.evil.example`"),
    "device-controlled firmware text is fenced against markdown autolinks"
  )
}

func testSupportReportMetadataNormalization() {
  check(
    SupportReport.normalizedMetadataValue(
      "  AirPodsPro2,1   (USB-C) ",
      maximumLength: 80
    ) == "AirPodsPro2,1 (USB-C)",
    "model metadata trims and collapses whitespace"
  )
  check(
    SupportReport.normalizedMetadataValue(
      "AirPodsPro2,1\n- account: exposed",
      maximumLength: 80
    ) == nil,
    "model metadata rejects Markdown punctuation outside the allowlist"
  )
  check(
    SupportReport.normalizedMetadataValue(
      String(repeating: "A", count: 81),
      maximumLength: 80
    ) == nil,
    "model metadata rejects overlong values"
  )
  check(
    SupportReport.normalizedMetadataValue("AirPods Pro\u{0301}", maximumLength: 80) == nil,
    "model metadata rejects non-ASCII combining marks"
  )
  check(
    SupportReport.normalizedMetadataValue(
      "AirPods" + String(repeating: "\u{034F}", count: 200_000),
      maximumLength: 80
    ) == nil,
    "model metadata caps unicode scalars, not grapheme clusters"
  )
}

func testSupportReportIssueURL() {
  let draft = SupportReportIssueDraft(
    title: "[Compatibility] AirPods",
    body: "### Compatibility report\n\n- Model identifier: AirPodsTest1,1"
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
    "issue URL selects the dedicated Markdown template"
  )
  check(query["title"] == draft.title, "issue URL prefills the title")
  check(query["body"] == draft.body, "issue URL prefills the reviewed report body")

  let oversized = SupportReportIssueDraft(
    title: draft.title,
    body: String(repeating: "x", count: SupportReport.maximumPrefilledURLLength)
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
    fallbackQuery?.first(where: { $0.name == "body" }) == nil,
    "fallback omits the overlong body"
  )
}

func testSupportReportIssueURLEncodesPlusSigns() {
  let draft = SupportReportIssueDraft(
    title: "[Compatibility] Beats Studio Buds + on macOS 26.1.0",
    body: "### Compatibility report\n\n- Firmware: 6A300+1"
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

  let encodedBody = encodedQuery
    .components(separatedBy: "&")
    .first { $0.hasPrefix("body=") }
    .map { String($0.dropFirst("body=".count)) } ?? ""
  let formDecodedBody = encodedBody
    .replacingOccurrences(of: "+", with: " ")
    .removingPercentEncoding
  check(
    formDecodedBody == draft.body,
    "GitHub's form decoding restores the reviewed body exactly"
  )
}

func testSupportReportRequiresConfirmationBeforeOpening() {
  let draft = SupportReportIssueDraft(
    title: "[Compatibility] AirPods",
    body: "### Compatibility report"
  )
  let outcome = CommandOutcome(
    plain: draft.body,
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
  check(output == [draft.body], "interaction prints the report for review first")
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
  check(openCount == 1, "affirmative confirmation opens exactly one issue draft")
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

func testSupportReportFamilyFromModelIdentifier() {
  check(
    SupportReport.family(for: "BTHeadphones76,8231") == .airPods,
    "the Bluetooth model identifier of AirPods Pro 3 resolves to AirPods"
  )
  check(
    SupportReport.family(for: "btheadphones76,8231") == .airPods,
    "the Bluetooth model identifier prefix is matched case-insensitively"
  )
  check(
    SupportReport.family(for: "BTHeadphones76,8210") == .beats,
    "a known Beats product ID resolves to the exploratory Beats family"
  )
  check(
    SupportReport.family(for: "BTHeadphones76,60000") == .unknownApple,
    "an unlisted Apple product ID still produces an exploratory report"
  )
  check(
    SupportReport.family(for: "BTHeadphones123,456") == nil,
    "a non-Apple vendor ID stays unidentifiable"
  )
  check(
    SupportReport.family(for: "BTHeadphones76,8231,0") == nil,
    "a malformed Bluetooth model identifier stays unidentifiable"
  )
  check(
    SupportReport.family(for: "AirPodsTest1,1") == .airPods,
    "a marketing-style model identifier still matches by name"
  )
  check(
    SupportReport.family(for: "BeatsTest1,1") == .beats,
    "a marketing-style Beats identifier still matches by name"
  )
  check(SupportReport.family(for: nil) == nil, "missing model metadata is unidentifiable")
}

func runSupportReportTests() {
  testSupportReportContentsAndPrivacy()
  testSupportReportUnavailableValuesAndIdentification()
  testSupportReportFencesDeviceControlledText()
  testSupportReportMetadataNormalization()
  testSupportReportFamilyFromModelIdentifier()
  testSupportReportIssueURL()
  testSupportReportIssueURLEncodesPlusSigns()
  testSupportReportRequiresConfirmationBeforeOpening()
}
