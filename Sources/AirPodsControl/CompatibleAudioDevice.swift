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

extension DeviceStatusField: Equatable where State: Equatable {}

// Audio-device selection has no unsupported state: every compatible device
// can be compared with the selected route when its identity is available.
// Unresolved means that comparison could not be made safely; readError means
// a required Core Audio route or identity read failed.
enum AudioDeviceSelectionObservation: Equatable {
  case selected
  case notSelected
  case unresolved
  case readError
}

enum DeviceSelectionPolicy {
  // Operational commands require one target. They never choose the first
  // device merely because discovery returned it first.
  case singleOrExact
  // Status lists every compatible device when unnamed. A supplied name still
  // uses the same unique exact-match rule as every other operational command.
  case allOrExact
}

enum DeviceSelection<Value> {
  case selected([Value])
  case noDevice
  case ambiguousDevice
}

enum DeviceDisplayName {
  static func matches(_ lhs: String, _ rhs: String) -> Bool {
    lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
  }
}

enum DeviceNameSelection {
  static func select<T>(
    _ items: [T],
    named requestedName: String?,
    name: (T) -> String?,
    policy: DeviceSelectionPolicy,
    logger: DebugLogger
  ) -> DeviceSelection<T> {
    if let requestedName {
      let matches = items.filter { item in
        guard let itemName = name(item) else { return false }
        return DeviceDisplayName.matches(itemName, requestedName)
      }
      guard let selected = matches.first else {
        logger.warning("device_selection", "no-exact-name-match")
        return .noDevice
      }
      guard matches.count == 1 else {
        logger.warning("device_selection", "ambiguous-device-name")
        return .ambiguousDevice
      }
      logger.info("selected_device", name(selected))
      return .selected([selected])
    }

    guard !items.isEmpty else {
      logger.warning("device_selection", "no-compatible-device")
      return .noDevice
    }
    switch policy {
    case .singleOrExact:
      guard items.count == 1, let selected = items.first else {
        logger.warning("device_selection", "ambiguous-device")
        return .ambiguousDevice
      }
      logger.info("selected_device", name(selected))
      return .selected([selected])
    case .allOrExact:
      logger.info("selected_device_count", items.count)
      return .selected(items)
    }
  }
}

enum CommandDeviceResolution {
  case devices([any CompatibleAudioDevice])
  case failed(TerminalReason)
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

  func readInEarPlacementStatus() -> DeviceStatusField<BluetoothEarPlacement>

  func readAudioOutputSelectionStatus() -> AudioDeviceSelectionObservation
  func readAudioInputSelectionStatus() -> AudioDeviceSelectionObservation

  // Blocks for the given interval without going stale: the production
  // adapter must keep pumping the main run loop while it waits. How long to
  // wait is the caller's policy, not the device's.
  func settle(for interval: TimeInterval)
}

extension CompatibleAudioDevice {
  func readInEarPlacementStatus() -> DeviceStatusField<BluetoothEarPlacement> {
    .unresolved
  }
}
