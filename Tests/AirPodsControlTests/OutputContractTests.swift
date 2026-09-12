import Testing

@testable import AirPodsControlCore

@Suite("CLI output contracts")
struct OutputContractTests {
  @Test("Renders a representative status journey in JSON and plain text")
  func statusOutputContract() {
    let first = FakeCompatibleAudioDevice(
      name: "Status AirPods",
      listeningMode: .transparency,
      conversationAwarenessEnabled: true,
      audioOutputSelectionStatus: .selected,
      audioInputSelectionStatus: .notSelected
    )
    first.inEarPlacementStatus = .value(
      BluetoothEarPlacement(left: .inEar, right: .inCase)
    )
    let second = FakeCompatibleAudioDevice(
      name: "Studio Beats",
      listeningMode: .noiseCancellation,
      conversationAwarenessSupported: false
    )

    let status = StatusCommand.outcome(devices: [first, second])

    #expect(
      CLIOutputSerializer.json(status.jsonPayload)
        == "{\"devices\":[{\"conversationAwareness\":\"on\",\"device\":\"Status AirPods\",\"isSelectedAudioInput\":false,\"isSelectedAudioOutput\":true,\"leftEarPlacement\":\"in-ear\",\"listeningMode\":\"transparency\",\"rightEarPlacement\":\"in-case\"},{\"device\":\"Studio Beats\",\"isSelectedAudioInput\":false,\"isSelectedAudioOutput\":false,\"listeningMode\":\"noise-cancellation\"}],\"result\":\"ok\"}\n",
      "status JSON preserves its complete envelope, nested fields, and device order"
    )
    #expect(
      CLIOutputSerializer.plain(status.plain) == """
      Status AirPods:
        Listening mode: transparency
        Conversation Awareness: on
        Selected as audio output: yes
        Selected as audio input: no
        Left ear placement: in-ear
        Right ear placement: in-case

      Studio Beats:
        Listening mode: noise-cancellation
        Selected as audio output: no
        Selected as audio input: no
      """ + "\n",
      "status plain output preserves fields, grouping, and its final newline"
    )
  }
}
