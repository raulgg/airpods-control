import Darwin
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
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
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
    outcome.issueDraft?.body.contains("Created locally by") == false,
    "the issue body omits the local-only footer"
  )
  check(
    outcome.issueDraft?.body.hasSuffix(
      """
      ### Notes (optional)

      Add any other compatibility details that are safe to publish.
      """
    ) == true,
    "the prefilled issue retains the editable notes section from the issue template"
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
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: false
    )
  )
  unavailable.exposesListeningModeSetter = false
  unavailable.exposesConversationAwarenessSetter = false
  let report = SupportReport.make(device: unavailable)
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
    reportMetadata: SupportReportDeviceMetadata(
      family: nil,
      modelIdentifier: nil,
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: false
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
      unrecognizedListeningModes: ["www.evil.example/mode"],
      listeningModeQueryAnswered: true
    )
  )
  let markdown = SupportReport.make(device: hostile)?.markdown ?? ""
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
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "airpods` [CLICK](http://evil.example) `x",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
    )
  )
  check(
    SupportReport.make(device: unnormalized) == nil,
    "make itself rejects metadata that escapes the allowlist"
  )

  let hostileModes = FakeCompatibleAudioDevice(
    name: "",
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: ["mode` [CLICK](http://evil.example) `x"],
      listeningModeQueryAnswered: true
    )
  )
  let hostileModesMarkdown = SupportReport.make(device: hostileModes)?.markdown ?? ""
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
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: ["AVOutputDeviceBluetoothListeningModeHearingAid"],
      listeningModeQueryAnswered: true
    )
  )
  let markdown = SupportReport.make(device: device)?.markdown ?? ""
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
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: (1...8).map { "Mode\($0)" },
      listeningModeQueryAnswered: true
    )
  )
  let noisyMarkdown = SupportReport.make(device: noisy)?.markdown ?? ""
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
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: (1...6).map { "Mode\($0)" },
      listeningModeQueryAnswered: true
    )
  )
  let exactMarkdown = SupportReport.make(device: exact)?.markdown ?? ""
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
    reportMetadata: SupportReportDeviceMetadata(
      family: .unknownApple,
      modelIdentifier: "BTHeadphones76,60000",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
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
    "model metadata rejects invisible combining-mark runs of any length"
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
    body: "### Compatibility report\n\n- Model: Beats Studio Buds +"
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

  let pro3 = SupportReport.product(for: "BTHeadphones76,8231")
  check(pro3?.modelName == "AirPods Pro 3", "product ID 0x2027 resolves to AirPods Pro 3")
  check(pro3?.bluetoothProductID == 0x2027, "the decimal product field decodes to hex")

  let fitPro = SupportReport.product(for: "BTHeadphones76,8210")
  check(
    fitPro?.modelName == "Beats Fit Pro",
    "product ID 0x2012 resolves to Beats Fit Pro"
  )

  let unknown = SupportReport.product(for: "BTHeadphones76,60000")
  check(unknown?.family == .unknownApple, "an unlisted Apple product ID stays exploratory")
  check(unknown?.modelName == nil, "an unlisted Apple product ID has no model name")
  check(
    unknown?.bluetoothProductID == 60000,
    "an unlisted Apple product ID is still decoded for the report"
  )

  let marketing = SupportReport.product(for: "AirPodsTest1,1")
  check(
    marketing?.modelName == nil && marketing?.bluetoothProductID == nil,
    "a marketing-style identifier resolves a family without inventing a product"
  )

  check(SupportReport.hexProductID(0x2F) == "0x002F", "hex product IDs are zero-padded")
  check(SupportReport.hexProductID(60000) == "0xEA60", "hex product IDs use uppercase hex")

  check(
    SupportReport.family(for: "BTHeadphones76,4294975527") == nil,
    "an oversized product field is rejected instead of truncated to 32 bits"
  )
  check(
    SupportReport.product(for: "BTHeadphones76,65536") == nil,
    "product fields above 0xFFFF are rejected"
  )
  check(
    SupportReport.product(for: "BTHeadphones76,65535")?.family == .unknownApple,
    "the 16-bit boundary product ID is still decoded"
  )
}

