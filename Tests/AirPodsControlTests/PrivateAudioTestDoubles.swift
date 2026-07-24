import Foundation

let rawListeningModeValues: [ListeningMode: String] = [
  .off: "AVOutputDeviceBluetoothListeningModeNormal",
  .transparency: "AVOutputDeviceBluetoothListeningModeAudioTransparency",
  .adaptive: "AVOutputDeviceBluetoothListeningModeAutomatic",
  .noiseCancellation: "AVOutputDeviceBluetoothListeningModeActiveNoiseCancellation",
]

@objc final class FakeContext: NSObject {
  let devices: [AnyObject]

  init(devices: [AnyObject]) {
    self.devices = devices
  }

  @objc(outputDevices) func outputDeviceValues() -> [AnyObject] {
    devices
  }
}

@objc final class FakeLegacyContextProvider: NSObject {
  let context: AnyObject

  init(context: AnyObject) {
    self.context = context
  }

  @objc(sharedSystemAudio) func legacyContext() -> AnyObject {
    context
  }
}

@objc final class FakeDualContextProvider: NSObject {
  let modernContext: AnyObject
  let legacyContextValue: AnyObject

  init(modern: AnyObject, legacy: AnyObject) {
    modernContext = modern
    legacyContextValue = legacy
  }

  @objc(sharedSystemAudioContext) func modernContextValue() -> AnyObject {
    modernContext
  }

  @objc(sharedSystemAudio) func legacyContext() -> AnyObject {
    legacyContextValue
  }
}

@objc final class FakeRawDevice: NSObject {
  let outputName: String
  let modes: [String]
  var mode: String
  let conversationAwarenessSupported: Bool
  var conversationAwarenessEnabled: Bool
  let appliesListeningModeAsynchronously: Bool
  let appliesConversationAwarenessWrite: Bool
  var listeningModeSetCount = 0
  var conversationAwarenessSetCount = 0

  init(
    name: String,
    modes: [String] = Array(rawListeningModeValues.values),
    mode: String = rawListeningModeValues[.transparency]!,
    conversationAwarenessSupported: Bool = true,
    conversationAwarenessEnabled: Bool = false,
    appliesListeningModeAsynchronously: Bool = false,
    appliesConversationAwarenessWrite: Bool = true
  ) {
    outputName = name
    self.modes = modes
    self.mode = mode
    self.conversationAwarenessSupported = conversationAwarenessSupported
    self.conversationAwarenessEnabled = conversationAwarenessEnabled
    self.appliesListeningModeAsynchronously = appliesListeningModeAsynchronously
    self.appliesConversationAwarenessWrite = appliesConversationAwarenessWrite
  }

  @objc(name) func deviceName() -> String {
    outputName
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    modes
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String {
    mode
  }

  @objc(setCurrentBluetoothListeningMode:error:)
  func setListeningMode(_ newMode: String, _ error: NSErrorPointer) -> Bool {
    listeningModeSetCount += 1
    if appliesListeningModeAsynchronously {
      DispatchQueue.main.async { self.mode = newMode }
    } else {
      mode = newMode
    }
    return true
  }

  @objc(supportsConversationDetection) func supportsConversationDetection() -> Bool {
    conversationAwarenessSupported
  }

  @objc(isConversationDetectionEnabled) func isConversationDetectionEnabled() -> Bool {
    conversationAwarenessEnabled
  }

  @objc(setConversationDetectionEnabled:error:)
  func setConversationDetectionEnabled(_ enabled: Bool, _ error: NSErrorPointer) -> Bool {
    conversationAwarenessSetCount += 1
    if appliesConversationAwarenessWrite {
      conversationAwarenessEnabled = enabled
    }
    return true
  }
}

@objc final class FakeReadOnlyRawDevice: NSObject {
  let outputName: String

  init(name: String) {
    outputName = name
  }

  @objc(name) func deviceName() -> String {
    outputName
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    Array(rawListeningModeValues.values)
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String {
    rawListeningModeValues[.transparency]!
  }
}

@objc final class FakeScriptedListeningModeRawDevice: NSObject {
  let reads: [String?]
  let setterAccepted: Bool
  var readIndex = 0

  init(reads: [String?], setterAccepted: Bool = true) {
    precondition(!reads.isEmpty)
    self.reads = reads
    self.setterAccepted = setterAccepted
  }

  @objc(name) func deviceName() -> String {
    "Scripted AirPods"
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    Array(rawListeningModeValues.values)
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String? {
    let index = min(readIndex, reads.count - 1)
    readIndex += 1
    return reads[index]
  }

  @objc(setCurrentBluetoothListeningMode:error:)
  func setListeningMode(_ newMode: String, _ error: NSErrorPointer) -> Bool {
    setterAccepted
  }
}

@objc final class FakeIncompleteRawDevice: NSObject {
  @objc(name) func deviceName() -> String {
    "Incomplete AirPods"
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    Array(rawListeningModeValues.values)
  }
}

func scriptedPrivateAudioDevice(
  reads: [String?],
  setterAccepted: Bool = true
) -> PrivateAudioDevice {
  privateAudioDevice(
    FakeScriptedListeningModeRawDevice(
      reads: reads,
      setterAccepted: setterAccepted
    )
  )
}

func privateAudioDevice(_ rawDevice: AnyObject) -> PrivateAudioDevice {
  PrivateAudioController(
    rawDevices: [rawDevice],
    logger: DebugLogger(enabled: false)
  ).selectDevice(named: nil)!
}
