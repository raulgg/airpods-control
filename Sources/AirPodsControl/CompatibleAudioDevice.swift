struct DeviceWriteObservation<State> {
  let setterAccepted: Bool
  let observed: State?
}

protocol CompatibleAudioDevice {
  var name: String { get }

  func supportReportMetadata() -> SupportReportDeviceMetadata

  func availableListeningModes() -> [ListeningMode]
  func currentListeningMode() -> ListeningMode?
  func canSetListeningMode() -> Bool
  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode>
  func waitForListeningModeEffect()

  func supportsConversationAwareness() -> Bool?
  func conversationAwarenessState() -> Bool?
  func canSetConversationAwareness() -> Bool
  func setConversationAwarenessAndReadBack(
    _ target: Bool
  ) -> DeviceWriteObservation<Bool>
}

extension CompatibleAudioDevice {
  func waitForListeningModeEffect() {}
}
