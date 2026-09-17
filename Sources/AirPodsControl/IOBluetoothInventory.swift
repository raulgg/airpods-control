import CoreAudio

enum CoreAudioListeningModeObservation {
  case value(ListeningMode)
  case unavailable
  case unrecognized
  case conflict
  case readFailure
}

enum CoreAudioInEarPlacementObservation {
  case value(BluetoothEarPlacement)
  case unavailable
  case unknown
  case conflict
  case readFailure
}

private let recognizedAppleAudioManufacturers: Set<String> = [
  "Apple",
  "Apple Inc.",
  "Beats Electronics",
  "Beats Electronics LLC",
  "Beats Electronics, LLC",
]
private let maximumCoreAudioDeviceNameLength = 512

private enum AppleAudioAdmission: Equatable {
  case positive
  case unavailable
  case negative
}

private struct CoreAudioBluetoothEndpoint {
  let audioDeviceID: AudioDeviceID
  let bluetoothDevice: AnyObject
  let hasOutput: Bool
  let name: String?
  let appleAudioAdmission: AppleAudioAdmission
  let listeningMode: AudioRoutingRead<UInt32>
  let inEarPlacement: BluetoothEarPlacementRead
}

private struct CoreAudioBluetoothDeviceGroup {
  let equalityAnchor: AnyObject
  var endpoints: [CoreAudioBluetoothEndpoint]
}

struct IOBluetoothListeningModeBinding {
  let name: String
  let audioDeviceID: AudioDeviceID
  let bluetoothDevice: AnyObject
  let allowOffCorrelation: ListeningModeAllowOffCorrelation?
}

struct IOBluetoothInventoryResult {
  let devices: [IOBluetoothStatusDevice]
  let listeningModeBindings: [IOBluetoothListeningModeBinding]
}

struct IOBluetoothInventory {
  static func capture(
    audioDeviceIDs: [AudioDeviceID],
    runtime: any BluetoothAudioRuntime,
    routingBackend: any AudioRoutingBackend,
    routingObserver: AudioRoutingObserver,
    readStatusListeningMode: Bool,
    readStatusInEarPlacement: Bool,
    allowOffCache: (any ListeningModeAllowOffCaching)?,
    logger: DebugLogger
  ) -> IOBluetoothInventoryResult {
    var groups: [CoreAudioBluetoothDeviceGroup] = []
    var mappedEndpointCount = 0
    for (index, audioDeviceID) in audioDeviceIDs.enumerated() {
      guard let endpoint = captureEndpoint(
        index: index,
        audioDeviceID: audioDeviceID,
        runtime: runtime,
        routingBackend: routingBackend,
        readStatusListeningMode: readStatusListeningMode,
        readStatusInEarPlacement: readStatusInEarPlacement,
        logger: logger
      ) else { continue }

      mappedEndpointCount += 1
      if let groupIndex = groups.firstIndex(where: {
        bluetoothDevicesAreExactlyEqual($0.equalityAnchor, endpoint.bluetoothDevice)
      }) {
        groups[groupIndex].endpoints.append(endpoint)
      } else {
        groups.append(
          CoreAudioBluetoothDeviceGroup(
            equalityAnchor: endpoint.bluetoothDevice,
            endpoints: [endpoint]
          )
        )
      }
    }
    logger.info("bluetooth.mapped_endpoint_count", mappedEndpointCount)
    logger.info("bluetooth.mapped_device_count", groups.count)

    let devices = compatibleDevices(
      from: groups,
      runtime: runtime,
      routingObserver: routingObserver,
      logger: logger
    )
    let cacheCollisionAudioDeviceIDs = collisionAudioDeviceIDs(from: groups)
    let listeningModeBindings = listeningModeBindings(
      from: groups,
      cacheCollisionAudioDeviceIDs: cacheCollisionAudioDeviceIDs,
      routingBackend: routingBackend,
      allowOffCache: allowOffCache,
      logger: logger
    )
    logger.info("compatible_device_count", devices.count)
    return IOBluetoothInventoryResult(
      devices: devices,
      listeningModeBindings: listeningModeBindings
    )
  }

