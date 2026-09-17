import Foundation
import Testing

@testable import AirPodsControlCore

@Suite("Audio device status interface")
struct AudioDeviceStatusReadingTests {
  @Test("Renders exact output through the narrow status interface")
  func rendersExactStatusOutputAndReadOrder() throws {
    let device = StatusOnlyAudioDevice(
      name: "Status-only AirPods",
      listeningMode: .value(.transparency),
      conversationAwareness: .value(true),
      audioOutputSelection: .selected,
      audioInputSelection: .notSelected,
      inEarPlacement: .value(
        BluetoothEarPlacement(left: .inEar, right: .inCase)
      )
    )
    let invocation = try parseInvocation(["status", "--json"])
    let outcome = CommandExecution.execute(invocation) { _, policy, _ in
      #expect(policy == .allOrExact, "status keeps the all-or-exact policy")
      return .statusDevices([device])
    }

    #expect(
      outcome.plain == """
      Status-only AirPods:
        Listening mode: transparency
        Conversation Awareness: on
        Selected as audio output: yes
        Selected as audio input: no
        Left ear placement: in-ear
        Right ear placement: in-case
      """,
      "status output remains exact for a read-only device"
    )
    #expect(
      CLIOutputSerializer.json(outcome.jsonPayload)
        == "{\"devices\":[{\"conversationAwareness\":\"on\",\"device\":\"Status-only AirPods\",\"isSelectedAudioInput\":false,\"isSelectedAudioOutput\":true,\"leftEarPlacement\":\"in-ear\",\"listeningMode\":\"transparency\",\"rightEarPlacement\":\"in-case\"}],\"result\":\"ok\"}\n",
      "status JSON remains exact for a read-only device"
    )
    #expect(
      device.readOrder == [
        "name",
        "listeningMode",
        "conversationAwareness",
        "audioOutputSelection",
        "audioInputSelection",
        "inEarPlacement",
      ],
      "status keeps its one-pass read order"
    )
  }

  @Test("Preserves status resolution failure output")
  func preservesStatusResolutionFailureOutput() throws {
    let invocation = try parseInvocation(["status", "--json"])
    let outcome = CommandExecution.execute(invocation) { _, policy, _ in
      #expect(policy == .allOrExact, "status requests all-or-exact resolution")
      return .failed(.unavailable)
    }

    #expect(outcome.exitCode == 6, "status discovery unavailability exits six")
    #expect(
      outcome.plain == "Compatible device discovery is unavailable.",
      "status discovery failures keep their established sentence"
    )
    #expect(
      CLIOutputSerializer.json(outcome.jsonPayload)
        == "{\"devices\":[],\"error\":\"unavailable\",\"result\":\"error\"}\n",
      "status discovery failures keep their established JSON envelope"
    )
  }
}

private final class StatusOnlyAudioDevice: AudioDeviceStatusReading {
  private let storedName: String?
  private let listeningMode: DeviceStatusField<ListeningMode>
  private let conversationAwareness: DeviceStatusField<Bool>
  private let audioOutputSelection: AudioDeviceSelectionObservation
  private let audioInputSelection: AudioDeviceSelectionObservation
  private let inEarPlacement: DeviceStatusField<BluetoothEarPlacement>

  private(set) var readOrder: [String] = []

  init(
    name: String?,
    listeningMode: DeviceStatusField<ListeningMode>,
    conversationAwareness: DeviceStatusField<Bool>,
    audioOutputSelection: AudioDeviceSelectionObservation,
    audioInputSelection: AudioDeviceSelectionObservation,
    inEarPlacement: DeviceStatusField<BluetoothEarPlacement>
  ) {
    storedName = name
    self.listeningMode = listeningMode
    self.conversationAwareness = conversationAwareness
    self.audioOutputSelection = audioOutputSelection
    self.audioInputSelection = audioInputSelection
    self.inEarPlacement = inEarPlacement
  }

  var name: String? {
    readOrder.append("name")
    return storedName
  }

  func readListeningModeStatus() -> DeviceStatusField<ListeningMode> {
    readOrder.append("listeningMode")
    return listeningMode
  }

  func readConversationAwarenessStatus() -> DeviceStatusField<Bool> {
    readOrder.append("conversationAwareness")
    return conversationAwareness
  }

  func readAudioOutputSelectionStatus() -> AudioDeviceSelectionObservation {
    readOrder.append("audioOutputSelection")
    return audioOutputSelection
  }

  func readAudioInputSelectionStatus() -> AudioDeviceSelectionObservation {
    readOrder.append("audioInputSelection")
    return audioInputSelection
  }

  func readInEarPlacementStatus() -> DeviceStatusField<BluetoothEarPlacement> {
    readOrder.append("inEarPlacement")
    return inEarPlacement
  }
}
