import Foundation

private func statusOutcome(
  _ arguments: [String] = ["status"],
  devices: [any CompatibleAudioDevice]?
) -> CommandOutcome {
  let invocation = try! parseInvocation(arguments)
  return CommandExecution.execute(
    invocation,
    resolveDevices: { _, _, _ in devices }
  )
}

private func statusRecords(_ outcome: CommandOutcome) -> [[String: Any]]? {
  outcome.payload["devices"] as? [[String: Any]]
}

private func serializedStatusPayload(_ outcome: CommandOutcome) -> String? {
  guard JSONSerialization.isValidJSONObject(outcome.payload),
        let data = try? JSONSerialization.data(
          withJSONObject: outcome.payload,
          options: [.sortedKeys]
        )
  else {
    return nil
  }
  return String(decoding: data, as: UTF8.self)
}

func testStatusRendersOneOrManyDevicesInResolverOrder() {
  let bedroom = FakeCompatibleAudioDevice(
    name: "Bedroom AirPods",
    listeningMode: .transparency,
    conversationAwarenessEnabled: true
  )
  let studio = FakeCompatibleAudioDevice(
    name: "Studio Beats",
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false
  )

  let outcome = statusOutcome(devices: [bedroom, studio])
  check(outcome.exitCode == 0, "multi-device status succeeds")
  check(
    outcome.plain == """
    Bedroom AirPods:
      Listening mode: transparency
      Conversation Awareness: on

    Studio Beats:
      Listening mode: noise-cancellation
    """,
    "plain status groups fields under device names in resolver order"
  )
  check(outcome.payload.count == 2, "successful status has the exact top-level shape")
  check(outcome.payload["result"] as? String == "ok", "multi-device status result is ok")
  guard let records = statusRecords(outcome) else {
    check(false, "status payload contains device records")
    return
  }
  check(records.count == 2, "status payload contains every resolved device")
  check(records[0]["device"] as? String == "Bedroom AirPods", "JSON preserves first device")
  check(records[1]["device"] as? String == "Studio Beats", "JSON preserves second device")
  check(
    records[0]["listeningMode"] as? String == "transparency"
      && records[0]["conversationAwareness"] as? String == "on",
    "available status fields use canonical values"
  )
  check(records[1].count == 2, "unsupported CA leaves the exact reduced record shape")
  check(
    records[1]["conversationAwareness"] == nil,
    "proven unsupported CA omits its canonical JSON key"
  )
  check(records.allSatisfy { $0["lm"] == nil && $0["ca"] == nil }, "aliases are never JSON keys")
  check(
    serializedStatusPayload(outcome) == """
    {"devices":[{"conversationAwareness":"on","device":"Bedroom AirPods","listeningMode":"transparency"},{"device":"Studio Beats","listeningMode":"noise-cancellation"}],"result":"ok"}
    """,
    "multi-device status has the exact sorted JSON contract"
  )

  let singleton = statusOutcome(
    ["status", "--device", "Bedroom AirPods", "--json"],
    devices: [bedroom]
  )
  check(singleton.plain.hasPrefix("Bedroom AirPods:\n"), "singleton status retains its heading")
  check(statusRecords(singleton)?.count == 1, "selected status JSON still uses a devices array")
}