func testSupportReportWriteTestConsent() {
  let device = FakeCompatibleAudioDevice(name: "")
  var errors = [String]()

  let declined = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: device),
    inputIsInteractive: true,
    readResponse: { "n" },
    writeError: { errors.append($0) }
  )
  check(!declined, "answering n declines the write tests")
  let prompt = errors.joined()
  check(prompt.contains("Run the write tests? [y/N]"), "consent is an explicit question")
  check(prompt.contains("may be disruptive"), "consent warns about disruption")
  check(
    prompt.contains("After you confirm, the command will run only the checks listed above."),
    "consent makes the fixed scope clear"
  )
  check(
    prompt.contains("best-effort attempt to restore"),
    "consent accurately describes restoration as best effort"
  )
  check(
    prompt.contains(
      "switch through advertised listening modes recognized by this CLI: "
        + "off, adaptive, noise-cancellation"
    ),
    "consent lists the exact exploratory modes from the captured plan"
  )
  check(
    prompt.contains(
      "restore the captured initial listening mode (transparency) if needed"
    ),
    "consent identifies the separate restoration target"
  )
  check(
    prompt.contains(
      "toggle Conversation Awareness away from the captured initial state and back"
    ),
    "consent lists the Conversation Awareness toggle"
  )
  check(prompt.contains("read-only"), "declining explains the fallback report")

  let accepted = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: device),
    inputIsInteractive: true,
    readResponse: { "YES" },
    writeError: { _ in }
  )
  check(accepted, "an explicit yes consents")

  errors = []
  let noninteractive = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: device),
    inputIsInteractive: false,
    readResponse: {
      check(false, "noninteractive consent never reads input")
      return "y"
    },
    writeError: { errors.append($0) }
  )
  check(!noninteractive, "noninteractive input cannot consent")
  check(
    errors.joined().contains("--with-write-tests"),
    "noninteractive use points at the consent flag"
  )

  let nothingToTest = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    conversationAwarenessSupported: false
  )
  errors = []
  let skipped = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: nothingToTest),
    inputIsInteractive: true,
    readResponse: {
      check(false, "no consent question without testable capabilities")
      return "y"
    },
    writeError: { errors.append($0) }
  )
  check(!skipped, "nothing to test means no consent")
  check(errors.isEmpty, "nothing to test asks nothing")

  let unreadableCA = FakeCompatibleAudioDevice(
    name: "",
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: nil
  )
  errors = []
  _ = SupportReportInteraction.requestWriteTestConsent(
    plan: SupportReportWriteTestPlan.make(device: unreadableCA),
    inputIsInteractive: true,
    readResponse: { "n" },
    writeError: { errors.append($0) }
  )
  let unreadableCAPrompt = errors.joined()
  check(
    unreadableCAPrompt.contains(
      "switch through advertised listening modes recognized by this CLI"
    ),
    "readable modes are still promised"
  )
  check(
    !unreadableCAPrompt.contains(
      "toggle Conversation Awareness away from the captured initial state and back"
    ),
    "a Conversation Awareness test that would be skipped is not promised"
  )
}

