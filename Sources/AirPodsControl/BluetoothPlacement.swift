enum BluetoothPlacement {
  static func resolved(
    hal: DeviceStatusField<BluetoothEarPlacement>,
    ble: BluetoothEarPlacement?,
    enrolled: Bool
  ) -> DeviceStatusField<BluetoothEarPlacement> {
    switch hal {
    case .value, .unresolved, .readError:
      return hal
    case .unsupported:
      guard enrolled else { return .unsupported }
      return ble.map(DeviceStatusField.value) ?? .unresolved
    }
  }
}