  private static func captureEndpoint(
    index: Int,
    audioDeviceID: AudioDeviceID,
    runtime: any BluetoothAudioRuntime,
    routingBackend: any AudioRoutingBackend,
    readStatusListeningMode: Bool,
    readStatusInEarPlacement: Bool,
    logger: DebugLogger
  ) -> CoreAudioBluetoothEndpoint? {
    let prefix = "core_audio.candidate_\(index)"

    let aggregateRead = routingBackend.isAggregateDevice(audioDeviceID)
    logBooleanRead(aggregateRead, key: "\(prefix).aggregate", logger: logger)
    guard case .value(false) = aggregateRead else {
      logger.debug("\(prefix).eligible", false)
      return nil
    }

    let transportRead = routingBackend.readTransportType(for: audioDeviceID)
    let isClassicBluetooth: Bool
    switch transportRead {
    case .value(kAudioDeviceTransportTypeBluetooth):
      isClassicBluetooth = true
      logger.debug("\(prefix).transport", "classic-bluetooth")
    case .value:
      isClassicBluetooth = false
      logger.debug("\(prefix).transport", "other")
    case .unavailable:
      isClassicBluetooth = false
      logger.debug("\(prefix).transport", "unavailable")
    case let .failure(status):
      isClassicBluetooth = false
      logger.debug("\(prefix).transport", "read-error")
      logger.debug("\(prefix).transport_error", status)
    }
    guard isClassicBluetooth else {
      logger.debug("\(prefix).eligible", false)
      return nil
    }

    let aliveRead = routingBackend.readDeviceIsAlive(audioDeviceID)
    logBooleanRead(aliveRead, key: "\(prefix).alive", logger: logger)
    guard case .value(true) = aliveRead else {
      logger.debug("\(prefix).eligible", false)
      return nil
    }

    let inputRead = routingBackend.readHasStreams(
      for: audioDeviceID,
      direction: .input
    )
    let outputRead = routingBackend.readHasStreams(
      for: audioDeviceID,
      direction: .output
    )
    let hasInput = positiveValue(inputRead)
    let hasOutput = positiveValue(outputRead)
    logBooleanRead(inputRead, key: "\(prefix).input_streams", logger: logger)
    logBooleanRead(outputRead, key: "\(prefix).output_streams", logger: logger)
    guard hasInput || hasOutput else {
      logger.debug("\(prefix).eligible", false)
      return nil
    }

    let appleAudioAdmission: AppleAudioAdmission
    switch routingBackend.readIsAppleAudioDevice(audioDeviceID) {
    case .value(true):
      appleAudioAdmission = .positive
      logger.debug("\(prefix).apple_audio_property", true)
    case .value(false):
      appleAudioAdmission = .negative
      logger.debug("\(prefix).apple_audio_property", false)
    case .unavailable:
      logger.debug("\(prefix).apple_audio_property", "unavailable")
      let manufacturerRead = routingBackend.readManufacturer(for: audioDeviceID)
      if case let .value(.some(manufacturer)) = manufacturerRead {
        let recognized = recognizedAppleAudioManufacturers.contains(manufacturer)
        appleAudioAdmission = recognized ? .positive : .unavailable
        logger.debug("\(prefix).apple_manufacturer", recognized)
      } else {
        appleAudioAdmission = .unavailable
        switch manufacturerRead {
        case .value:
          logger.debug("\(prefix).manufacturer", "available")
        case .unavailable:
          logger.debug("\(prefix).manufacturer", "unavailable")
        case let .failure(status):
          logger.debug("\(prefix).manufacturer", "read-error")
          logger.debug("\(prefix).manufacturer_error", status)
        }
      }
    case let .failure(status):
      appleAudioAdmission = .unavailable
      logger.debug("\(prefix).apple_audio_property", "read-error")
      logger.debug("\(prefix).apple_audio_property_error", status)
    }

    let bluetoothDevice: AnyObject
    switch runtime.bluetoothDevice(for: audioDeviceID) {
    case let .value(.some(value)):
      bluetoothDevice = value
      logger.debug("\(prefix).mapping", "available")
    case .value(nil), .unavailable:
      logger.debug("\(prefix).mapping", "unavailable")
      logger.debug("\(prefix).eligible", false)
      return nil
    case let .failure(status):
      logger.debug("\(prefix).mapping", "read-error")
      logger.debug("\(prefix).mapping_error", status)
      logger.debug("\(prefix).eligible", false)
      return nil
    }

    let name = appleAudioAdmission == .positive
      ? usableName(routingBackend.readName(for: audioDeviceID))
      : nil
    let listeningModeRead: AudioRoutingRead<UInt32> = readStatusListeningMode
      ? routingBackend.readBluetoothListeningMode(for: audioDeviceID)
      : .unavailable
    switch listeningModeRead {
    case let .value(listeningMode):
      logger.debug("\(prefix).listening_mode", "available")
      logger.debug(
        "\(prefix).recognized_listening_mode",
        BluetoothListeningModeMapping.modeByRawValue[listeningMode] != nil
      )
    case .unavailable:
      logger.debug("\(prefix).listening_mode", "unavailable")
    case let .failure(status):
      logger.debug("\(prefix).listening_mode", "read-error")
      logger.debug("\(prefix).listening_mode_error", status)
    }
    let inEarPlacementRead: BluetoothEarPlacementRead = readStatusInEarPlacement
      ? routingBackend.readBluetoothInEarPlacement(for: audioDeviceID)
      : .unavailable
    switch inEarPlacementRead {
    case .value:
      logger.debug("\(prefix).in_ear_placement", "available")
    case .unavailable:
      logger.debug("\(prefix).in_ear_placement", "unavailable")
    case .unknown:
      logger.debug("\(prefix).in_ear_placement", "unknown")
    case let .failure(status):
      logger.debug("\(prefix).in_ear_placement", "read-error")
      logger.debug("\(prefix).in_ear_placement_error", status)
    }
    logger.debug("\(prefix).name_available", name != nil)
    logger.debug("\(prefix).eligible", appleAudioAdmission == .positive)
    return CoreAudioBluetoothEndpoint(
      audioDeviceID: audioDeviceID,
      bluetoothDevice: bluetoothDevice,
      hasOutput: hasOutput,
      name: name,
      appleAudioAdmission: appleAudioAdmission,
      listeningMode: listeningModeRead,
      inEarPlacement: inEarPlacementRead
    )
  }

