import Foundation

enum ListeningModeBootstrap {
  struct HALInventory {
    let candidates: [ListeningModeCandidate]
    let discovery: ListeningModeHALDiscovery
  }

  static func resolve(
    command: ListeningModeCommand,
    named requestedName: String?,
    avDevices: [PrivateAudioDevice],
    logger: DebugLogger,
    chooseAmbiguous: ([String]) -> ListeningModeAmbiguousChoice,
    loadHAL: () -> HALInventory
  ) -> ListeningModeResolution {
    let avCoordinator = ListeningModeCoordinator(
      avDevices: avDevices,
      halCandidates: [],
      logger: logger
    )
    if let session = avCoordinator.uniqueSelectedReadySession(
      command: command,
      named: requestedName
    ) {
      logger.debug("listening_mode.hal_inventory", "deferred")
      logger.info(
        "listening_mode.transport",
        session.transport.listeningModeTransportKind.rawValue
      )
      return .session(session)
    }

    logger.debug("listening_mode.hal_inventory", "loaded")
    let inventory = loadHAL()
    let coordinator = ListeningModeCoordinator(
      avDevices: avDevices,
      halCandidates: inventory.candidates,
      halDiscovery: inventory.discovery,
      logger: logger
    )
    return coordinator.resolve(
      command: command,
      named: requestedName,
      chooseAmbiguous: chooseAmbiguous
    )
  }
}

extension ListeningModeBootstrap.HALInventory {
  init(_ result: IOBluetoothStatusControllerCreationResult) {
    switch result {
    case let .success(controller):
      self.init(candidates: controller.listeningModeCandidates(), discovery: .available)
    case .unavailable:
      self.init(candidates: [], discovery: .unavailable)
    case .readError:
      self.init(candidates: [], discovery: .readError)
    }
  }
}