func testSupportReportWriteTestsCommandFlow() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
    )
  )

  let consented = try! parseInvocation(["support-report", "--with-write-tests"])
  var consentRequests = 0
  let outcome = CommandExecution.execute(
    consented,
    resolveDevice: { _, _ in device },
    requestWriteTestConsent: { _ in
      consentRequests += 1
      return false
    }
  )
  check(consentRequests == 0, "--with-write-tests never asks again")
  check(outcome.exitCode == 0, "a restored write-test run succeeds")
  check(
    outcome.plain.contains("### Write tests (run with consent)"),
    "the consented report carries the write-test section"
  )
  check(
    outcome.plain.contains("- `listening-mode set off`: verified"),
    "each mode write gets a verdict line"
  )
  check(
    outcome.plain.contains("- `conversation-awareness set`: verified round trip"),
    "the Conversation Awareness round trip gets a verdict line"
  )
  check(
    outcome.plain.contains("\n\nInitial state restored: yes"),
    "a clean run reports restoration"
  )
  check(
    !outcome.plain.contains("- Initial state restored:"),
    "restoration status is not part of the write-result list"
  )
  check(
    outcome.plain.contains("Listening-mode setter: exposed (see write tests)"),
    "the setter line points at the write-test section"
  )
  check(
    !outcome.plain.contains("Write tests: not run"),
    "a consented report has no not-run marker"
  )
  let localOnlyFooter =
    "\n\nCreated locally by `airpods-control support-report`. Check it before submitting."
  let completeReport = outcome.plain.replacingOccurrences(of: localOnlyFooter, with: "")
  let issueReport = completeReport.replacingOccurrences(
    of: "\n\nInitial state restored: yes",
    with: ""
  )
  check(
    outcome.issueDraft?.body.hasPrefix(issueReport + "\n\n### Notes (optional)") == true,
    "the prefilled issue contains the write results without restoration status"
  )
  check(
    outcome.issueDraft.map { SupportReport.safeIssueURL(for: $0).prefilled } == true,
    "a four-mode write report fits in the prefilled issue URL"
  )
  check(
    outcome.issueDraft?.body.contains("Initial state restored:") == false,
    "the issue body omits the restoration status"
  )
  check(
    outcome.issueDraft?.body.contains(
      "- Listening-mode write tests: run; per-mode verdicts omitted for state privacy"
    ) == false,
    "the issue body does not replace detailed write results with a summary"
  )
  check(
    outcome.issueDraft?.body.contains(
      "- `listening-mode set noise-cancellation`: verified"
    ) == true,
    "the issue body includes the final mode-write verdict without a restoration label"
  )
  check(
    outcome.issueDraft?.body.contains("- `listening-mode set off`: verified") == true,
    "the issue body includes each named mode-result row"
  )
  check(
    outcome.plain.contains(
      "- `listening-mode set noise-cancellation`: verified"
    ),
    "the terminal includes the final mode-write verdict without a restoration label"
  )
  check(
    !outcome.plain.contains("(restoration)")
      && outcome.issueDraft?.body.contains("(restoration)") == false,
    "neither report uses a restoration label"
  )
  check(
    outcome.issueDraft?.body.contains("Created locally by") == false,
    "the issue body omits the local-only footer"
  )
  check(
    device.currentListeningMode() == .noiseCancellation,
    "the fake device ends restored"
  )

  let skipped = try! parseInvocation(["support-report", "--no-write-tests"])
  let skippedOutcome = CommandExecution.execute(
    skipped,
    resolveDevice: { _, _ in device },
    requestWriteTestConsent: { _ in
      check(false, "--no-write-tests never asks")
      return true
    }
  )
  check(
    skippedOutcome.plain.contains("- Write tests: not run"),
    "a passive report says the write tests did not run"
  )
  check(
    skippedOutcome.plain.contains("exposed, not tested by this report"),
    "a passive report keeps the untested setter wording"
  )
  check(
    !skippedOutcome.plain.contains("### Write tests"),
    "a passive report has no write-test section"
  )

  let asked = try! parseInvocation(["support-report"])
  var askCount = 0
  let askedOutcome = CommandExecution.execute(
    asked,
    resolveDevice: { _, _ in device },
    requestWriteTestConsent: { _ in
      askCount += 1
      return true
    }
  )
  check(askCount == 1, "the default invocation asks for consent exactly once")
  check(
    askedOutcome.plain.contains("### Write tests (run with consent)"),
    "granted consent runs the write tests"
  )
}

