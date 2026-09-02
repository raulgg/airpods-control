import Foundation

enum BluetoothCommandKind {
  case setup
  case status
  case disable
  case enroll
  case unenroll

  init?(_ command: CLICommand) {
    switch command {
    case .bluetoothSetup: self = .setup
    case .bluetoothStatus: self = .status
    case .bluetoothDisable: self = .disable
    case .bluetoothEnroll: self = .enroll
    case .bluetoothUnenroll: self = .unenroll
    case .version, .status, .supportReport,
      .listeningModeGet, .listeningModeSet, .listeningModeList,
      .listeningModeCycle, .conversationAwarenessGet,
      .conversationAwarenessSet:
      return nil
    }
  }
}

enum BluetoothCommand {
  static func outcome(
    invocation: CLIInvocation,
    store: any BluetoothAssociationStoring,
    scanner: any BluetoothScanning,
    resolveStatusInventory: () -> (
      devices: [IOBluetoothStatusDevice],
      correlation: (IOBluetoothStatusDevice) -> BluetoothEndpointCorrelation?
    ),
    interactive: Bool,
    readResponse: () -> String?,
    writePrompt: (String) -> Void
  ) -> CommandOutcome {
    guard let command = BluetoothCommandKind(invocation.command) else {
      preconditionFailure("BluetoothCommand requires a bluetooth command")
    }
    switch command {
    case .setup:
      return setup(store: store, scanner: scanner)
    case .status:
      return status(store: store, scanner: scanner)
    case .disable:
      return disable(store: store)
    case .enroll:
      guard let name = invocation.requestedDeviceName else {
        return error("bad-args", reason: .badArgs)
      }
      return enroll(
        name: name,
        store: store,
        scanner: scanner,
        resolveStatusInventory: resolveStatusInventory,
        interactive: interactive,
        readResponse: readResponse,
        writePrompt: writePrompt
      )
    case .unenroll:
      guard let name = invocation.requestedDeviceName else {
        return error("bad-args", reason: .badArgs)
      }
      return unenroll(name: name, store: store)
    }
  }

  private static func setup(
    store: any BluetoothAssociationStoring,
    scanner: any BluetoothScanning
  ) -> CommandOutcome {
    guard var document = mutableDocument(from: store.load()) else {
      return settingsError()
    }
    document.enabled = true
    guard save(document, to: store) else { return settingsError() }
    let result = scanner.requestAuthorization(timeout: 30)
    let plain = "enabled\nBluetooth permission: \(result.authorization.rawValue)"
    return CommandOutcome(
      plain: plain,
      data: [
        "authorization": result.authorization.rawValue,
        "enabled": true,
      ]
    )
  }

  private static func status(
    store: any BluetoothAssociationStoring,
    scanner: any BluetoothScanning
  ) -> CommandOutcome {
    let document: BluetoothSettingsDocument
    switch store.load() {
    case .missing:
      document = .empty(enabled: false)
    case let .value(value):
      document = value
    case .invalid:
      return settingsError()
    }
    let authorization = scanner.authorization()
    let radio = scanner.radioState()
    let learningIncomplete = document.candidates.contains {
      $0.expiresAt > Date()
    }
    let associationPayloads: [[String: Any]] = document.associations.map {
      association in
      [
        "device": association.displayName,
        "product": AppleAudioProducts.hexProductID(association.productID),
        "provenance": association.provenance.rawValue,
      ]
    }
    var lines = [
      "Enabled: \(document.enabled ? "yes" : "no")",
      "Bluetooth permission: \(authorization.rawValue)",
    ]
    if let radio { lines.append("Bluetooth radio: \(radio.rawValue)") }
    lines.append(
      "Enrollment in progress: \(learningIncomplete ? "yes" : "no")"
    )
    if document.associations.isEmpty {
      lines.append("Enrolled accessories: none")
    } else {
      lines.append("Enrolled accessories:")
      for association in document.associations {
        lines.append(
          "  \(SafeTerminalText.escaped(association.displayName)) "
            + "(\(AppleAudioProducts.hexProductID(association.productID)), "
            + "\(association.provenance.rawValue))"
        )
      }
    }
    var data: [String: Any] = [
      "authorization": authorization.rawValue,
      "enabled": document.enabled,
      "enrolledAccessories": associationPayloads,
      "learningIncomplete": learningIncomplete,
    ]
    if let radio { data["radio"] = radio.rawValue }
    return CommandOutcome(
      plain: lines.joined(separator: "\n"),
      data: data
    )
  }

  private static func disable(
    store: any BluetoothAssociationStoring
  ) -> CommandOutcome {
    guard var document = mutableDocument(from: store.load()) else {
      return settingsError()
    }
    document.enabled = false
    guard save(document, to: store) else { return settingsError() }
    return CommandOutcome(
      plain: "disabled",
      data: ["enabled": false]
    )
  }

  private static func unenroll(
    name: String,
    store: any BluetoothAssociationStoring
  ) -> CommandOutcome {
    guard let document = mutableDocument(from: store.load()) else {
      return settingsError()
    }
    switch document.unenrolling(name: name) {
    case .notEnrolled:
      return error("not-enrolled", reason: .noDevice)
    case .ambiguous:
      return error("ambiguous-device", reason: .ambiguousDevice)
    case let .unenrolled(updated):
      guard save(updated, to: store) else { return settingsError() }
      return CommandOutcome(
        plain: "unenrolled",
        data: ["device": name]
      )
    }
  }

