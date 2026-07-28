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
  let name: String
  var listeningModes: [ListeningMode]
  var listeningMode: ListeningMode?
  var appliesListeningModeWrite: Bool
  var conversationAwarenessSupported: Bool?
  var conversationAwarenessEnabled: Bool?
  var appliesConversationAwarenessWrite: Bool
  var reportMetadata: SupportReportDeviceMetadata
  var exposesListeningModeSetter = true
  var exposesConversationAwarenessSetter = true
  var listeningModeSetterAccepted: (ListeningMode) -> Bool = { _ in true }
  var conversationAwarenessSetterAccepted: (Bool) -> Bool = { _ in true }
  // When set, a listening-mode write lands on the returned mode instead of
  // the requested one (nil = the device reports no mode after the write).
  var listeningModeWriteOverride: ((ListeningMode) -> ListeningMode?)?
  var listeningModeEffect: (() -> Void)?
  var conversationAwarenessStateEffect: (() -> Void)?
  var lastListeningModeTarget: ListeningMode?
  var listeningModeSetCount = 0
  var listeningModeEffectWaitCount = 0
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

  func waitForListeningModeEffect() {
    listeningModeEffectWaitCount += 1
    listeningModeEffect?()
  }

  func supportsConversationAwareness() -> Bool? {
    conversationAwarenessSupported
  }

  func conversationAwarenessState() -> Bool? {
    conversationAwarenessStateEffect?()
    return conversationAwarenessEnabled
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
}
