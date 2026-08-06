import Foundation

struct DeviceWriteObservation<State> {
  let setterAccepted: Bool
  let observed: State?
}

// Status needs to distinguish a feature the device definitely lacks from a
// state that could not be resolved, and both of those from an actual read
// failure. The individual get commands intentionally keep their established
// optional-value behavior; this richer result is only for aggregate status.
enum DeviceStatusField<State> {
  case value(State)
  case unsupported
  case unresolved
  case readError
}

enum DeviceSelectionPolicy {
  // Existing operational commands use the first compatible device when no
  // name is supplied. A supplied name must always resolve uniquely.
  case firstOrExact
  // Status lists every compatible device when unnamed. A supplied name still
  // uses the same unique exact-match rule as every other operational command.
  case allOrExact
}

protocol CompatibleAudioDevice {
  // Absent when the adapter was told not to read the customizable name, which
  // is what the support-report path asks for. Absence is not a blank name:
  // there is nothing here to print.
  var name: String? { get }

  func supportReportMetadata() -> SupportReportDeviceMetadata

  func availableListeningModes() -> [ListeningMode]
  func currentListeningMode() -> ListeningMode?
  func readListeningModeStatus() -> DeviceStatusField<ListeningMode>
  func canSetListeningMode() -> Bool
  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode>

  func supportsConversationAwareness() -> Bool?
  func conversationAwarenessState() -> Bool?
  func readConversationAwarenessStatus() -> DeviceStatusField<Bool>
  func canSetConversationAwareness() -> Bool
  func setConversationAwarenessAndReadBack(
    _ target: Bool
  ) -> DeviceWriteObservation<Bool>

  // Blocks for the given interval without going stale: the production
  // adapter must keep pumping the main run loop while it waits. How long to
  // wait is the caller's policy, not the device's.
  func settle(for interval: TimeInterval)
}

extension CompatibleAudioDevice {
  func readListeningModeStatus() -> DeviceStatusField<ListeningMode> {
    currentListeningMode().map(DeviceStatusField.value) ?? .unresolved
  }

  func readConversationAwarenessStatus() -> DeviceStatusField<Bool> {
    guard let supported = supportsConversationAwareness() else {
      return .unresolved
    }
    guard supported else { return .unsupported }
    return conversationAwarenessState().map(DeviceStatusField.value) ?? .unresolved
  }
}
