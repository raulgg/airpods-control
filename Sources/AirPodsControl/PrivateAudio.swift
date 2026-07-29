import Darwin
import Foundation

private let listeningModeRawValues: [ListeningMode: String] = [
  .off: "AVOutputDeviceBluetoothListeningModeNormal",
  .transparency: "AVOutputDeviceBluetoothListeningModeAudioTransparency",
  .adaptive: "AVOutputDeviceBluetoothListeningModeAutomatic",
  .noiseCancellation: "AVOutputDeviceBluetoothListeningModeActiveNoiseCancellation",
]
private let listeningModesByRawValue = Dictionary(
  uniqueKeysWithValues: listeningModeRawValues.map { ($1, $0) }
)

private let standardWriteReadbackAttempts = 16
private let offListeningModeReadbackAttempts = 30
private let privateAudioReadbackDelay: useconds_t = 50_000

// AVFoundation delivers route-state changes through the main run loop. A
// blocking sleep can leave the output-device snapshot stale until process exit.
private func waitForPrivateAudioUpdate(_ microseconds: useconds_t) {
  let interval = TimeInterval(microseconds) / 1_000_000
  RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
}

private let nameSelector = NSSelectorFromString("name")
private let availableModesSelector = NSSelectorFromString("availableBluetoothListeningModes")
private let currentModeSelector = NSSelectorFromString("currentBluetoothListeningMode")
private let setModeSelector = NSSelectorFromString("setCurrentBluetoothListeningMode:error:")
private let supportsCASelector = NSSelectorFromString("supportsConversationDetection")
private let caEnabledSelector = NSSelectorFromString("isConversationDetectionEnabled")
private let setCASelector = NSSelectorFromString("setConversationDetectionEnabled:error:")
private let modelIDSelector = NSSelectorFromString("modelID")

@objc private protocol ListeningModeSetterShim {
  @objc(setCurrentBluetoothListeningMode:error:)
  func setListeningMode(_ mode: String, _ error: NSErrorPointer) -> Bool
}

@objc private protocol ConversationAwarenessSupportShim {
  @objc(supportsConversationDetection) func supportsConversationAwareness() -> Bool
}

@objc private protocol ConversationAwarenessStateShim {
  @objc(isConversationDetectionEnabled) func conversationAwarenessEnabled() -> Bool
}

@objc private protocol ConversationAwarenessSetterShim {
  @objc(setConversationDetectionEnabled:error:)
  func setConversationAwareness(_ enabled: Bool, _ error: NSErrorPointer) -> Bool
}

enum PrivateAudioDiscovery {
  static let contextSelectors = ["sharedSystemAudioContext", "sharedSystemAudio"]

  static func sharedContext(from provider: AnyObject, logger: DebugLogger) -> AnyObject? {
    for selectorName in contextSelectors {
      let selector = NSSelectorFromString(selectorName)
      let available = provider.responds(to: selector)
      logger.debug("selector.\(selectorName)", available ? "available" : "unavailable")
      guard available else { continue }
      guard let value = provider.perform(selector)?.takeUnretainedValue() else {
        logger.warning("selector.\(selectorName)", "returned-null")
        continue
      }
      logger.info("audio_context_selector", selectorName)
      return value as AnyObject
    }
    logger.warning("audio_context", "unavailable")
    return nil
  }

  static func outputDevices(from context: AnyObject, logger: DebugLogger) -> [AnyObject]? {
    let selector = NSSelectorFromString("outputDevices")
    guard context.responds(to: selector) else {
      logger.warning("selector.outputDevices", "unavailable")
      return nil
    }
    guard let value = context.perform(selector)?.takeUnretainedValue(),
          let devices = value as? [AnyObject]
    else {
      logger.warning("selector.outputDevices", "returned-invalid-value")
      return nil
    }
    logger.info("output_device_count", devices.count)
    return devices
  }

  static func systemOutputDevices(logger: DebugLogger) -> [AnyObject]? {
    let frameworks = [
      "/System/Library/Frameworks/AVFoundation.framework/AVFoundation",
      "/System/Library/Frameworks/AVRouting.framework/AVRouting",
    ]

    for framework in frameworks {
      dlerror()
      if dlopen(framework, RTLD_NOW) != nil {
        logger.debug("framework", "\(framework):loaded")
      } else {
        let error = dlerror().map { String(cString: $0) } ?? "unknown-error"
        logger.warning("framework", "\(framework):\(error)")
      }
    }

    guard let cls = NSClassFromString("AVOutputContext") else {
      logger.warning("class.AVOutputContext", "unavailable")
      return nil
    }
    logger.debug("class.AVOutputContext", "available")

    guard let context = sharedContext(from: cls as AnyObject, logger: logger) else {
      return nil
    }
    return outputDevices(from: context, logger: logger)
  }
}

final class PrivateAudioDevice: CompatibleAudioDevice {
  private let object: AnyObject
  let name: String?
  private let logger: DebugLogger

