import Foundation

struct DeviceWriteObservation<State> {
  let setterAccepted: Bool
  let observed: State?
}

protocol CompatibleAudioDevice {
  // Absent when the adapter was told not to read the customizable name, which
  // is what the support-report path asks for. Absence is not a blank name:
  // there is nothing here to print.
  var name: String? { get }

  func supportReportMetadata() -> SupportReportDeviceMetadata

  func availableListeningModes() -> [ListeningMode]
  func currentListeningMode() -> ListeningMode?
  func canSetListeningMode() -> Bool
  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode>

  func supportsConversationAwareness() -> Bool?
  func conversationAwarenessState() -> Bool?
  func canSetConversationAwareness() -> Bool
  func setConversationAwarenessAndReadBack(
    _ target: Bool
  ) -> DeviceWriteObservation<Bool>

  // Blocks for the given interval without going stale: the production
  // adapter must keep pumping the main run loop while it waits. How long to
  // wait is the caller's policy, not the device's.
  func settle(for interval: TimeInterval)
}
