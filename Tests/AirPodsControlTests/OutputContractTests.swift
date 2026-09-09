import CoreAudio
import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("CLI output contracts")
struct OutputContractTests {
  @Test("Preserves JSON escaping, key order, types, and final newline")
  func jsonSerializationContract() {
    let output = CLIOutputSerializer.json([
      "bool": .bool(true),
      "integer": .integer(7),
      "nested": .object([
        "control": .string("line\n\tesc\u{001B}"),
        "quote": .string("a\"b"),
        "slash": .string("a/b"),
      ]),
      "null": .null,
    ])

    #expect(
      output == "{\"bool\":true,\"integer\":7,\"nested\":{\"control\":\"line\\n\\tesc\\u001b\",\"quote\":\"a\\\"b\",\"slash\":\"a\\/b\"},\"null\":null}\n",
      "JSON output retains sorted compact encoding and a final newline"
    )
  }

  @Test("Serializes representative command outcomes exactly")
  func commandJSONContracts() throws {
    let success = try commandOutcome(
      ["lm", "get"],
      device: FakeCompatibleAudioDevice(
        name: "Desk AirPods",
        listeningMode: .transparency
      )
    )
    #expect(
      CLIOutputSerializer.json(success.jsonPayload)
        == "{\"device\":\"Desk AirPods\",\"listeningMode\":\"transparency\",\"result\":\"ok\"}\n",
      "successful listening-mode JSON remains byte stable"
    )

    let noOp = try commandOutcome(
      ["lm", "set", "adaptive"],
      device: FakeCompatibleAudioDevice(
        name: "No-op AirPods",
        listeningMode: .transparency,
        appliesListeningModeWrite: false
      )
    )
    #expect(
      CLIOutputSerializer.json(noOp.jsonPayload)
        == "{\"device\":\"No-op AirPods\",\"listeningMode\":\"transparency\",\"result\":\"no-op\"}\n",
      "unverified writes retain the no-op JSON envelope"
    )

    let unknown = try commandOutcome(
      ["lm", "get"],
      device: FakeCompatibleAudioDevice(
        name: "Unknown AirPods",
        listeningMode: nil
      )
    )
    #expect(
      CLIOutputSerializer.json(unknown.jsonPayload)
        == "{\"device\":\"Unknown AirPods\",\"listeningMode\":null,\"result\":\"ok\"}\n",
      "an unresolved listening mode stays JSON null"
    )

    let unsupported = try commandOutcome(
      ["lm", "set", "adaptive"],
      device: FakeCompatibleAudioDevice(
        name: "Limited AirPods",
        listeningModes: [.transparency],
        listeningMode: .transparency
      )
    )
    #expect(
      CLIOutputSerializer.json(unsupported.jsonPayload)
        == "{\"device\":\"Limited AirPods\",\"error\":\"unsupported\",\"listeningMode\":\"transparency\",\"result\":\"error\"}\n",
      "unsupported writes retain their complete error payload"
    )

    let statusDevice = FakeCompatibleAudioDevice(
      name: "Status AirPods",
      listeningMode: .transparency,
      conversationAwarenessEnabled: true,
      audioOutputSelectionStatus: .selected,
      audioInputSelectionStatus: .notSelected
    )
    statusDevice.inEarPlacementStatus = .value(
      BluetoothEarPlacement(left: .inEar, right: .inCase)
    )
    let status = StatusCommand.outcome(devices: [statusDevice])
    #expect(
      CLIOutputSerializer.json(status.jsonPayload)
        == "{\"devices\":[{\"conversationAwareness\":\"on\",\"device\":\"Status AirPods\",\"isSelectedAudioInput\":false,\"isSelectedAudioOutput\":true,\"leftEarPlacement\":\"in-ear\",\"listeningMode\":\"transparency\",\"rightEarPlacement\":\"in-case\"}],\"result\":\"ok\"}\n",
      "status JSON retains nested field order and booleans"
    )

    let cached = try cachedListeningModeListOutcome()
    #expect(
      CLIOutputSerializer.json(cached.jsonPayload)
        == "{\"allowOffAvailability\":{\"expiresAt\":\"2033-05-25T03:33:20.000Z\",\"observedAt\":\"2033-05-18T03:33:20.000Z\",\"source\":\"cached-av-observation\"},\"device\":\"Cached AirPods\",\"listeningMode\":\"noise-cancellation\",\"result\":\"ok\",\"supportedListeningModes\":[\"off\",\"transparency\",\"adaptive\",\"noise-cancellation\"]}\n",
      "cached evidence JSON retains provenance without private identifiers"
    )
  }

  @Test("Preserves representative plain output and final newlines")
  func plainOutputContracts() throws {
    let success = try commandOutcome(
      ["lm", "get"],
      device: FakeCompatibleAudioDevice(
        name: "Desk AirPods",
        listeningMode: .transparency
      )
    )
    #expect(
      CLIOutputSerializer.plain(success.plain) == "transparency\n",
      "successful listening-mode output keeps its plain token"
    )

    let noOp = try commandOutcome(
      ["lm", "set", "adaptive"],
      device: FakeCompatibleAudioDevice(
        name: "No-op AirPods",
        listeningMode: .transparency,
        appliesListeningModeWrite: false
      )
    )
    #expect(
      CLIOutputSerializer.plain(noOp.plain) == "no-op\n",
      "no-op output keeps its plain token"
    )

    let unknown = try commandOutcome(
      ["lm", "get"],
      device: FakeCompatibleAudioDevice(
        name: "Unknown AirPods",
        listeningMode: nil
      )
    )
    #expect(
      CLIOutputSerializer.plain(unknown.plain) == "unknown\n",
      "unknown output keeps its plain fallback"
    )

    let failure = try commandOutcome(
      ["lm", "set", "adaptive"],
      device: FakeCompatibleAudioDevice(
        name: "Limited AirPods",
        listeningModes: [.transparency],
        listeningMode: .transparency
      )
    )
    #expect(
      CLIOutputSerializer.plain(failure.plain) == "unsupported\n",
      "unsupported output keeps its plain token"
    )

    let first = FakeCompatibleAudioDevice(
      name: "Status AirPods",
      listeningMode: .transparency
    )
    let second = FakeCompatibleAudioDevice(
      name: "Studio Beats",
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: false
    )
    let status = StatusCommand.outcome(devices: [first, second])
    #expect(
      CLIOutputSerializer.plain(status.plain) == """
      Status AirPods:
        Listening mode: transparency
        Conversation Awareness: off
        Selected as audio output: no
        Selected as audio input: no

      Studio Beats:
        Listening mode: noise-cancellation
        Selected as audio output: no
        Selected as audio input: no
      """ + "\n",
      "status plain output preserves device order and grouping"
    )
  }

  @Test("Renders deterministic terminal and GitHub report fixtures")
  func supportReportOutputFixtures() throws {
    let privateName = "PRIVATE-DEVICE-NAME-SENTINEL-OUTPUT"
    let device = FakeCompatibleAudioDevice(
      name: privateName,
      listeningModes: [.transparency, .noiseCancellation],
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: false,
      reportMetadata: .fixture(modelIdentifier: "BTHeadphones76,8231")
    )
    let snapshot = SupportReportSnapshot.capture(
      device: device,
      operatingSystemVersion: OperatingSystemVersion(
        majorVersion: 14,
        minorVersion: 2,
        patchVersion: 3
      )
    )
    let document = SupportReportDocument.make(
      snapshot: snapshot,
      cliVersion: "9.9.9"
    )
    let terminal = SupportReportTerminalRenderer.render(
      document,
      options: SupportReportTerminalRenderOptions(
        colorEnabled: false,
        width: 72
      )
    )
    let github = SupportReportGitHubRenderer.render(document)

    #expect(terminal == """
    Compatibility report
    ════════════════════════════════════════════

    Device
      Model                    AirPods Pro 3
      Identifier               BTHeadphones76,8231 · product 0x2027
      Family                   AirPods
      macOS                    14.2.3
      airpods-control          9.9.9

    Capabilities
      Listening modes          Transparency, Noise cancellation
      Mode query               Available · recognized mode
      Mode setter              Available · not tested
      Conversation Awareness   Supported
      CA query                 Available
      CA setter                Available · not tested

    Write tests
      Status                   NOT RUN

    Review complete. Nothing has been submitted to GitHub.
    """, "terminal report fixture remains exact at width 72 without color")
    #expect(
      !terminal.contains(privateName),
      "terminal report fixture omits the private device name"
    )

    #expect(github.title == "[Compatibility] AirPods Pro 3 on macOS 14.2.3")
    #expect(github.report == """
    #### Device

    - Model: AirPods Pro 3
    - Model identifier: `BTHeadphones76,8231` (Bluetooth product ID 0x2027)
    - Device family: AirPods
    - macOS: 14.2.3
    - airpods-control: 9.9.9

    #### Capabilities

    - Advertised known listening modes: transparency, noise-cancellation
    - Other advertised listening modes: none
    - Listening-mode query: answers with a recognized mode
    - Listening-mode setter: exposed, not tested by this report
    - Conversation Awareness capability: supported
    - Conversation Awareness query: answers
    - Conversation Awareness setter: exposed, not tested by this report

    #### Write tests

    - Status: not run
    """, "GitHub report fixture remains exact")
    #expect(
      !github.report.contains(privateName) && !github.title.contains(privateName),
      "GitHub report fixture omits the private device name"
    )
  }
}

private func cachedListeningModeListOutcome() throws -> CommandOutcome {
  let clock = Date(timeIntervalSince1970: 2_000_000_000)
  let backend = FakeHALRoutingBackend()
  backend.rawModeRead = .value(2)
  let cache = try #require(InMemoryListeningModeAllowOffCache(
    salt: Data(repeating: 0xA5, count: 32),
    now: { clock }
  ))
  backend.deviceUIDs[42] = .value("uid-42")
  let correlation = ListeningModeAllowOffCorrelation(
    targetAudioDeviceID: 42,
    collisionAudioDeviceIDs: [42],
    backend: backend,
    cache: cache,
    logger: DebugLogger(enabled: false),
    now: { clock }
  )
  let transport = HALListeningModeTransport(
    name: "Cached AirPods",
    audioDeviceID: 42,
    bluetoothDevice: NSObject(),
    backend: backend,
    logger: DebugLogger(enabled: false),
    wait: { _ in }
  )
  _ = cache.applyObservation(
    rawDeviceUID: "uid-42",
    allowsOff: true,
    observedAt: clock
  )
  let candidate = ListeningModeCandidate(
    displayName: "Cached AirPods",
    selectableNames: ["Cached AirPods"],
    avTransport: nil,
    halTransport: transport,
    route: .notSelected,
    allowOffCorrelation: correlation
  )
  return try coordinatorOutcome(
    ["lm", "list", "--json"],
    candidates: [candidate]
  )
}