  private static func compatibleDevices(
    from groups: [CoreAudioBluetoothDeviceGroup],
    runtime: any BluetoothAudioRuntime,
    routingObserver: AudioRoutingObserver,
    logger: DebugLogger
  ) -> [IOBluetoothStatusDevice] {
    groups.compactMap { group in
      guard !group.endpoints.contains(where: {
        $0.appleAudioAdmission == .negative
      }) else {
        logger.debug("bluetooth.apple_audio_consistency", "conflict")
        return nil
      }
      let positiveEndpoints = group.endpoints.filter {
        $0.appleAudioAdmission == .positive
      }
      let endpoints = positiveEndpoints.filter(\.hasOutput)
        + positiveEndpoints.filter { !$0.hasOutput }
      guard let primary = endpoints.first,
            let namedEndpoint = endpoints.first(where: { $0.name != nil }),
            let name = namedEndpoint.name
      else { return nil }
      return IOBluetoothStatusDevice(
        object: primary.bluetoothDevice,
        name: name,
        coreAudioListeningMode: resolveListeningMode(
          from: group.endpoints,
          logger: logger
        ),
        coreAudioInEarPlacement: resolveInEarPlacement(
          from: group.endpoints,
          logger: logger
        ),
        runtime: runtime,
        routingObserver: routingObserver
      )
    }
  }

  private static func collisionAudioDeviceIDs(
    from groups: [CoreAudioBluetoothDeviceGroup]
  ) -> [AudioDeviceID] {
    groups.flatMap { group -> [AudioDeviceID] in
      guard !group.endpoints.contains(where: {
        $0.appleAudioAdmission == .negative
      }) else { return [] }
      return group.endpoints.filter {
        $0.appleAudioAdmission == .positive && $0.hasOutput
      }.map(\.audioDeviceID)
    }
  }

