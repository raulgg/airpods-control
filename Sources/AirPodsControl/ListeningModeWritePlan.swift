struct ListeningModeWritePlan {
  private let transport: any ListeningModeTransport
  private let availableModes: [ListeningMode]
  private let allowOffAuthorization: ListeningModeAllowOffAuthorization?
  private let authorizesHALOff: Bool

  init(
    transport: any ListeningModeTransport,
    availableModes: [ListeningMode],
    allowOffAuthorization: ListeningModeAllowOffAuthorization?
  ) {
    self.transport = transport
    self.availableModes = availableModes
    self.allowOffAuthorization = allowOffAuthorization
    authorizesHALOff = transport.listeningModeTransportKind == .hal
      && allowOffAuthorization != nil
  }

  func canWrite(_ target: ListeningMode) -> Bool {
    availableModes.contains(target)
  }

  func execute(_ target: ListeningMode) -> ListeningModeWriteResolution {
    precondition(canWrite(target), "write plan cannot execute an unavailable mode")
    let observation: DeviceWriteObservation<ListeningMode>
    if target == .off, authorizesHALOff {
      guard let allowOffTransport = transport as? any ListeningModeAllowOffTransport
      else {
        return resolveListeningModeWrite(
          requested: target,
          setterAccepted: false,
          observed: transport.currentListeningMode(),
          transparencySupported: false
        )
      }
      observation = allowOffTransport.setListeningModeAndReadBackAllowingOff(target)
    } else {
      observation = transport.setListeningModeAndReadBack(target)
    }
    if target == .off,
      authorizesHALOff,
      allowOffAuthorization?.cachedEvidence != nil,
      observation.setterAccepted,
      let observed = observation.observed,
      observed != .off
    {
      allowOffAuthorization?.invalidate()
    }
    return resolveListeningModeWrite(
      requested: target,
      setterAccepted: observation.setterAccepted,
      observed: observation.observed,
      transparencySupported: availableModes.contains(.transparency)
        && !authorizesHALOff
    )
  }
}