func testSupportReportIssueBodyIncludesCompleteModeResults() {
  func issueBody(initialMode: ListeningMode) -> String {
    let device = FakeCompatibleAudioDevice(
      name: "",
      listeningModes: [.off, .transparency, .adaptive],
      listeningMode: initialMode,
      appliesListeningModeWrite: false,
      conversationAwarenessSupported: false,
      reportMetadata: SupportReportDeviceMetadata(
        family: .airPods,
        modelIdentifier: "BTHeadphones76,8231",
        unrecognizedListeningModes: [],
        listeningModeQueryAnswered: true
      )
    )
    let preflight = SupportReport.make(device: device)!
    let results = SupportReportWriteTester.run(device: device)
    return preflight.including(writeTests: results).issueDraft.body
  }

  let transparencyInitial = issueBody(initialMode: .transparency)
  let adaptiveInitial = issueBody(initialMode: .adaptive)

  check(
    transparencyInitial != adaptiveInitial,
    "the issue body preserves the state-dependent mode results shown locally"
  )
  check(
    transparencyInitial.contains("- `listening-mode set adaptive`: no-op"),
    "the issue body includes the attempted alternate mode"
  )
}

func testSupportReportIssueBodyIncludesStateDependentModeSkipReasons() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.off, .transparency, .adaptive],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )
  let preflight = SupportReport.make(device: device)!
  let results = SupportReportWriteTester.run(device: device)
  let report = preflight.including(writeTests: results)

  check(
    report.markdown.contains("initial mode is not advertised"),
    "the local report keeps the actionable mode skip reason"
  )
  check(
    report.issueDraft.body.contains("initial mode is not advertised"),
    "the issue draft includes the actionable mode skip reason"
  )
  check(
    !report.issueDraft.body.contains(
      "- Listening-mode write tests: skipped; reason available in local output"
    ),
    "the issue draft does not replace the skip reason with a generic marker"
  )
}

func testSupportReportRunsOnlyTheConsentedWritePlan() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: nil,
    conversationAwarenessEnabled: nil,
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
    )
  )
  let invocation = try! parseInvocation(["support-report"])

  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    requestWriteTestConsent: { _ in
      device.listeningModes.append(.noiseCancellation)
      device.conversationAwarenessSupported = true
      device.conversationAwarenessEnabled = false
      return true
    }
  )

  check(
    device.listeningModeSetCount == 2,
    "execution writes only the mode target and restoration disclosed before consent"
  )
  check(
    device.conversationAwarenessSetCount == 0,
    "a capability appearing after consent is not written"
  )
  check(
    !outcome.plain.contains("listening-mode set noise-cancellation"),
    "the report contains no undisclosed mode write"
  )
  check(
    outcome.plain.contains(
      "`conversation-awareness set`: skipped (capability unavailable)"
    ),
    "the report preserves the consented capability snapshot"
  )
}

func testSupportReportSkipsCapabilitiesRemovedDuringConsent() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
    )
  )
  let invocation = try! parseInvocation(["support-report"])

  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    requestWriteTestConsent: { _ in
      device.listeningModes = [.transparency]
      device.exposesConversationAwarenessSetter = false
      return true
    }
  )

  check(
    device.listeningModeSetCount == 0,
    "a planned mode that is no longer advertised is not written"
  )
  check(
    device.conversationAwarenessSetCount == 0,
    "a setter that disappears during consent is not invoked"
  )
  check(
    outcome.plain.contains(
      "`listening-mode set`: skipped "
        + "(planned listening modes are no longer advertised, nothing written)"
    ),
    "the local report explains the stale mode capability"
  )
  check(
    outcome.plain.contains(
      "`conversation-awareness set`: skipped "
        + "(capability or setter no longer exposed, nothing written)"
    ),
    "the local report explains the stale Conversation Awareness capability"
  )
}

