import Foundation

extension SupportReportDeviceMetadata {
  // Defaults to AirPods Pro 3 (`BTHeadphones76,8231`, Bluetooth product ID
  // 0x2027), the verified baseline device. Tests pass only the fields they
  // actually vary.
  static func fixture(
    family: SupportReportDeviceFamily? = .airPods,
    modelIdentifier: String? = "BTHeadphones76,8231",
    unrecognizedListeningModes: [String] = [],
    listeningModeQueryAnswered: Bool = true
  ) -> SupportReportDeviceMetadata {
    SupportReportDeviceMetadata(
      family: family,
      modelIdentifier: modelIdentifier,
      unrecognizedListeningModes: unrecognizedListeningModes,
      listeningModeQueryAnswered: listeningModeQueryAnswered
    )
  }
}

final class FakeCompatibleAudioDevice: CompatibleAudioDevice {
  let name: String?
  var listeningModes: [ListeningMode]
  var listeningMode: ListeningMode?
  var appliesListeningModeWrite: Bool
  var conversationAwarenessSupported: Bool?
  var conversationAwarenessEnabled: Bool?
  var appliesConversationAwarenessWrite: Bool
  var listeningModeStatusOverride: DeviceStatusField<ListeningMode>?
  var conversationAwarenessStatusOverride: DeviceStatusField<Bool>?
  var audioOutputSelectionStatus: AudioDeviceSelectionObservation
  var audioInputSelectionStatus: AudioDeviceSelectionObservation
  var reportMetadata: SupportReportDeviceMetadata
  var exposesListeningModeSetter = true
  var exposesConversationAwarenessSetter = true
  var listeningModeSetterAccepted: (ListeningMode) -> Bool = { _ in true }
  var conversationAwarenessSetterAccepted: (Bool) -> Bool = { _ in true }
  // When set, a listening-mode write lands on the returned mode instead of
  // the requested one (nil = the device reports no mode after the write).
  var listeningModeWriteOverride: ((ListeningMode) -> ListeningMode?)?
  // Runs on each settle, simulating state that changes during the hold.
  var settleEffect: (() -> Void)?
  var conversationAwarenessStateEffect: (() -> Void)?
  var lastListeningModeTarget: ListeningMode?
  var listeningModeSetCount = 0
  var settleIntervals: [TimeInterval] = []
  var conversationAwarenessSetCount = 0
  var supportReportMetadataReadCount = 0
  var availableListeningModesReadCount = 0
  var currentListeningModeReadCount = 0
  var listeningModeStatusReadCount = 0
  var conversationAwarenessSupportReadCount = 0
  var conversationAwarenessStateReadCount = 0
  var conversationAwarenessStatusReadCount = 0
  var audioOutputSelectionStatusReadCount = 0
  var audioInputSelectionStatusReadCount = 0

  // Defaults to no name, matching a device discovered without reading the
  // name selector. Tests that select or print a name pass one.
  init(
    name: String? = nil,
    listeningModes: [ListeningMode] = ListeningMode.allCases,
    listeningMode: ListeningMode? = .transparency,
    appliesListeningModeWrite: Bool = true,
    conversationAwarenessSupported: Bool? = true,
    conversationAwarenessEnabled: Bool? = false,
    appliesConversationAwarenessWrite: Bool = true,
    audioOutputSelectionStatus: AudioDeviceSelectionObservation = .notSelected,
    audioInputSelectionStatus: AudioDeviceSelectionObservation = .notSelected,
    reportMetadata: SupportReportDeviceMetadata = SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "AirPodsTest1,1",
      unrecognizedListeningModes: [],
      listeningModeQueryAnswered: true
    )
  ) {
    self.name = name
    self.listeningModes = listeningModes
    self.listeningMode = listeningMode
    self.appliesListeningModeWrite = appliesListeningModeWrite
    self.conversationAwarenessSupported = conversationAwarenessSupported
    self.conversationAwarenessEnabled = conversationAwarenessEnabled
    self.appliesConversationAwarenessWrite = appliesConversationAwarenessWrite
    self.audioOutputSelectionStatus = audioOutputSelectionStatus
    self.audioInputSelectionStatus = audioInputSelectionStatus
    self.reportMetadata = reportMetadata
  }

  func supportReportMetadata() -> SupportReportDeviceMetadata {
    supportReportMetadataReadCount += 1
    return reportMetadata
  }

  func availableListeningModes() -> [ListeningMode] {
    availableListeningModesReadCount += 1
    return listeningModes
  }

  func currentListeningMode() -> ListeningMode? {
    currentListeningModeReadCount += 1
    return listeningMode
  }

  func readListeningModeStatus() -> DeviceStatusField<ListeningMode> {
    listeningModeStatusReadCount += 1
    if let listeningModeStatusOverride { return listeningModeStatusOverride }
    return currentListeningMode().map(DeviceStatusField.value) ?? .unresolved
  }

  func canSetListeningMode() -> Bool {
    exposesListeningModeSetter
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    listeningModeSetCount += 1
    lastListeningModeTarget = target
    let setterAccepted = listeningModeSetterAccepted(target)
    if setterAccepted, let listeningModeWriteOverride {
      listeningMode = listeningModeWriteOverride(target)
    } else if setterAccepted, appliesListeningModeWrite {
      listeningMode = target
    }
    return DeviceWriteObservation(
      setterAccepted: setterAccepted,
      observed: listeningMode
    )
  }

  func settle(for interval: TimeInterval) {
    settleIntervals.append(interval)
    settleEffect?()
  }

  func supportsConversationAwareness() -> Bool? {
    conversationAwarenessSupportReadCount += 1
    return conversationAwarenessSupported
  }

  func conversationAwarenessState() -> Bool? {
    conversationAwarenessStateReadCount += 1
    conversationAwarenessStateEffect?()
    return conversationAwarenessEnabled
  }

  func readConversationAwarenessStatus() -> DeviceStatusField<Bool> {
    conversationAwarenessStatusReadCount += 1
    if let conversationAwarenessStatusOverride { return conversationAwarenessStatusOverride }
    guard let supported = supportsConversationAwareness() else { return .unresolved }
    guard supported else { return .unsupported }
    return conversationAwarenessState().map(DeviceStatusField.value) ?? .unresolved
  }

  func canSetConversationAwareness() -> Bool {
    exposesConversationAwarenessSetter
  }

  func setConversationAwarenessAndReadBack(
    _ target: Bool
  ) -> DeviceWriteObservation<Bool> {
    conversationAwarenessSetCount += 1
    let setterAccepted = conversationAwarenessSetterAccepted(target)
    if setterAccepted, appliesConversationAwarenessWrite {
      conversationAwarenessEnabled = target
    }
    return DeviceWriteObservation(
      setterAccepted: setterAccepted,
      observed: conversationAwarenessEnabled
    )
  }

  func readAudioOutputSelectionStatus() -> AudioDeviceSelectionObservation {
    audioOutputSelectionStatusReadCount += 1
    return audioOutputSelectionStatus
  }

  func readAudioInputSelectionStatus() -> AudioDeviceSelectionObservation {
    audioInputSelectionStatusReadCount += 1
    return audioInputSelectionStatus
  }
}