  private init(object: AnyObject, name: String?, logger: DebugLogger) {
    self.object = object
    self.name = name
    self.logger = logger
  }

  private func allowlistedString(
    selector: Selector,
    label: String,
    maximumLength: Int
  ) -> String? {
    guard object.responds(to: selector),
          let value = object.perform(selector)?.takeUnretainedValue() as? String
    else {
      logger.debug("selector.\(label)", "unavailable")
      return nil
    }
    return SupportReportSnapshot.normalizedMetadataValue(value, maximumLength: maximumLength)
  }

  func supportReportMetadata() -> SupportReportDeviceMetadata {
    let modelIdentifier = allowlistedString(
      selector: modelIDSelector,
      label: "modelID",
      maximumLength: SupportReportSnapshot.maximumModelIdentifierLength
    )
    let unrecognizedModes = availableRawListeningModes().filter {
      listeningModesByRawValue[$0] == nil
    }
    return SupportReportDeviceMetadata(
      family: AppleAudioProducts.family(for: modelIdentifier),
      modelIdentifier: modelIdentifier,
      unrecognizedListeningModes: unrecognizedModes,
      listeningModeQueryAnswered: currentRawListeningMode() != nil
    )
  }

  static func compatible(
    object: AnyObject,
    index: Int,
    logger: DebugLogger,
    includeDeviceName: Bool = true
  ) -> PrivateAudioDevice? {
    let requiredSelectors = [nameSelector, availableModesSelector, currentModeSelector]
    for selector in requiredSelectors where !object.responds(to: selector) {
      logger.debug("device.\(index).missing_selector", NSStringFromSelector(selector))
      return nil
    }

    // The name selector stays uninvoked unless the caller wants the name, so
    // the device keeps no name at all rather than a blank one.
    var name: String?
    if includeDeviceName {
      guard let nameValue = object.perform(nameSelector)?.takeUnretainedValue(),
            let value = nameValue as? String,
            !value.isEmpty
      else {
        logger.debug("device.\(index).name", "unavailable")
        return nil
      }
      logger.debug("device.\(index).name", value)
      name = value
    }

    guard let modesValue = object.perform(availableModesSelector)?.takeUnretainedValue(),
          let modes = modesValue as? [String],
          !modes.isEmpty
    else {
      logger.debug("device.\(index).compatible", false)
      return nil
    }

    logger.debug("device.\(index).compatible", true)
    logger.debug("device.\(index).available_modes", modes.joined(separator: ","))
    return PrivateAudioDevice(object: object, name: name, logger: logger)
  }

  private func availableRawListeningModes() -> [String] {
    guard object.responds(to: availableModesSelector),
          let value = object.perform(availableModesSelector)?.takeUnretainedValue(),
          let modes = value as? [String]
    else {
      logger.warning("selector.availableBluetoothListeningModes", "unavailable")
      return []
    }
    logger.debug("device.available_modes", modes.joined(separator: ","))
    return modes
  }

  func availableListeningModes() -> [ListeningMode] {
    availableRawListeningModes().compactMap { listeningModesByRawValue[$0] }
  }

  private func currentRawListeningMode() -> String? {
    guard object.responds(to: currentModeSelector),
          let value = object.perform(currentModeSelector)?.takeUnretainedValue(),
          let mode = value as? String
    else {
      logger.warning("selector.currentBluetoothListeningMode", "unavailable")
      return nil
    }
    logger.debug("device.current_mode", mode)
    return mode
  }

  func currentListeningMode() -> ListeningMode? {
    currentRawListeningMode().flatMap { listeningModesByRawValue[$0] }
  }

  func canSetListeningMode() -> Bool {
    let available = object.responds(to: setModeSelector)
    logger.debug("selector.setCurrentBluetoothListeningMode:error:", available)
    return available
  }

  private func logSetterError(_ error: NSError?, key: String) {
    guard let error else { return }
    // Framework-supplied error strings are not part of the pasteable debug
    // stream. The numeric code is bounded and the log key supplies context.
    logger.warning(key, error.code)
  }

  private func setRawListeningMode(_ mode: String) -> Bool? {
    guard canSetListeningMode() else { return nil }
    var error: NSError?
    let setter = unsafeBitCast(object, to: ListeningModeSetterShim.self)
    let accepted = setter.setListeningMode(mode, &error)
    logger.debug("write.listening_mode.accepted", accepted)
    logSetterError(error, key: "write.listening_mode.error")
    return accepted
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode
  ) -> DeviceWriteObservation<ListeningMode> {
    setListeningModeAndReadBack(target, wait: waitForPrivateAudioUpdate)
  }

  func settle(for interval: TimeInterval) {
    waitForPrivateAudioUpdate(useconds_t(interval * 1_000_000))
  }

