import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Status command")
struct StatusCommandTests {
  @Test("Renders one or many devices in resolver order")
  func statusRendersOneOrManyDevicesInResolverOrder() throws {
    let bedroom = FakeCompatibleAudioDevice(
      name: "Bedroom AirPods",
      listeningMode: .transparency,
      conversationAwarenessEnabled: true,
      audioOutputSelectionStatus: .selected,
      audioInputSelectionStatus: .notSelected
    )
    bedroom.inEarPlacementStatus = .value(
      BluetoothEarPlacement(left: .inEar, right: .outOfEar)
    )
    let studio = FakeCompatibleAudioDevice(
      name: "Studio Beats",
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: false,
      audioOutputSelectionStatus: .notSelected,
      audioInputSelectionStatus: .selected
    )

    let outcome = try statusOutcome(devices: [bedroom, studio])
    #expect(outcome.exitCode == 0, "multi-device status succeeds")
    #expect(
      outcome.plain.hasPrefix("Bedroom AirPods:\n")
        && outcome.plain.contains("\n\nStudio Beats:\n"),
      "plain status groups fields under device names in resolver order"
    )
    #expect(
      outcome.plain.contains("Left ear placement: in-ear")
        && outcome.plain.contains("Right ear placement: out-of-ear"),
      "plain status renders known placement states"
    )
    #expect(outcome.payload["result"] as? String == "ok", "multi-device status result is ok")
    let records = try #require(statusRecords(outcome), "status payload contains device records")
    try #require(records.count == 2, "status payload contains every resolved device")
    #expect(records[0]["device"] as? String == "Bedroom AirPods", "JSON preserves first device")
    #expect(records[1]["device"] as? String == "Studio Beats", "JSON preserves second device")
    #expect(
      records[0]["listeningMode"] as? String == "transparency"
        && records[0]["conversationAwareness"] as? String == "on",
      "available status fields use canonical values"
    )
    #expect(
      records[0]["leftEarPlacement"] as? String == "in-ear"
        && records[0]["rightEarPlacement"] as? String == "out-of-ear",
      "known placement states use canonical JSON strings"
    )
    #expect(
      records[1]["conversationAwareness"] == nil,
      "proven unsupported CA omits its canonical JSON key"
    )
    #expect(
      records[1]["leftEarPlacement"] == nil
        && records[1]["rightEarPlacement"] == nil,
      "proven unsupported placement omits its canonical JSON keys"
    )
    #expect(
      records[0]["isSelectedAudioOutput"] as? Bool == true
        && records[0]["isSelectedAudioInput"] as? Bool == false,
      "selection observations use JSON booleans"
    )
    #expect(
      records[1]["isSelectedAudioOutput"] as? Bool == false
        && records[1]["isSelectedAudioInput"] as? Bool == true,
      "each device has independent input and output selection observations"
    )
    bedroom.inEarPlacementStatus = .value(
      BluetoothEarPlacement(left: .inCase, right: .inEar)
    )
    let singleton = try statusOutcome(
      ["status", "--device", "Bedroom AirPods", "--json"],
      devices: [bedroom]
    )
    #expect(singleton.plain.hasPrefix("Bedroom AirPods:\n"), "singleton status retains its heading")
    #expect(statusRecords(singleton)?.count == 1, "selected status JSON still uses a devices array")
    #expect(
      singleton.plain.contains("Left ear placement: in-case")
        && statusRecords(singleton)?.first?["leftEarPlacement"] as? String == "in-case",
      "a later status renders in-case placement consistently in plain and JSON output"
    )
  }

  @Test("Preserves unresolved field fallbacks")
  func statusPreservesExistingUnresolvedGetFallbacks() throws {
    let unresolved = FakeCompatibleAudioDevice(
      name: "Office AirPods",
      listeningMode: nil,
      conversationAwarenessSupported: nil,
      conversationAwarenessEnabled: nil
    )
    unresolved.inEarPlacementStatus = .unresolved
    let outcome = try statusOutcome(devices: [unresolved])
    #expect(outcome.exitCode == 0, "unresolved reads still produce a successful status")
    #expect(
      outcome.plain.contains("Left ear placement: unknown")
        && outcome.plain.contains("Right ear placement: unknown"),
      "unresolved placement uses plain unknown fallbacks"
    )
    let record = try #require(statusRecords(outcome)?.first, "unresolved status has a JSON record")
    #expect(record["listeningMode"] is NSNull, "unresolved listening mode is JSON null")
    #expect(record["conversationAwareness"] is NSNull, "unresolved CA is JSON null")
    #expect(record["leftEarPlacement"] is NSNull, "unresolved left placement is JSON null")
    #expect(record["rightEarPlacement"] is NSNull, "unresolved right placement is JSON null")
    #expect(record["errors"] == nil, "unresolved values are not read errors")

    let missingState = FakeCompatibleAudioDevice(
      name: "State AirPods",
      conversationAwarenessSupported: true,
      conversationAwarenessEnabled: nil
    )
    let missingStateOutcome = try statusOutcome(devices: [missingState])
    let missingStateRecord = statusRecords(missingStateOutcome)?.first
    #expect(
      missingStateRecord?["conversationAwareness"] is NSNull,
      "supported CA with unresolved state keeps the existing null fallback"
    )
    #expect(missingStateRecord?["errors"] == nil, "nil fake CA state is unresolved by default")
  }

  @Test("Reports field read errors and aggregate exit policy")
  func statusReportsReadErrorsAndAggregateExitPolicy() throws {
    let partial = FakeCompatibleAudioDevice(
      name: "Partial AirPods",
      conversationAwarenessEnabled: true
    )
    partial.listeningModeStatusOverride = .readError

    let partialOutcome = try statusOutcome(devices: [partial])
    #expect(partialOutcome.exitCode == 0, "one usable field keeps aggregate status successful")
    #expect(
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
    let partialRecord = try #require(statusRecords(partialOutcome)?.first, "partial-error status has a record")
    #expect(partialRecord["listeningMode"] is NSNull, "read error retains get fallback state")
    #expect(
      (partialRecord["errors"] as? [String: String]) == ["listeningMode": "read-error"],
      "JSON records a canonical per-field read error"
    )
    #expect(partialOutcome.payload["error"] == nil, "mixed status has no top-level error")

    let featureFailures = FakeCompatibleAudioDevice(name: "Feature failures")
    featureFailures.listeningModeStatusOverride = .readError
    featureFailures.conversationAwarenessStatusOverride = .readError
    let featureFailureOutcome = try statusOutcome(devices: [featureFailures])
    #expect(
      featureFailureOutcome.exitCode == 0,
      "successful selection observations make all-feature-read errors a partial success"
    )
    #expect(
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
    failed.inEarPlacementStatus = .readError
    let failedOutcome = try statusOutcome(devices: [failed])
    #expect(failedOutcome.exitCode == 5, "all-read-error status uses exit five")
    #expect(failedOutcome.payload["result"] as? String == "error", "all-read-error result is error")
    #expect(failedOutcome.payload["error"] as? String == "read-error", "all-read-error is distinct")
    #expect(
      failedOutcome.plain.contains("Left ear placement: unknown")
        && failedOutcome.plain.contains("Right ear placement: unknown"),
      "plain all-read-error status keeps placement fallbacks"
    )
    let failedErrors = statusRecords(failedOutcome)?.first?["errors"] as? [String: String]
    #expect(
      failedErrors == [
        "listeningMode": "read-error",
        "conversationAwareness": "read-error",
        "isSelectedAudioOutput": "read-error",
        "isSelectedAudioInput": "read-error",
        "leftEarPlacement": "read-error",
        "rightEarPlacement": "read-error",
      ],
      "JSON all-read-error map names every canonical field"
    )
    let unsupported = FakeCompatibleAudioDevice(name: "Unsupported Beats")
    unsupported.listeningModeStatusOverride = .unsupported
    unsupported.conversationAwarenessStatusOverride = .unsupported
    let mixed = try statusOutcome(devices: [failed, unsupported])
    #expect(mixed.exitCode == 0, "proven unsupported outcomes keep a mixed scan successful")
    #expect(mixed.payload["result"] as? String == "ok", "mixed scan has an ok result")
  }

  @Test("Distinguishes unresolved selection from read errors")
  func statusDistinguishesUnresolvedSelectionFromReadErrors() throws {
    let device = FakeCompatibleAudioDevice(
      name: "Selection AirPods",
      audioOutputSelectionStatus: .unresolved,
      audioInputSelectionStatus: .readError
    )

    let outcome = try statusOutcome(devices: [device])
    #expect(outcome.exitCode == 0, "an unresolved selection is a usable non-error result")
    #expect(
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
    let record = try #require(statusRecords(outcome)?.first, "selection fallback status has a JSON record")
    #expect(record["isSelectedAudioOutput"] is NSNull, "unresolved output selection is JSON null")
    #expect(record["isSelectedAudioInput"] is NSNull, "failed input selection is JSON null")
    #expect(
      record["errors"] as? [String: String] == ["isSelectedAudioInput": "read-error"],
      "only the failed selection direction has a canonical JSON error"
    )
  }

  @Test("Escapes plain headings while retaining raw JSON names")
  func statusEscapesPlainHeadingsWithoutChangingJSONNames() throws {
    let name = "Café 🎧\n\r\t\\\u{001B}\u{007F}\u{2028}"
    let device = FakeCompatibleAudioDevice(name: name)
    let outcome = try statusOutcome(devices: [device])
    #expect(
      outcome.plain.hasPrefix("Café 🎧\\n\\r\\t\\\\\\u{001B}\\u{007F}\\u{2028}:\n"),
      "plain headings retain normal Unicode and escape record-breaking controls"
    )
    #expect(statusRecords(outcome)?.first?["device"] as? String == name, "JSON retains the raw device name")
  }

  @Test("Reads each field once without writing settings")
  func statusIsOnePassAndReadOnly() throws {
    let supported = FakeCompatibleAudioDevice(name: "Read-only Status AirPods")
    let unsupported = FakeCompatibleAudioDevice(
      name: "Unsupported Status Beats",
      conversationAwarenessSupported: false
    )
    _ = try statusOutcome(devices: [supported, unsupported])

    for device in [supported, unsupported] {
      #expect(device.listeningModeStatusReadCount == 1, "status samples listening mode once")
      #expect(device.currentListeningModeReadCount == 1, "fake status performs one underlying mode read")
      #expect(device.conversationAwarenessStatusReadCount == 1, "status samples CA once")
      #expect(device.conversationAwarenessSupportReadCount == 1, "status probes CA support once")
      #expect(
        device.audioOutputSelectionStatusReadCount == 1,
        "status samples audio output selection once"
      )
      #expect(
        device.audioInputSelectionStatusReadCount == 1,
        "status samples audio input selection once"
      )
      #expect(
        device.inEarPlacementStatusReadCount == 1,
        "status samples ear placement once"
      )
      #expect(device.listeningModeSetCount == 0, "status never sets listening mode")
      #expect(device.conversationAwarenessSetCount == 0, "status never sets CA")
      #expect(device.settleIntervals.isEmpty, "status never settles or polls")
      #expect(device.supportReportMetadataReadCount == 0, "status never reads report metadata")
      #expect(device.availableListeningModesReadCount == 0, "status does not list available modes")
    }
    #expect(supported.conversationAwarenessStateReadCount == 1, "supported CA state is read once")
    #expect(unsupported.conversationAwarenessStateReadCount == 0, "unsupported CA skips state read")
  }

  @Test("Preserves resolution failures and all-or-exact policy")
  func statusResolutionFailuresAndPolicy() throws {
    for arguments in [["status"], ["status", "--device", "Missing AirPods"]] {
      var capturedName: String?
      var capturedPolicy: DeviceSelectionPolicy?
      let invocation = try parseInvocation(arguments)
      let outcome = CommandExecution.execute(
        invocation,
        resolveDevices: { name, policy, _ in
          capturedName = name
          capturedPolicy = policy
          return .failed(.noDevice)
        }
      )
      #expect(outcome.exitCode == 1, "status no-device exits one")
      #expect(
        outcome.plain == "No compatible AirPods or Beats device is connected.",
        "status uses the exact accepted no-device sentence"
      )
      #expect((outcome.payload["devices"] as? [[String: Any]])?.isEmpty == true, "no-device array is empty")
      #expect(outcome.payload["error"] as? String == "no-device", "no-device JSON has its error")
      #expect(outcome.payload["result"] as? String == "error", "no-device JSON is an error")
      if arguments.count == 1 {
        #expect(capturedName == nil, "unnamed status forwards no requested name")
      } else {
        #expect(capturedName == "Missing AirPods", "named status forwards the requested name")
      }
      guard case .allOrExact? = capturedPolicy else {
        Issue.record("status requests all-or-exact device resolution")
        return
      }
    }

    let invocation = try parseInvocation(["status"])
    let readError = CommandExecution.execute(
      invocation,
      resolveDevices: { _, _, _ in .failed(.readError) }
    )
    #expect(
      readError.terminalReason == .readError,
      "status preserves a discovery read error"
    )
    #expect(
      (readError.payload["devices"] as? [[String: Any]])?.isEmpty == true,
      "status discovery read errors return an empty device array"
    )
  }
}

private func statusOutcome(
  _ arguments: [String] = ["status"],
  devices: [any CompatibleAudioDevice]?
) throws -> CommandOutcome {
  let invocation = try parseInvocation(arguments)
  return CommandExecution.execute(
    invocation,
    resolveDevices: { _, _, _ in
      guard let devices else { return .failed(.noDevice) }
      return .devices(devices)
    }
  )
}

private func statusRecords(_ outcome: CommandOutcome) -> [[String: Any]]? {
  outcome.payload["devices"] as? [[String: Any]]
}