func testSupportReportSkipsASetterOrSupportRemovedDuringConsent() {
  let invocation = try! parseInvocation(["support-report"])
  let modeDevice = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: false
  )
  let modeOutcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in modeDevice },
    runSupportReportWriteTests: { plan, device in
      SupportReportWriteTester.run(plan: plan, device: device)
    },
    requestWriteTestConsent: { _ in
      modeDevice.exposesListeningModeSetter = false
      return true
    }
  )

  check(
    modeDevice.listeningModeSetCount == 0,
    "a listening-mode setter removed during consent is not invoked"
  )
  check(
    modeOutcome.plain.contains(
      "`listening-mode set`: skipped "
        + "(setter no longer exposed, nothing written)"
    ),
    "the local report explains the stale listening-mode setter"
  )

  let awarenessDevice = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    listeningMode: nil,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false
  )
  let awarenessOutcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in awarenessDevice },
    runSupportReportWriteTests: { plan, device in
      SupportReportWriteTester.run(plan: plan, device: device)
    },
    requestWriteTestConsent: { _ in
      awarenessDevice.conversationAwarenessSupported = false
      return true
    }
  )

  check(
    awarenessDevice.conversationAwarenessSetCount == 0,
    "Conversation Awareness support removed during consent prevents a write"
  )
  check(
    awarenessOutcome.plain.contains(
      "`conversation-awareness set`: skipped "
        + "(capability or setter no longer exposed, nothing written)"
    ),
    "the local report explains stale Conversation Awareness support"
  )
}

func testSupportReportSkipsAPlanWhoseInitialModeChangedDuringConsent() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: false,
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
    )
  )
  let invocation = try! parseInvocation(["support-report"])

  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    requestWriteTestConsent: { _ in
      device.listeningMode = .adaptive
      return true
    }
  )

  check(
    device.listeningModeSetCount == 0,
    "a mode changed while consent is pending is not overwritten"
  )
  check(
    device.currentListeningMode() == .adaptive,
    "the user's newer listening mode remains active"
  )
  check(
    outcome.plain.contains(
      "`listening-mode set`: skipped "
        + "(initial state changed after planning, nothing written)"
    ),
    "the report explains why the stale mode plan was skipped"
  )
}

func testSupportReportSkipsAPlanWhoseAwarenessChangedDuringConsent() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [],
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: false
    )
  )
  let invocation = try! parseInvocation(["support-report"])

  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    requestWriteTestConsent: { _ in
      device.conversationAwarenessEnabled = true
      return true
    }
  )

  check(
    device.conversationAwarenessSetCount == 0,
    "Conversation Awareness changed while consent is pending is not overwritten"
  )
  check(
    device.conversationAwarenessState() == true,
    "the user's newer Conversation Awareness state remains active"
  )
  check(
    outcome.plain.contains(
      "`conversation-awareness set`: skipped "
        + "(initial state changed after planning, nothing written)"
    ),
    "the report explains why the stale Conversation Awareness plan was skipped"
  )
}

func testSupportReportPreservesThePreflightSnapshotDuringWrites() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive],
    listeningMode: .transparency,
    conversationAwarenessSupported: false,
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
    )
  )
  device.listeningModeEffect = {
    device.reportMetadata = SupportReportDeviceMetadata(
      family: nil,
      modelIdentifier: nil,
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: false
    )
  }

  let invocation = try! parseInvocation(["support-report", "--with-write-tests"])
  let outcome = CommandExecution.execute(invocation) { _, _ in device }

  check(
    outcome.exitCode == 0,
    "losing model metadata after a restored run does not replace the report outcome"
  )
  check(
    outcome.plain.contains("Model: AirPods Pro 3"),
    "the report retains the compatibility snapshot captured before writes"
  )
  check(
    outcome.plain.contains("Initial state restored: yes"),
    "the report still states the final restoration result"
  )
  check(
    outcome.issueDraft != nil,
    "a transient post-write metadata loss does not discard the reviewed issue draft"
  )
}