func testStatusPreservesExistingUnresolvedGetFallbacks() {
  let unresolved = FakeCompatibleAudioDevice(
    name: "Office AirPods",
    listeningMode: nil,
    conversationAwarenessSupported: nil,
    conversationAwarenessEnabled: nil
  )
  let outcome = statusOutcome(devices: [unresolved])
  check(outcome.exitCode == 0, "unresolved reads still produce a successful status")
  check(
    outcome.plain == """
    Office AirPods:
      Listening mode: unknown
      Conversation Awareness: unsupported
    """,
    "unresolved status uses individual-get plain fallbacks"
  )
  guard let record = statusRecords(outcome)?.first else {
    check(false, "unresolved status has a JSON record")
    return
  }
  check(record.count == 3, "unresolved status keeps both canonical state keys")
  check(record["listeningMode"] is NSNull, "unresolved listening mode is JSON null")
  check(record["conversationAwareness"] is NSNull, "unresolved CA is JSON null")
  check(record["errors"] == nil, "unresolved values are not read errors")

  let missingState = FakeCompatibleAudioDevice(
    name: "State AirPods",
    conversationAwarenessSupported: true,
    conversationAwarenessEnabled: nil
  )
  let missingStateOutcome = statusOutcome(devices: [missingState])
  let missingStateRecord = statusRecords(missingStateOutcome)?.first
  check(
    missingStateRecord?["conversationAwareness"] is NSNull,
    "supported CA with unresolved state keeps the existing null fallback"
  )
  check(missingStateRecord?["errors"] == nil, "nil fake CA state is unresolved by default")
}

func testStatusReportsReadErrorsAndAggregateExitPolicy() {
  let partial = FakeCompatibleAudioDevice(
    name: "Partial AirPods",
    conversationAwarenessEnabled: true
  )
  partial.listeningModeStatusOverride = .readError

  let partialOutcome = statusOutcome(devices: [partial])
  check(partialOutcome.exitCode == 0, "one usable field keeps aggregate status successful")
  check(
    partialOutcome.plain == """
    Partial AirPods:
      Listening mode: unknown
      Conversation Awareness: on
      Read errors: Listening mode
    """,
    "plain status identifies the field with a real read error"
  )
  guard let partialRecord = statusRecords(partialOutcome)?.first else {
    check(false, "partial-error status has a record")
    return
  }
  check(partialRecord["listeningMode"] is NSNull, "read error retains get fallback state")
  check(
    (partialRecord["errors"] as? [String: String]) == ["listeningMode": "read-error"],
    "JSON records a canonical per-field read error"
  )
  check(partialOutcome.payload["error"] == nil, "mixed status has no top-level error")

  let failed = FakeCompatibleAudioDevice(name: "Failed AirPods")
  failed.listeningModeStatusOverride = .readError
  failed.conversationAwarenessStatusOverride = .readError
  let failedOutcome = statusOutcome(devices: [failed])
  check(failedOutcome.exitCode == 5, "all-read-error status uses exit five")
  check(failedOutcome.payload["result"] as? String == "error", "all-read-error result is error")
  check(failedOutcome.payload["error"] as? String == "read-error", "all-read-error is distinct")
  check(
    failedOutcome.plain.contains("Read errors: Listening mode, Conversation Awareness"),
    "plain all-read-error lists both fields in canonical order"
  )
  let failedErrors = statusRecords(failedOutcome)?.first?["errors"] as? [String: String]
  check(
    failedErrors == [
      "listeningMode": "read-error",
      "conversationAwareness": "read-error",
    ],
    "JSON all-read-error map names both canonical fields"
  )
  check(
    serializedStatusPayload(failedOutcome) == """
    {"devices":[{"conversationAwareness":null,"device":"Failed AirPods","errors":{"conversationAwareness":"read-error","listeningMode":"read-error"},"listeningMode":null}],"error":"read-error","result":"error"}
    """,
    "all-read-error status has the exact sorted JSON contract"
  )

  let unsupported = FakeCompatibleAudioDevice(name: "Unsupported Beats")
  unsupported.listeningModeStatusOverride = .unsupported
  unsupported.conversationAwarenessStatusOverride = .unsupported
  let mixed = statusOutcome(devices: [failed, unsupported])
  check(mixed.exitCode == 0, "proven unsupported outcomes keep a mixed scan successful")
  check(mixed.payload["result"] as? String == "ok", "mixed scan has an ok result")
  check(
    statusRecords(mixed)?.last?.count == 1,
    "a fully unsupported record contains only its device identity"
  )
}

