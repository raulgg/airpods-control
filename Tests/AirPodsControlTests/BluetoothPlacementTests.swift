import Foundation

func testBluetoothPlacementResolved() {
  let ble = BluetoothEarPlacement(left: .inEar, right: .inEar)
  let hal = BluetoothEarPlacement(left: .outOfEar, right: .inEar)

  if case let .value(value) = BluetoothPlacement.resolved(
    hal: .value(hal),
    ble: ble,
    enrolled: true
  ) {
    check(value == hal, "valid HAL placement wins over BLE")
  } else {
    check(false, "valid HAL placement wins over BLE")
  }

  if case .unresolved = BluetoothPlacement.resolved(
    hal: .unresolved,
    ble: ble,
    enrolled: true
  ) {
    check(true, "unresolved HAL evidence blocks BLE")
  } else {
    check(false, "unresolved HAL evidence blocks BLE")
  }

  if case .readError = BluetoothPlacement.resolved(
    hal: .readError,
    ble: ble,
    enrolled: true
  ) {
    check(true, "HAL read errors block BLE")
  } else {
    check(false, "HAL read errors block BLE")
  }

  if case let .value(value) = BluetoothPlacement.resolved(
    hal: .unsupported,
    ble: ble,
    enrolled: true
  ) {
    check(value == ble, "BLE fills unsupported HAL when enrolled")
  } else {
    check(false, "BLE fills unsupported HAL when enrolled")
  }

  if case .unresolved = BluetoothPlacement.resolved(
    hal: .unsupported,
    ble: nil,
    enrolled: true
  ) {
    check(true, "enrolled silence stays unknown")
  } else {
    check(false, "enrolled silence stays unknown")
  }

  if case .unsupported = BluetoothPlacement.resolved(
    hal: .unsupported,
    ble: ble,
    enrolled: false
  ) {
    check(true, "unenrolled ads do not fill HAL placement")
  } else {
    check(false, "unenrolled ads do not fill HAL placement")
  }
}

func runBluetoothPlacementTests() {
  testBluetoothPlacementResolved()
}
