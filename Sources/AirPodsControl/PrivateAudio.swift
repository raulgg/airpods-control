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
private let deviceIDSelector = NSSelectorFromString("deviceID")

enum PrivateAudioDiscoverySource: String, Hashable {
  case contextPlural = "context-plural"
  case contextSingular = "context-singular"
}

enum PrivateAudioAccessPolicy {
  case operational
  case status
  case supportReport
}

struct PrivateAudioContextEndpoints {
  let plural: [AnyObject]
  let singular: AnyObject?
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

  fileprivate static func deviceIdentifier(for object: AnyObject) -> String? {
    guard object.responds(to: deviceIDSelector),
          let value = object.perform(deviceIDSelector)?.takeUnretainedValue()
    else { return nil }

    if let string = value as? String, !string.isEmpty {
      return string
    }
    if let uuid = value as? UUID {
      return uuid.uuidString
    }
    return nil
  }

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

  static func outputDevice(from context: AnyObject, logger: DebugLogger) -> AnyObject? {
    let selector = NSSelectorFromString("outputDevice")
    guard context.responds(to: selector) else {
      logger.debug("selector.outputDevice", "unavailable")
      return nil
    }
    guard let device = context.perform(selector)?.takeUnretainedValue() else {
      logger.info("discovery.context_singular_present", false)
      return nil
    }
    logger.info("discovery.context_singular_present", true)
    return device as AnyObject
  }

  static func contextEndpoints(
    from context: AnyObject,
    logger: DebugLogger
  ) -> PrivateAudioContextEndpoints {
    let plural = outputDevices(from: context, logger: logger) ?? []
    logger.info("discovery.context_plural_count", plural.count)
    return PrivateAudioContextEndpoints(
      plural: plural,
      singular: outputDevice(from: context, logger: logger)
    )
  }

  private static func systemContext(logger: DebugLogger) -> AnyObject? {
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
    return context
  }

  static func systemOutputDevices(logger: DebugLogger) -> [AnyObject]? {
    guard let context = systemContext(logger: logger) else { return nil }
    return outputDevices(from: context, logger: logger)
  }

  static func systemStatusOutputContext(logger: DebugLogger) -> AnyObject? {
    systemContext(logger: logger)
  }

  static func systemOperationalEndpoints(
    logger: DebugLogger
  ) -> PrivateAudioContextEndpoints? {
    guard let context = systemContext(logger: logger) else { return nil }
    return contextEndpoints(from: context, logger: logger)
  }
}

final class PrivateAudioDevice: CompatibleAudioDevice {
  let object: AnyObject
  fileprivate(set) var sources: Set<PrivateAudioDiscoverySource>
  let name: String?
  private let logger: DebugLogger

  private init(
    object: AnyObject,
    sources: Set<PrivateAudioDiscoverySource>,
    name: String?,
    logger: DebugLogger
  ) {
    self.object = object
    self.sources = sources
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
    sources: Set<PrivateAudioDiscoverySource>,
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
          let modes = modesValue as? [String]
    else {
      logger.debug("device.\(index).compatible", false)
      return nil
    }

    if modes.isEmpty {
      guard sources.contains(.contextSingular),
            singularEndpointHasControlSignal(object)
      else {
        logger.debug("device.\(index).compatible", false)
        return nil
      }
      // Only the singular current endpoint may survive an empty capability
      // list, and only while it still answers a control-plane query. Product
      // metadata is never runtime capability evidence.
      logger.debug("device.\(index).transient_empty_modes", true)
    }

    logger.debug("device.\(index).compatible", true)
    logger.debug("device.\(index).available_modes", modes.joined(separator: ","))
    return PrivateAudioDevice(
      object: object,
      sources: sources,
      name: name,
      logger: logger
    )
  }

