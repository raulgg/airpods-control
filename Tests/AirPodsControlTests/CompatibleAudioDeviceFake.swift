final class FakeCompatibleAudioDevice: CompatibleAudioDevice {
  let name: String
  var listeningModes: [ListeningMode]
  var listeningMode: ListeningMode?
  var appliesListeningModeWrite: Bool
  var conversationAwarenessSupported: Bool?
  var conversationAwarenessEnabled: Bool?
  var appliesConversationAwarenessWrite: Bool
  var reportMetadata: SupportReportDeviceMetadata
  var listeningModeSetCount = 0
  var conversationAwarenessSetCount = 0

  init(
    name: String,
    listeningModes: [ListeningMode] = ListeningMode.allCases,
    listeningMode: ListeningMode? = .transparency,
    appliesListeningModeWrite: Bool = true,
    conversationAwarenessSupported: Bool? = true,
    conversationAwarenessEnabled: Bool? = false,
    appliesConversationAwarenessWrite: Bool = true,
    reportMetadata: SupportReportDeviceMetadata = SupportReportDeviceMetadata(
      family: .airPods,
      modelIdentifier: "AirPodsTest1,1",
      firmwareVersion: "1.0",
      connectionState: .connected
    )
  ) {
    self.name = name
    self.listeningModes = listeningModes
    self.listeningMode = listeningMode
    self.appliesListeningModeWrite = appliesListeningModeWrite
    self.conversationAwarenessSupported = conversationAwarenessSupported
    self.conversationAwarenessEnabled = conversationAwarenessEnabled
    self.appliesConversationAwarenessWrite = appliesConversationAwarenessWrite
    self.reportMetadata = reportMetadata
  }

  func supportReportMetadata() -> SupportReportDeviceMetadata {
    reportMetadata
  }

  func availableListeningModes() -> [ListeningMode] {
    listeningModes
  }

  func currentListeningMode() -> ListeningMode? {
    listeningMode
  }

  func canSetListeningMode() -> Bool {
    true
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    listeningModeSetCount += 1
    if appliesListeningModeWrite {
      listeningMode = target
    }
    return DeviceWriteObservation(
      setterAccepted: true,
      observed: listeningMode
    )
  }

  func supportsConversationAwareness() -> Bool? {
    conversationAwarenessSupported
  }

  func conversationAwarenessState() -> Bool? {
    conversationAwarenessEnabled
  }

  func canSetConversationAwareness() -> Bool {
    true
  }

  func setConversationAwarenessAndReadBack(
    _ target: Bool
  ) -> DeviceWriteObservation<Bool> {
    conversationAwarenessSetCount += 1
    if appliesConversationAwarenessWrite {
      conversationAwarenessEnabled = target
    }
    return DeviceWriteObservation(
      setterAccepted: true,
      observed: conversationAwarenessEnabled
    )
  }
}
