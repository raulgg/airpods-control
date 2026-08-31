struct ListeningModeWritePlan {
  private let transport: any ListeningModeTransport
  private let allowOffTransport: (any ListeningModeAllowOffTransport)?
  private let availableModes: [ListeningMode]
  private let allowOffAuthorization: ListeningModeAllowOffAuthorization?
  private let allowsOffProbe: Bool
  private let allowOffCorrelation: ListeningModeAllowOffCorrelation?
  private let authorizesHALOff: Bool

  init(
    transport: any ListeningModeTransport,
    availableModes: [ListeningMode],
    allowOffAuthorization: ListeningModeAllowOffAuthorization?,
    allowsOffProbe: Bool = false,
    allowOffCorrelation: ListeningModeAllowOffCorrelation? = nil
  ) {
    let allowOffTransport = transport as? any ListeningModeAllowOffTransport
    self.transport = transport
    self.allowOffTransport = allowOffTransport
    self.availableModes = availableModes
    self.allowOffAuthorization = allowOffAuthorization
    self.allowsOffProbe = allowsOffProbe
    self.allowOffCorrelation = allowOffCorrelation
    authorizesHALOff = transport.listeningModeTransportKind == .hal
      && allowOffTransport != nil
      && (allowOffAuthorization != nil || allowsOffProbe)
  }

  func canWrite(_ target: ListeningMode) -> Bool {
    guard availableModes.contains(target) else { return false }
    guard target != .off || transport.listeningModeTransportKind != .hal else {
      return authorizesHALOff
    }
    return true
  }

  func execute(_ target: ListeningMode) -> ListeningModeWriteResolution {
    precondition(canWrite(target), "write plan cannot execute an unavailable mode")
    let observation: DeviceWriteObservation<ListeningMode>
    let isProbe = target == .off && allowsOffProbe && allowOffAuthorization == nil
    let observedAt = target == .off
      ? allowOffCorrelation?.captureObservationTime()
      : nil
    if target == .off, authorizesHALOff {
      guard let allowOffTransport else {
        return resolveListeningModeWrite(
          requested: target,
          setterAccepted: false,
          observed: transport.currentListeningMode(),
          transparencySupported: false,
          probeDenied: false
        )
      }
      observation = allowOffTransport.setListeningModeAndReadBackAllowingOff(target)
    } else {
      observation = transport.setListeningModeAndReadBack(target)
    }
    let probeDenied = isProbe
      && observation.setterAccepted
      && observation.observed != nil
      && observation.observed != .off
    if target == .off, observation.setterAccepted, let observedAt {
      if observation.observed == .off {
        allowOffCorrelation?.observeCurrentOff(observedAt: observedAt)
      } else if observation.observed != nil {
        allowOffCorrelation?.observeDenial(observedAt: observedAt)
      }
    }
    if target == .off,
      allowOffAuthorization != nil,
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
        && !authorizesHALOff,
      probeDenied: probeDenied
    )
  }
}