  private static func singularEndpointHasControlSignal(_ object: AnyObject) -> Bool {
    if object.responds(to: currentModeSelector),
       let rawMode = object.perform(currentModeSelector)?.takeUnretainedValue() as? String,
       !rawMode.isEmpty
    {
      return true
    }

    guard object.responds(to: supportsCASelector),
          object.responds(to: caEnabledSelector)
    else { return false }
    let support = unsafeBitCast(object, to: ConversationAwarenessSupportShim.self)
    guard support.supportsConversationAwareness() else { return false }
    let state = unsafeBitCast(object, to: ConversationAwarenessStateShim.self)
    _ = state.conversationAwarenessEnabled()
    return true
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

  func readListeningModeStatus() -> DeviceStatusField<ListeningMode> {
    // Compatibility checks this selector during discovery. If it disappears
    // or stops returning a string before the one-shot status read, that is a
    // real read failure rather than an unknown future mode.
    guard object.responds(to: currentModeSelector),
          let value = object.perform(currentModeSelector)?.takeUnretainedValue(),
          let rawMode = value as? String
    else {
      logger.warning("status.listening_mode", "read-error")
      return .readError
    }
    logger.debug("device.current_mode", rawMode)
    guard let mode = listeningModesByRawValue[rawMode] else {
      return .unresolved
    }
    return .value(mode)
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

  func readConversationAwarenessStatus() -> DeviceStatusField<Bool> {
    // A missing support probe is unresolved, matching the existing get
    // command's fallback. An explicit false is the only proof that the field
    // should be omitted from status.
    guard let supported = supportsConversationAwareness() else {
      return .unresolved
    }
    guard supported else { return .unsupported }

    // Once the device advertises support, losing the state selector is an
    // actual read failure. The stable output still uses the get command's
    // fallback while the status errors map records the failure.
    guard object.responds(to: caEnabledSelector) else {
      logger.warning("status.conversation_awareness", "read-error")
      return .readError
    }
    let shim = unsafeBitCast(object, to: ConversationAwarenessStateShim.self)
    let enabled = shim.conversationAwarenessEnabled()
    logger.debug("device.conversation_awareness", enabled ? "on" : "off")
    return .value(enabled)
  }

  func readAudioOutputSelectionStatus() -> AudioDeviceSelectionObservation {
    .unresolved
  }

  func readAudioInputSelectionStatus() -> AudioDeviceSelectionObservation {
    .unresolved
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

  private init(
    devices: [PrivateAudioDevice],
    logger: DebugLogger,
    includeDeviceNames: Bool
  ) {
    self.logger = logger
    includesDeviceNames = includeDeviceNames
    self.devices = devices
    logger.info("compatible_device_count", devices.count)
    for (index, device) in devices.enumerated() {
      let sources = device.sources.map(\.rawValue).sorted().joined(separator: ",")
      logger.debug("discovery.candidate_\(index)_sources", sources)
    }
  }

  convenience init(
    rawDevices: [AnyObject],
    logger: DebugLogger,
    includeDeviceNames: Bool = true
  ) {
    let devices = rawDevices.enumerated().compactMap { index, object in
      PrivateAudioDevice.compatible(
        object: object,
        sources: [.contextPlural],
        index: index,
        logger: logger,
        includeDeviceName: includeDeviceNames
      )
    }
    self.init(
      devices: devices,
      logger: logger,
      includeDeviceNames: includeDeviceNames
    )
  }

  convenience init(
    endpoints: PrivateAudioContextEndpoints,
    logger: DebugLogger
  ) {
    let pluralDevices = endpoints.plural.enumerated().compactMap { index, object in
      PrivateAudioDevice.compatible(
        object: object,
        sources: [.contextPlural],
        index: index,
        logger: logger
      )
    }
    let singularDevice = endpoints.singular.flatMap { object in
      PrivateAudioDevice.compatible(
        object: object,
        sources: [.contextSingular],
        index: endpoints.plural.count,
        logger: logger
      )
    }
    self.init(
      devices: Self.resolveOperationalDevices(
        plural: pluralDevices,
        singularObject: endpoints.singular,
        singularDevice: singularDevice
      ),
      logger: logger,
      includeDeviceNames: true
    )
  }

  private static func resolveOperationalDevices(
    plural: [PrivateAudioDevice],
    singularObject: AnyObject?,
    singularDevice: PrivateAudioDevice?
  ) -> [PrivateAudioDevice] {
    guard let singularObject else { return plural }

    let needsIdentifiers = plural.contains { $0.object !== singularObject }
    let singularIdentifier = needsIdentifiers
      ? PrivateAudioDiscovery.deviceIdentifier(for: singularObject)
      : nil
    var resolved: [PrivateAudioDevice] = []
    var insertedSingular = false

    for pluralDevice in plural {
      let isAlias: Bool?
      if pluralDevice.object === singularObject {
        isAlias = true
      } else if let singularIdentifier,
                let pluralIdentifier = PrivateAudioDiscovery.deviceIdentifier(
                  for: pluralDevice.object
                )
      {
        isAlias = pluralIdentifier == singularIdentifier
      } else {
        isAlias = nil
      }

      if isAlias == false {
        resolved.append(pluralDevice)
        continue
      }

      if isAlias == true {
        singularDevice?.sources.insert(.contextPlural)
      }
      if !insertedSingular, let singularDevice {
        resolved.append(singularDevice)
        insertedSingular = true
      }
    }

    if !insertedSingular, let singularDevice {
      resolved.append(singularDevice)
    }
    return resolved
  }

  func selectDevice(named requestedName: String?) -> PrivateAudioDevice? {
    selectDevices(named: requestedName, policy: .firstOrExact)?.first
  }

  func selectDevices(
    named requestedName: String?,
    policy: DeviceSelectionPolicy
  ) -> [PrivateAudioDevice]? {
    guard let requestedName else {
      if !includesDeviceNames, devices.count != 1 {
        logger.warning("device_selection", "unique-name-free-device-required")
        return nil
      }
      guard !devices.isEmpty else {
        logger.warning("device_selection", "no-compatible-device")
        return nil
      }
      switch policy {
      case .firstOrExact:
        let selected = devices[0]
        logger.info("selected_device", selected.name ?? "name-not-read")
        return [selected]
      case .allOrExact:
        guard includesDeviceNames else {
          // Name-free discovery belongs to support-report and must retain its
          // exactly-one-device privacy contract.
          let selected = devices[0]
          logger.info("selected_device", "name-not-read")
          return [selected]
        }
        logger.info("selected_device_count", devices.count)
        return devices
      }
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
    return [selected]
  }
}