func testStatusEscapesPlainHeadingsWithoutChangingJSONNames() {
  let name = "Café 🎧\n\r\t\\\u{001B}\u{007F}\u{2028}"
  let device = FakeCompatibleAudioDevice(name: name)
  let outcome = statusOutcome(devices: [device])
  check(
    outcome.plain.hasPrefix("Café 🎧\\n\\r\\t\\\\\\u{001B}\\u{007F}\\u{2028}:\n"),
    "plain headings retain normal Unicode and escape record-breaking controls"
  )
  check(statusRecords(outcome)?.first?["device"] as? String == name, "JSON retains the raw device name")
}

func testStatusIsOnePassAndReadOnly() {
  let supported = FakeCompatibleAudioDevice(name: "Read-only Status AirPods")
  let unsupported = FakeCompatibleAudioDevice(
    name: "Unsupported Status Beats",
    conversationAwarenessSupported: false
  )
  _ = statusOutcome(devices: [supported, unsupported])

  for device in [supported, unsupported] {
    check(device.listeningModeStatusReadCount == 1, "status samples listening mode once")
    check(device.currentListeningModeReadCount == 1, "fake status performs one underlying mode read")
    check(device.conversationAwarenessStatusReadCount == 1, "status samples CA once")
    check(device.conversationAwarenessSupportReadCount == 1, "status probes CA support once")
    check(device.listeningModeSetCount == 0, "status never sets listening mode")
    check(device.conversationAwarenessSetCount == 0, "status never sets CA")
    check(device.settleIntervals.isEmpty, "status never settles or polls")
    check(device.supportReportMetadataReadCount == 0, "status never reads report metadata")
    check(device.availableListeningModesReadCount == 0, "status does not list available modes")
  }
  check(supported.conversationAwarenessStateReadCount == 1, "supported CA state is read once")
  check(unsupported.conversationAwarenessStateReadCount == 0, "unsupported CA skips state read")
}

func testStatusNoDeviceContractAndResolutionPolicy() {
  for arguments in [["status"], ["status", "--device", "Missing AirPods"]] {
    var capturedName: String?
    var capturedPolicy: DeviceSelectionPolicy?
    let invocation = try! parseInvocation(arguments)
    let outcome = CommandExecution.execute(
      invocation,
      resolveDevices: { name, policy, _ in
        capturedName = name
        capturedPolicy = policy
        return nil
      }
    )
    check(outcome.exitCode == 1, "status no-device exits one")
    check(
      outcome.plain == "No compatible AirPods or Beats device is connected.",
      "status uses the exact accepted no-device sentence"
    )
    check(outcome.payload.count == 3, "status no-device has the exact payload shape")
    check((outcome.payload["devices"] as? [[String: Any]])?.isEmpty == true, "no-device array is empty")
    check(outcome.payload["error"] as? String == "no-device", "no-device JSON has its error")
    check(outcome.payload["result"] as? String == "error", "no-device JSON is an error")
    check(
      serializedStatusPayload(outcome)
        == "{\"devices\":[],\"error\":\"no-device\",\"result\":\"error\"}",
      "status no-device JSON is exact"
    )
    if arguments.count == 1 {
      check(capturedName == nil, "unnamed status forwards no requested name")
    } else {
      check(capturedName == "Missing AirPods", "named status forwards the requested name")
    }
    if case .allOrExact? = capturedPolicy {
      check(true, "status requests all-or-exact device resolution")
    } else {
      check(false, "status requests all-or-exact device resolution")
    }
  }
}

func runStatusCommandTests() {
  testStatusRendersOneOrManyDevicesInResolverOrder()
  testStatusPreservesExistingUnresolvedGetFallbacks()
  testStatusReportsReadErrorsAndAggregateExitPolicy()
  testStatusEscapesPlainHeadingsWithoutChangingJSONNames()
  testStatusIsOnePassAndReadOnly()
  testStatusNoDeviceContractAndResolutionPolicy()
}