  private static func enroll(
    name: String,
    store: any BluetoothAssociationStoring,
    scanner: any BluetoothScanning,
    resolveStatusInventory: () -> (
      devices: [IOBluetoothStatusDevice],
      correlation: (IOBluetoothStatusDevice) -> BluetoothEndpointCorrelation?
    ),
    interactive: Bool,
    readResponse: () -> String?,
    writePrompt: (String) -> Void
  ) -> CommandOutcome {
    guard interactive else {
      return error("interactive-terminal-required", reason: .unavailable)
    }
    guard var document = mutableDocument(from: store.load()) else {
      return settingsError()
    }
    guard document.enabled else {
      return error("bluetooth-disabled", reason: .unavailable)
    }
    guard scanner.authorization() == .authorized else {
      return error("bluetooth-permission", reason: .unavailable)
    }

    let firstInventory = resolveStatusInventory()
    guard let firstTarget = exactTarget(
      name: name,
      devices: firstInventory.devices,
      bluetoothCorrelation: firstInventory.correlation,
      document: document
    ), case let .value(firstHAL) = firstTarget.placement else {
      return error("placement-unavailable", reason: .unavailable)
    }
    let firstScan = scanner.scan(
      duration: BluetoothScan.duration
    )
    guard let firstBLE = uniqueMatchingObservation(
      productID: firstTarget.productID,
      placement: firstHAL,
      scan: firstScan
    ) else {
      return error("bluetooth-observation-unavailable", reason: .unavailable)
    }

    writePrompt(
      "Move exactly one earbud so one is in ear and the other is out, "
        + "then press Return: "
    )
    guard readResponse() != nil else {
      return error("cancelled", reason: .unavailable)
    }

    let secondInventory = resolveStatusInventory()
    guard let secondTarget = exactTarget(
      name: name,
      devices: secondInventory.devices,
      bluetoothCorrelation: secondInventory.correlation,
      document: document
    ), case let .value(secondHAL) = secondTarget.placement,
      secondHAL.left != secondHAL.right,
      secondHAL != firstHAL,
      secondTarget.productID == firstTarget.productID,
      secondTarget.coreAudioUIDDigests == firstTarget.coreAudioUIDDigests
    else {
      return error("asymmetric-transition-required", reason: .unavailable)
    }
    let secondScan = scanner.scan(
      duration: BluetoothScan.duration
    )
    guard let secondBLE = uniqueMatchingObservation(
      productID: secondTarget.productID,
      placement: secondHAL,
      scan: secondScan
    ), secondBLE.peripheralIdentifier == firstBLE.peripheralIdentifier else {
      return error("bluetooth-identity-conflict", reason: .unavailable)
    }

    guard let enrolled = document.recordingVerified(
      target: firstTarget,
      peripheralIdentifier: firstBLE.peripheralIdentifier
    ) else {
      return error("bluetooth-identity-conflict", reason: .unavailable)
    }
    document = enrolled
    document.candidates.removeAll {
      $0.productID == firstTarget.productID
        && BluetoothSettingsDocument.namesMatch(
          $0.displayName,
          firstTarget.name
        )
    }
    guard save(document, to: store) else { return settingsError() }
    return CommandOutcome(
      plain: "enrolled",
      data: [
        "device": firstTarget.name,
        "provenance": BluetoothAssociationProvenance.userVerified.rawValue,
      ]
    )
  }

  private static func exactTarget(
    name: String,
    devices: [IOBluetoothStatusDevice],
    bluetoothCorrelation: (IOBluetoothStatusDevice) -> BluetoothEndpointCorrelation?,
    document: BluetoothSettingsDocument
  ) -> BluetoothCorrelationTarget? {
    let matches = devices.filter {
      guard let deviceName = $0.name else { return false }
      return BluetoothSettingsDocument.namesMatch(deviceName, name)
    }
    guard matches.count == 1,
          let device = matches.first,
          let targetName = device.name,
          let correlation = bluetoothCorrelation(device)
    else {
      return nil
    }
    return document.correlationTarget(
      name: targetName,
      productID: correlation.productID,
      coreAudioUIDs: correlation.coreAudioUIDs,
      placement: device.readInEarPlacementStatus()
    )
  }

  private static func uniqueMatchingObservation(
    productID: Int,
    placement: BluetoothEarPlacement,
    scan: BluetoothScanResult
  ) -> BluetoothPeripheralObservation? {
    guard scan.authorization == .authorized, scan.radio == .poweredOn else {
      return nil
    }
    let candidates = AirPodsBLEScanNormalizer.normalize(scan.advertisements).filter {
      $0.productID == productID
    }
    guard candidates.count == 1, candidates[0].placement == placement else {
      return nil
    }
    return candidates[0]
  }

  private static func mutableDocument(
    from result: BluetoothSettingsLoadResult
  ) -> BluetoothSettingsDocument? {
    switch result {
    case .missing: return .empty(enabled: false)
    case let .value(document): return document
    case .invalid: return nil
    }
  }

  private static func save(
    _ document: BluetoothSettingsDocument,
    to store: any BluetoothAssociationStoring
  ) -> Bool {
    do {
      try store.save(document)
      return true
    } catch {
      return false
    }
  }

  private static func settingsError() -> CommandOutcome {
    error("bluetooth-settings", reason: .unavailable)
  }

  private static func error(
    _ detail: String,
    reason: TerminalReason
  ) -> CommandOutcome {
    CommandOutcome(
      plain: detail,
      terminalReason: reason,
      data: ["detail": detail]
    )
  }
}