func testSupportReportWriteTestsRestoreFailure() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
    )
  )
  device.listeningModeWriteOverride = { _ in .transparency }

  let invocation = try! parseInvocation(["support-report", "--with-write-tests"])
  let outcome = CommandExecution.execute(invocation) { _, _ in device }
  check(outcome.exitCode == 3, "a failed restoration exits no-op")
  check(
    outcome.plain.contains(
      "Initial state restored: no, listening mode is now transparency. "
        + "Restore manually in System Settings."
    ),
    "a failed restoration names the final state and the manual fix"
  )
  check(
    outcome.issueDraft?.body.contains("Initial state restored:") == false,
    "a failed restoration and manual fix remain terminal-only"
  )
  check(outcome.issueDraft != nil, "a failed restoration still offers the issue draft")
}

func testSupportReportInterruptedWriteTestsUseSignalExit() {
  let device = FakeCompatibleAudioDevice(
    name: "",
    listeningModes: [.transparency, .adaptive, .noiseCancellation],
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: false,
    reportMetadata: SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "BTHeadphones76,8231",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
    )
  )
  var caughtSignal: Int32?
  device.listeningModeEffect = {
    if device.listeningModeSetCount == 1 {
      caughtSignal = SIGTERM
    }
  }

  let invocation = try! parseInvocation(["support-report", "--with-write-tests"])
  let outcome = CommandExecution.execute(
    invocation,
    resolveDevice: { _, _ in device },
    runSupportReportWriteTests: { plan, resolvedDevice in
      SupportReportWriteTester.run(
        plan: plan,
        device: resolvedDevice,
        interruptionSignal: { caughtSignal }
      )
    }
  )

  check(outcome.exitCode == 143, "SIGTERM produces the conventional shell exit status")
  check(
    outcome.payload["result"] as? String == "interrupted",
    "the outcome distinguishes interruption from a completed report"
  )
  check(
    outcome.payload["signal"] as? Int32 == SIGTERM,
    "the outcome records the caught signal"
  )
  check(outcome.issueDraft == nil, "an interrupted run never opens an issue prompt")
  check(
    outcome.plain.contains("Write tests interrupted by SIGTERM"),
    "the interrupted local report explains why testing stopped"
  )
  check(
    device.currentListeningMode() == .noiseCancellation,
    "the command restores the initial mode before returning the signal exit"
  )
  check(
    device.conversationAwarenessSetCount == 0,
    "the command starts no later capability test after interruption"
  )
}

func runSupportReportTests() {
  testSupportReportContentsAndPrivacy()
  testSupportReportUnavailableValuesAndIdentification()
  testSupportReportUnrecognizedListeningModes()
  testSupportReportUnknownAppleProduct()
  testSupportReportFencesDeviceControlledText()
  testSupportReportMetadataNormalization()
  testSupportReportFamilyFromModelIdentifier()
  testSupportReportWriteTestConsent()
  testSupportReportWriteTestsCommandFlow()
  testSupportReportIssueBodyIncludesCompleteModeResults()
  testSupportReportIssueBodyIncludesStateDependentModeSkipReasons()
  testSupportReportRunsOnlyTheConsentedWritePlan()
  testSupportReportSkipsCapabilitiesRemovedDuringConsent()
  testSupportReportSkipsASetterOrSupportRemovedDuringConsent()
  testSupportReportSkipsAPlanWhoseInitialModeChangedDuringConsent()
  testSupportReportSkipsAPlanWhoseAwarenessChangedDuringConsent()
  testSupportReportPreservesThePreflightSnapshotDuringWrites()
  testSupportReportWriteTestsRestoreFailure()
  testSupportReportInterruptedWriteTestsUseSignalExit()
  testSupportReportIssueURL()
  testSupportReportIssueURLEncodesPlusSigns()
  testSupportReportRequiresConfirmationBeforeOpening()
}
