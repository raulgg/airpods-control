import CoreBluetooth
import Foundation

enum BluetoothAuthorizationState: String {
  case authorized
  case notDetermined = "not-determined"
  case denied
  case restricted
  case unavailable
}

enum BluetoothRadioState: String {
  case poweredOn = "powered-on"
  case poweredOff = "powered-off"
  case resetting
  case unsupported
  case unauthorized
  case unknown
}

struct BluetoothAdvertisement: Equatable {
  let peripheralIdentifier: UUID
  let manufacturerData: Data
}

struct BluetoothScanResult {
  let authorization: BluetoothAuthorizationState
  let radio: BluetoothRadioState
  let advertisements: [BluetoothAdvertisement]
}

protocol BluetoothScanning {
  func authorization() -> BluetoothAuthorizationState
  func radioState() -> BluetoothRadioState?
  func requestAuthorization(timeout: TimeInterval) -> BluetoothScanResult
  func scan(duration: TimeInterval) -> BluetoothScanResult
}

enum BluetoothScan {
  static let duration: TimeInterval = 2
}

struct BluetoothPeripheralObservation: Equatable {
  let peripheralIdentifier: UUID
  let productID: Int
  let placement: BluetoothEarPlacement
  let callbackCount: Int
}

enum AirPodsBLEScanNormalizer {
  static func normalize(
    _ advertisements: [BluetoothAdvertisement]
  ) -> [BluetoothPeripheralObservation] {
    Dictionary(grouping: advertisements, by: \.peripheralIdentifier)
      .compactMap { identifier, callbacks in
        let frames = callbacks.compactMap {
          AirPodsBLEFrameParser.parse(manufacturerData: $0.manufacturerData)
        }
        guard frames.count >= 2,
              let first = frames.first,
              frames.allSatisfy({ $0 == first })
        else {
          return nil
        }
        return BluetoothPeripheralObservation(
          peripheralIdentifier: identifier,
          productID: first.productID,
          placement: first.placement,
          callbackCount: frames.count
        )
      }
  }
}

final class SystemBluetoothScanner: BluetoothScanning {
  func authorization() -> BluetoothAuthorizationState {
    Self.authorizationState(CBManager.authorization)
  }

  func radioState() -> BluetoothRadioState? {
    guard authorization() == .authorized else { return nil }
    let session = SystemBluetoothScanSession()
    let manager = CBCentralManager(
      delegate: session,
      queue: nil,
      options: [CBCentralManagerOptionShowPowerAlertKey: false]
    )
    let deadline = Date(timeIntervalSinceNow: 0.25)
    while manager.state == .unknown, Date() < deadline {
      RunLoop.current.run(
        mode: .default,
        before: min(deadline, Date(timeIntervalSinceNow: 0.05))
      )
    }
    return Self.radioState(manager.state)
  }

  func requestAuthorization(timeout: TimeInterval) -> BluetoothScanResult {
    let before = authorization()
    guard before == .notDetermined else {
      return BluetoothScanResult(
        authorization: before,
        radio: before == .authorized ? .unknown : .unauthorized,
        advertisements: []
      )
    }
    let session = SystemBluetoothScanSession()
    let manager = CBCentralManager(
      delegate: session,
      queue: nil,
      options: [CBCentralManagerOptionShowPowerAlertKey: false]
    )
    let deadline = Date(timeIntervalSinceNow: max(0, timeout))
    while authorization() == .notDetermined, Date() < deadline {
      RunLoop.current.run(
        mode: .default,
        before: min(deadline, Date(timeIntervalSinceNow: 0.05))
      )
    }
    return BluetoothScanResult(
      authorization: authorization(),
      radio: Self.radioState(manager.state),
      advertisements: []
    )
  }

  func scan(duration: TimeInterval) -> BluetoothScanResult {
    let before = authorization()
    guard before == .authorized else {
      return BluetoothScanResult(
        authorization: before,
        radio: .unauthorized,
        advertisements: []
      )
    }

    let session = SystemBluetoothScanSession()
    let manager = CBCentralManager(
      delegate: session,
      queue: nil,
      options: [CBCentralManagerOptionShowPowerAlertKey: false]
    )
    let stateDeadline = Date(timeIntervalSinceNow: 1)
    while manager.state == .unknown, Date() < stateDeadline {
      RunLoop.current.run(
        mode: .default,
        before: min(stateDeadline, Date(timeIntervalSinceNow: 0.05))
      )
    }
    guard manager.state == .poweredOn else {
      return BluetoothScanResult(
        authorization: authorization(),
        radio: Self.radioState(manager.state),
        advertisements: []
      )
    }
    manager.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )
    let scanDeadline = Date(timeIntervalSinceNow: max(0, duration))
    while Date() < scanDeadline {
      RunLoop.current.run(
        mode: .default,
        before: min(scanDeadline, Date(timeIntervalSinceNow: 0.05))
      )
    }
    manager.stopScan()
    return BluetoothScanResult(
      authorization: authorization(),
      radio: Self.radioState(manager.state),
      advertisements: session.advertisements
    )
  }

  private static func authorizationState(
    _ authorization: CBManagerAuthorization
  ) -> BluetoothAuthorizationState {
    switch authorization {
    case .allowedAlways: return .authorized
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .restricted: return .restricted
    @unknown default: return .unavailable
    }
  }

  private static func radioState(_ state: CBManagerState) -> BluetoothRadioState {
    switch state {
    case .poweredOn: return .poweredOn
    case .poweredOff: return .poweredOff
    case .resetting: return .resetting
    case .unsupported: return .unsupported
    case .unauthorized: return .unauthorized
    case .unknown: return .unknown
    @unknown default: return .unknown
    }
  }
}

private final class SystemBluetoothScanSession: NSObject, CBCentralManagerDelegate {
  var advertisements: [BluetoothAdvertisement] = []

  func centralManagerDidUpdateState(_ central: CBCentralManager) {}

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard let manufacturerData =
      advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
    else {
      return
    }
    advertisements.append(
      BluetoothAdvertisement(
        peripheralIdentifier: peripheral.identifier,
        manufacturerData: manufacturerData
      )
    )
  }
}
