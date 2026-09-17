struct ListeningModeWritePlan {
  private let transport: any ListeningModeTransport
  private let allowOffTransport: (any ListeningModeAllowOffTransport)?
  private let availableModes: [ListeningMode]
  private let offPermission: ListeningModeOffPermission?
  private let allowOffCorrelation: ListeningModeAllowOffCorrelation?
  private let authorizesHALOff: Bool

  init(
    transport: any ListeningModeTransport,
    availableModes: [ListeningMode],
    offPermission: ListeningModeOffPermission?,
    allowOffCorrelation: ListeningModeAllowOffCorrelation? = nil
  ) {
    let allowOffTransport = transport as? any ListeningModeAllowOffTransport
    self.transport = transport
    self.allowOffTransport = allowOffTransport
    self.availableModes = availableModes
    self.offPermission = offPermission
    self.allowOffCorrelation = allowOffCorrelation
    let permitsOff: Bool
    switch offPermission {
    case .authorized, .probe: permitsOff = true
    case .none: permitsOff = false
    }
    authorizesHALOff = transport.listeningModeTransportKind == .hal
      && allowOffTransport != nil
      && permitsOff
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
    let isProbe = target == .off && isProbePermission
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
       case let .authorized(authorization)? = offPermission,
       observation.setterAccepted,
       let observed = observation.observed,
       observed != .off
    {
      authorization.invalidate()
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

  private var isProbePermission: Bool {
    switch offPermission {
    case .probe: return true
    case .authorized, .none: return false
    }
  }
}