  func setListeningModeAndReadBack(
    _ target: ListeningMode,
    wait: (useconds_t) -> Void
  ) -> DeviceWriteObservation<ListeningMode> {
    let rawTarget = listeningModeRawValues[target]!
    let settleThroughDeadline = target == .off
    let attemptLimit = settleThroughDeadline
      ? offListeningModeReadbackAttempts
      : standardWriteReadbackAttempts

    let setterAccepted = setRawListeningMode(rawTarget) == true
    var observedRawMode = currentRawListeningMode()
    logger.debug("verify.listening_mode.attempt", 0)

    if observedRawMode != rawTarget || settleThroughDeadline {
      for attempt in 1...attemptLimit {
        wait(privateAudioReadbackDelay)
        observedRawMode = currentRawListeningMode()
        logger.debug("verify.listening_mode.attempt", attempt)
        if observedRawMode == rawTarget, !settleThroughDeadline { break }
      }
    }

    return DeviceWriteObservation(
      setterAccepted: setterAccepted,
      observed: observedRawMode.flatMap { listeningModesByRawValue[$0] }
    )
  }

  func supportsConversationAwareness() -> Bool? {
    guard object.responds(to: supportsCASelector) else {
      logger.debug("selector.supportsConversationDetection", "unavailable")
      return nil
    }
    let shim = unsafeBitCast(object, to: ConversationAwarenessSupportShim.self)
    let supported = shim.supportsConversationAwareness()
    logger.debug("device.supports_conversation_awareness", supported)
    return supported
  }

  func conversationAwarenessState() -> Bool? {
    guard object.responds(to: caEnabledSelector) else {
      logger.debug("selector.isConversationDetectionEnabled", "unavailable")
      return nil
    }
    let shim = unsafeBitCast(object, to: ConversationAwarenessStateShim.self)
    let enabled = shim.conversationAwarenessEnabled()
    logger.debug("device.conversation_awareness", enabled ? "on" : "off")
    return enabled
  }

  func canSetConversationAwareness() -> Bool {
    let available = object.responds(to: setCASelector)
    logger.debug("selector.setConversationDetectionEnabled:error:", available)
    return available
  }

  private func setConversationAwareness(_ enabled: Bool) -> Bool? {
    guard canSetConversationAwareness() else { return nil }
    var error: NSError?
    let setter = unsafeBitCast(object, to: ConversationAwarenessSetterShim.self)
    let accepted = setter.setConversationAwareness(enabled, &error)
    logger.debug("write.conversation_awareness.accepted", accepted)
    logSetterError(error, key: "write.conversation_awareness.error")
    return accepted
  }

  func setConversationAwarenessAndReadBack(
    _ target: Bool
  ) -> DeviceWriteObservation<Bool> {
    setConversationAwarenessAndReadBack(target, wait: waitForPrivateAudioUpdate)
  }

  func setConversationAwarenessAndReadBack(
    _ target: Bool,
    wait: (useconds_t) -> Void
  ) -> DeviceWriteObservation<Bool> {
    let setterAccepted = setConversationAwareness(target) == true
    var observed = conversationAwarenessState()
    logger.debug("verify.conversation_awareness.attempt", 0)

    if observed != target {
      for attempt in 1...standardWriteReadbackAttempts {
        wait(privateAudioReadbackDelay)
        observed = conversationAwarenessState()
        logger.debug("verify.conversation_awareness.attempt", attempt)
        if observed == target { break }
      }
    }

    return DeviceWriteObservation(
      setterAccepted: setterAccepted,
      observed: observed
    )
  }
}

final class PrivateAudioController {
  private let devices: [PrivateAudioDevice]
  private let logger: DebugLogger
  private let includesDeviceNames: Bool

  init(
    rawDevices: [AnyObject],
    logger: DebugLogger,
    includeDeviceNames: Bool = true
  ) {
    self.logger = logger
    includesDeviceNames = includeDeviceNames
    devices = rawDevices.enumerated().compactMap { index, object in
      PrivateAudioDevice.compatible(
        object: object,
        index: index,
        logger: logger,
        includeDeviceName: includeDeviceNames
      )
    }
    logger.info("compatible_device_count", devices.count)
  }

  func selectDevice(named requestedName: String?) -> PrivateAudioDevice? {
    guard let requestedName else {
      if !includesDeviceNames, devices.count != 1 {
        logger.warning("device_selection", "unique-name-free-device-required")
        return nil
      }
      guard let selected = devices.first else {
        logger.warning("device_selection", "no-compatible-device")
        return nil
      }
      logger.info("selected_device", selected.name ?? "name-not-read")
      return selected
    }

    guard includesDeviceNames else {
      logger.warning("device_selection", "name-selection-disabled")
      return nil
    }

    let matches = devices.filter {
      $0.name?.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
    }

    guard matches.count == 1, let selected = matches.first else {
      if matches.isEmpty {
        logger.warning("device_selection", "no-exact-name-match")
      } else {
        logger.warning("device_selection", "ambiguous-device-name")
      }
      return nil
    }

    logger.info("selected_device", selected.name)
    return selected
  }
}
