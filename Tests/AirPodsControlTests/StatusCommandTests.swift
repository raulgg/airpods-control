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

func testStatusRendersOneOrManyDevicesInResolverOrder() {
  let bedroom = FakeCompatibleAudioDevice(
    name: "Bedroom AirPods",
    listeningMode: .transparency,
    conversationAwarenessEnabled: true,
    audioOutputSelectionStatus: .selected,
    audioInputSelectionStatus: .notSelected
  )
  let studio = FakeCompatibleAudioDevice(
    name: "Studio Beats",
    listeningMode: .noiseCancellation,
    conversationAwarenessSupported: false,
    audioOutputSelectionStatus: .notSelected,
    audioInputSelectionStatus: .selected
  )

  let outcome = statusOutcome(devices: [bedroom, studio])
  check(outcome.exitCode == 0, "multi-device status succeeds")
  check(
    outcome.plain == """
    Bedroom AirPods:
      Listening mode: transparency
      Conversation Awareness: on
      Selected as audio output: yes
      Selected as audio input: no

    Studio Beats:
      Listening mode: noise-cancellation
      Selected as audio output: no
      Selected as audio input: yes
    """,
    "plain status groups fields under device names in resolver order"
  )
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
  check(
    records[1]["conversationAwareness"] == nil,
    "proven unsupported CA omits its canonical JSON key"
  )
  check(
    records[0]["isSelectedAudioOutput"] as? Bool == true
      && records[0]["isSelectedAudioInput"] as? Bool == false,
    "selection observations use JSON booleans"
  )
  check(
    records[1]["isSelectedAudioOutput"] as? Bool == false
      && records[1]["isSelectedAudioInput"] as? Bool == true,
    "each device has independent input and output selection observations"
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
      Conversation Awareness: unknown
      Selected as audio output: no
      Selected as audio input: no
    """,
    "unresolved status uses individual-get plain fallbacks"
  )
  guard let record = statusRecords(outcome)?.first else {
    check(false, "unresolved status has a JSON record")
    return
  }
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
      Selected as audio output: no
      Selected as audio input: no
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

  let featureFailures = FakeCompatibleAudioDevice(name: "Feature failures")
  featureFailures.listeningModeStatusOverride = .readError
  featureFailures.conversationAwarenessStatusOverride = .readError
  let featureFailureOutcome = statusOutcome(devices: [featureFailures])
  check(
    featureFailureOutcome.exitCode == 0,
    "successful selection observations make all-feature-read errors a partial success"
  )
  check(
    featureFailureOutcome.payload["error"] == nil,
    "usable selection observations prevent a top-level read error"
  )

  let failed = FakeCompatibleAudioDevice(
    name: "Failed AirPods",
    audioOutputSelectionStatus: .readError,
    audioInputSelectionStatus: .readError
  )
  failed.listeningModeStatusOverride = .readError
  failed.conversationAwarenessStatusOverride = .readError
  let failedOutcome = statusOutcome(devices: [failed])
  check(failedOutcome.exitCode == 5, "all-read-error status uses exit five")
  check(failedOutcome.payload["result"] as? String == "error", "all-read-error result is error")
  check(failedOutcome.payload["error"] as? String == "read-error", "all-read-error is distinct")
  check(
    failedOutcome.plain == """
    Failed AirPods:
      Listening mode: unknown
      Conversation Awareness: unknown
      Selected as audio output: unknown
      Selected as audio input: unknown
      Read errors: Listening mode, Conversation Awareness, Audio output selection, Audio input selection
    """,
    "plain all-read-error lists every field in presentation order"
  )
  let failedErrors = statusRecords(failedOutcome)?.first?["errors"] as? [String: String]
  check(
    failedErrors == [
      "listeningMode": "read-error",
      "conversationAwareness": "read-error",
      "isSelectedAudioOutput": "read-error",
      "isSelectedAudioInput": "read-error",
    ],
    "JSON all-read-error map names every canonical field"
  )
  let unsupported = FakeCompatibleAudioDevice(name: "Unsupported Beats")
  unsupported.listeningModeStatusOverride = .unsupported
  unsupported.conversationAwarenessStatusOverride = .unsupported
  let mixed = statusOutcome(devices: [failed, unsupported])
  check(mixed.exitCode == 0, "proven unsupported outcomes keep a mixed scan successful")
  check(mixed.payload["result"] as? String == "ok", "mixed scan has an ok result")
}

func testStatusDistinguishesUnresolvedSelectionFromReadErrors() {
  let device = FakeCompatibleAudioDevice(
    name: "Selection AirPods",
    audioOutputSelectionStatus: .unresolved,
    audioInputSelectionStatus: .readError
  )

  let outcome = statusOutcome(devices: [device])
  check(outcome.exitCode == 0, "an unresolved selection is a usable non-error result")
  check(
    outcome.plain == """
    Selection AirPods:
      Listening mode: transparency
      Conversation Awareness: off
      Selected as audio output: unknown
      Selected as audio input: unknown
      Read errors: Audio input selection
    """,
    "unresolved and failed selection reads share the unknown fallback but only failures are listed"
  )
  guard let record = statusRecords(outcome)?.first else {
    check(false, "selection fallback status has a JSON record")
    return
  }
  check(record["isSelectedAudioOutput"] is NSNull, "unresolved output selection is JSON null")
  check(record["isSelectedAudioInput"] is NSNull, "failed input selection is JSON null")
  check(
    record["errors"] as? [String: String] == ["isSelectedAudioInput": "read-error"],
    "only the failed selection direction has a canonical JSON error"
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
    check(
      device.audioOutputSelectionStatusReadCount == 1,
      "status samples audio output selection once"
    )
    check(
      device.audioInputSelectionStatusReadCount == 1,
      "status samples audio input selection once"
    )
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
    check((outcome.payload["devices"] as? [[String: Any]])?.isEmpty == true, "no-device array is empty")
    check(outcome.payload["error"] as? String == "no-device", "no-device JSON has its error")
    check(outcome.payload["result"] as? String == "error", "no-device JSON is an error")
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
  testStatusDistinguishesUnresolvedSelectionFromReadErrors()
  testStatusEscapesPlainHeadingsWithoutChangingJSONNames()
  testStatusIsOnePassAndReadOnly()
  testStatusNoDeviceContractAndResolutionPolicy()
}
