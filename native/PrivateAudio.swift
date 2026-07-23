import Darwin
import Foundation

let normalListeningModeRawValue = "AVOutputDeviceBluetoothListeningModeNormal"

private let standardListeningModeReadbackAttempts = 16
private let offListeningModeReadbackAttempts = 30
private let listeningModeReadbackDelay: useconds_t = 50_000

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

struct ListeningModeWriteOutcome {
  let setterAccepted: Bool
  let observedRawMode: String?
}

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

final class AudioDevice {
  let object: AnyObject
  let name: String
  private let logger: DebugLogger

  private init(object: AnyObject, name: String, logger: DebugLogger) {
    self.object = object
    self.name = name
    self.logger = logger
  }

  static func compatible(object: AnyObject, index: Int, logger: DebugLogger) -> AudioDevice? {
    let requiredSelectors = [nameSelector, availableModesSelector, currentModeSelector]
    for selector in requiredSelectors where !object.responds(to: selector) {
      logger.debug("device.\(index).missing_selector", NSStringFromSelector(selector))
      return nil
    }

    guard let nameValue = object.perform(nameSelector)?.takeUnretainedValue(),
          let name = nameValue as? String,
          !name.isEmpty
    else {
      logger.debug("device.\(index).name", "unavailable")
      return nil
    }

    guard let modesValue = object.perform(availableModesSelector)?.takeUnretainedValue(),
          let modes = modesValue as? [String],
          !modes.isEmpty
    else {
      logger.debug("device.\(index).compatible", false)
      logger.debug("device.\(index).name", name)
      return nil
    }

    logger.debug("device.\(index).name", name)
    logger.debug("device.\(index).compatible", true)
    logger.debug("device.\(index).available_modes", modes.joined(separator: ","))
    return AudioDevice(object: object, name: name, logger: logger)
  }

  func availableListeningModes() -> [String] {
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

  func currentListeningMode() -> String? {
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

  func canSetListeningMode() -> Bool {
    let available = object.responds(to: setModeSelector)
    logger.debug("selector.setCurrentBluetoothListeningMode:error:", available)
    return available
  }

  func setListeningMode(_ mode: String) -> Bool? {
    guard canSetListeningMode() else { return nil }
    var error: NSError?
    let setter = unsafeBitCast(object, to: ListeningModeSetterShim.self)
    let accepted = setter.setListeningMode(mode, &error)
    logger.debug("write.listening_mode.accepted", accepted)
    if let error {
      logger.warning("write.listening_mode.error", error.localizedDescription)
    }
    return accepted
  }

  func setListeningModeAndReadBack(_ target: String) -> ListeningModeWriteOutcome {
    setListeningModeAndReadBack(target, wait: waitForPrivateAudioUpdate)
  }

  func setListeningModeAndReadBack(
    _ target: String,
    wait: (useconds_t) -> Void
  ) -> ListeningModeWriteOutcome {
    let settleThroughDeadline = target == normalListeningModeRawValue
    let attemptLimit = settleThroughDeadline
      ? offListeningModeReadbackAttempts
      : standardListeningModeReadbackAttempts

    let setterAccepted = setListeningMode(target) == true
    var observed = currentListeningMode()
    logger.debug("verify.listening_mode.attempt", 0)

    if observed != target || settleThroughDeadline {
      for attempt in 1...attemptLimit {
        wait(listeningModeReadbackDelay)
        observed = currentListeningMode()
        logger.debug("verify.listening_mode.attempt", attempt)
        if observed == target, !settleThroughDeadline { break }
      }
    }

    return ListeningModeWriteOutcome(
      setterAccepted: setterAccepted,
      observedRawMode: observed
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

  func setConversationAwareness(_ enabled: Bool) -> Bool? {
    guard canSetConversationAwareness() else { return nil }
    var error: NSError?
    let setter = unsafeBitCast(object, to: ConversationAwarenessSetterShim.self)
    let accepted = setter.setConversationAwareness(enabled, &error)
    logger.debug("write.conversation_awareness.accepted", accepted)
    if let error {
      logger.warning("write.conversation_awareness.error", error.localizedDescription)
    }
    return accepted
  }
}

final class PrivateAudioController {
  private let devices: [AudioDevice]
  private let logger: DebugLogger

  init(rawDevices: [AnyObject], logger: DebugLogger) {
    self.logger = logger
    devices = rawDevices.enumerated().compactMap { index, object in
      AudioDevice.compatible(object: object, index: index, logger: logger)
    }
    logger.info("compatible_device_count", devices.count)
  }

  func selectDevice(named requestedName: String?) -> AudioDevice? {
    guard let requestedName else {
      guard let selected = devices.first else {
        logger.warning("device_selection", "no-compatible-device")
        return nil
      }
      logger.info("selected_device", selected.name)
      return selected
    }

    let matches = devices.filter {
      $0.name.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
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