  private static func listeningModeBindings(
    from groups: [CoreAudioBluetoothDeviceGroup],
    cacheCollisionAudioDeviceIDs: [AudioDeviceID],
    routingBackend: any AudioRoutingBackend,
    allowOffCache: (any ListeningModeAllowOffCaching)?,
    logger: DebugLogger
  ) -> [IOBluetoothListeningModeBinding] {
    groups.compactMap { group in
      guard !group.endpoints.contains(where: {
        $0.appleAudioAdmission == .negative
      }) else { return nil }
      let outputEndpoints = group.endpoints.filter {
        $0.appleAudioAdmission == .positive && $0.hasOutput
      }
      let controlEndpoints = outputEndpoints.filter {
        routingBackend.hasBluetoothListeningMode(for: $0.audioDeviceID)
      }
      guard let namedEndpoint = outputEndpoints.first(where: { $0.name != nil }),
            let outputEndpoint =
            controlEndpoints.first(where: { $0.name != nil })
              ?? controlEndpoints.first,
              let name = namedEndpoint.name
      else { return nil }
      return IOBluetoothListeningModeBinding(
        name: name,
        audioDeviceID: outputEndpoint.audioDeviceID,
        bluetoothDevice: outputEndpoint.bluetoothDevice,
        allowOffCorrelation: {
          guard outputEndpoints.count == 1, let allowOffCache else { return nil }
          return ListeningModeAllowOffCorrelation(
            targetAudioDeviceID: outputEndpoint.audioDeviceID,
            collisionAudioDeviceIDs: cacheCollisionAudioDeviceIDs,
            backend: routingBackend,
            cache: allowOffCache,
            logger: logger
          )
        }()
      )
    }
  }

  private static func positiveValue(_ read: AudioRoutingRead<Bool>) -> Bool {
    if case .value(true) = read { return true }
    return false
  }

  private static func usableName(
    _ read: AudioRoutingRead<String?>
  ) -> String? {
    guard case let .value(.some(value)) = read,
          !value.isEmpty,
          value.unicodeScalars.count <= maximumCoreAudioDeviceNameLength
    else { return nil }
    return value
  }

  private static func logBooleanRead(
    _ read: AudioRoutingRead<Bool>,
    key: String,
    logger: DebugLogger
  ) {
    switch read {
    case let .value(value): logger.debug(key, value)
    case .unavailable: logger.debug(key, "unavailable")
    case let .failure(status):
      logger.debug(key, "read-error")
      logger.debug("\(key)_error", status)
    }
  }

  private static func resolveListeningMode(
    from endpoints: [CoreAudioBluetoothEndpoint],
    logger: DebugLogger
  ) -> CoreAudioListeningModeObservation {
    var recognizedModes: Set<ListeningMode> = []
    var sawReadFailure = false
    var sawUnrecognizedMode = false
    for endpoint in endpoints {
      switch endpoint.listeningMode {
      case let .value(rawValue):
        if let mode = BluetoothListeningModeMapping.modeByRawValue[rawValue] {
          recognizedModes.insert(mode)
        } else if rawValue != 0 {
          sawUnrecognizedMode = true
        }
      case .unavailable:
        break
      case .failure:
        sawReadFailure = true
      }
    }
    if recognizedModes.count > 1 {
      logger.debug("bluetooth.listening_mode_consistency", "conflict")
      return .conflict
    }
    if sawUnrecognizedMode {
      logger.debug("bluetooth.listening_mode_consistency", "unrecognized")
      return .unrecognized
    }
    if let mode = recognizedModes.first { return .value(mode) }
    if sawReadFailure {
      logger.debug("bluetooth.listening_mode_consistency", "read-error")
      return .readFailure
    }
    return .unavailable
  }

  private static func resolveInEarPlacement(
    from endpoints: [CoreAudioBluetoothEndpoint],
    logger: DebugLogger
  ) -> CoreAudioInEarPlacementObservation {
    var recognizedPlacements: Set<BluetoothEarPlacement> = []
    var sawUnknown = false
    for endpoint in endpoints {
      switch endpoint.inEarPlacement {
      case let .value(placement): recognizedPlacements.insert(placement)
      case .unavailable: break
      case .unknown: sawUnknown = true
      case .failure:
        logger.debug("bluetooth.in_ear_placement_consistency", "read-error")
        return .readFailure
      }
    }
    if recognizedPlacements.count > 1 {
      logger.debug("bluetooth.in_ear_placement_consistency", "conflict")
      return .conflict
    }
    if sawUnknown {
      logger.debug("bluetooth.in_ear_placement_consistency", "unknown")
      return .unknown
    }
    if let placement = recognizedPlacements.first {
      return .value(placement)
    }
    return .unavailable
  }
}
