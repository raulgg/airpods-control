import Foundation

@testable import AirPodsControlCore

let rawListeningModeValues: [ListeningMode: String] = [
  .off: "AVOutputDeviceBluetoothListeningModeNormal",
  .transparency: "AVOutputDeviceBluetoothListeningModeAudioTransparency",
  .adaptive: "AVOutputDeviceBluetoothListeningModeAutomatic",
  .noiseCancellation: "AVOutputDeviceBluetoothListeningModeActiveNoiseCancellation",
]

@objc final class FakeContext: NSObject {
  let devices: [AnyObject]
  let currentDevice: AnyObject?
  private(set) var outputDeviceReadCount = 0

  init(devices: [AnyObject], currentDevice: AnyObject? = nil) {
    self.devices = devices
    self.currentDevice = currentDevice
  }

  @objc(outputDevices) func outputDeviceValues() -> [AnyObject] {
    devices
  }

  @objc(outputDevice) func currentOutputDevice() -> AnyObject? {
    outputDeviceReadCount += 1
    return currentDevice
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
  let modelIdentifier: String
  let listeningModeError: NSError?
  let conversationAwarenessError: NSError?
  let deviceIdentifier: String
  private(set) var nameReadCount = 0
  private(set) var deviceIDReadCount = 0
  var listeningModeSetCount = 0
  var conversationAwarenessSetCount = 0

  init(
    name: String,
    modes: [String] = Array(rawListeningModeValues.values),
    mode: String = rawListeningModeValues[.transparency]!,
    conversationAwarenessSupported: Bool = true,
    conversationAwarenessEnabled: Bool = false,
    appliesListeningModeAsynchronously: Bool = false,
    appliesConversationAwarenessWrite: Bool = true,
    modelIdentifier: String = "AirPodsTest1,1",
    deviceIdentifier: String = UUID().uuidString,
    listeningModeError: NSError? = nil,
    conversationAwarenessError: NSError? = nil
  ) {
    outputName = name
    self.modes = modes
    self.mode = mode
    self.conversationAwarenessSupported = conversationAwarenessSupported
    self.conversationAwarenessEnabled = conversationAwarenessEnabled
    self.appliesListeningModeAsynchronously = appliesListeningModeAsynchronously
    self.appliesConversationAwarenessWrite = appliesConversationAwarenessWrite
    self.modelIdentifier = modelIdentifier
    self.deviceIdentifier = deviceIdentifier
    self.listeningModeError = listeningModeError
    self.conversationAwarenessError = conversationAwarenessError
  }

  @objc(name) func deviceName() -> String {
    nameReadCount += 1
    return outputName
  }

  @objc(modelID) func modelID() -> String {
    modelIdentifier
  }

  @objc(deviceID) func deviceID() -> String {
    deviceIDReadCount += 1
    return deviceIdentifier
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
    if let listeningModeError {
      error?.pointee = listeningModeError
      return false
    }
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
    if let conversationAwarenessError {
      error?.pointee = conversationAwarenessError
      return false
    }
    if appliesConversationAwarenessWrite {
      conversationAwarenessEnabled = enabled
    }
    return true
  }
}

@objc final class FakeReadOnlyRawDevice: NSObject {
  let outputName: String
  let modes: [String]
  let modelIdentifier: String
  let deviceIdentifier: String
  private(set) var nameReadCount = 0
  private(set) var deviceIDReadCount = 0

  init(
    name: String,
    modes: [String] = Array(rawListeningModeValues.values),
    modelIdentifier: String = "AirPodsReadOnly1,1",
    deviceIdentifier: String = UUID().uuidString
  ) {
    outputName = name
    self.modes = modes
    self.modelIdentifier = modelIdentifier
    self.deviceIdentifier = deviceIdentifier
  }

  @objc(name) func deviceName() -> String {
    nameReadCount += 1
    return outputName
  }

  @objc(modelID) func modelID() -> String {
    modelIdentifier
  }

  @objc(deviceID) func deviceID() -> String {
    deviceIDReadCount += 1
    return deviceIdentifier
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    modes
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String {
    rawListeningModeValues[.transparency]!
  }
}

@objc final class FakeCAOnlyCurrentRawDevice: NSObject {
  private(set) var conversationAwarenessEnabled = false
  private(set) var conversationAwarenessSetCount = 0

  @objc(name) func deviceName() -> String {
    "CA-only AirPods"
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    []
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String? {
    nil
  }

  @objc(supportsConversationDetection) func supportsConversationDetection() -> Bool {
    true
  }

  @objc(isConversationDetectionEnabled) func isConversationDetectionEnabled() -> Bool {
    conversationAwarenessEnabled
  }

  @objc(setConversationDetectionEnabled:error:)
  func setConversationDetectionEnabled(_ enabled: Bool, _ error: NSErrorPointer) -> Bool {
    conversationAwarenessSetCount += 1
    conversationAwarenessEnabled = enabled
    return true
  }
}

@objc final class FakeMissingConversationAwarenessStateRawDevice: NSObject {
  @objc(name) func deviceName() -> String {
    "Missing CA State AirPods"
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    [rawListeningModeValues[.transparency]!]
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String {
    rawListeningModeValues[.transparency]!
  }

  @objc(supportsConversationDetection) func supportsConversationDetection() -> Bool {
    true
  }
}

@objc final class FakeSupportReportRawDevice: NSObject {
  private(set) var nameReadCount = 0

  @objc(name) func deviceName() -> String {
    nameReadCount += 1
    return "Custom Owner Name"
  }

  @objc(modelID) func modelID() -> String {
    "BTHeadphones76,8231"
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    [
      rawListeningModeValues[.transparency]!,
      rawListeningModeValues[.noiseCancellation]!,
    ]
  }

  @objc(currentBluetoothListeningMode) func currentListeningMode() -> String {
    rawListeningModeValues[.transparency]!
  }

  @objc(supportsConversationDetection) func supportsConversationDetection() -> Bool {
    true
  }

  @objc(isConversationDetectionEnabled) func isConversationDetectionEnabled() -> Bool {
    false
  }
}

@objc final class FakeNamelessRawDevice: NSObject {
  @objc(modelID) func modelID() -> String {
    "BTHeadphones76,8231"
  }

  @objc(availableBluetoothListeningModes) func availableListeningModes() -> [String] {
    [rawListeningModeValues[.transparency]!]
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
