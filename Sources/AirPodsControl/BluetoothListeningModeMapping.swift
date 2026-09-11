enum BluetoothListeningModeMapping {
  static let modeByRawValue: [UInt32: ListeningMode] = [
    1: .off,
    2: .noiseCancellation,
    3: .transparency,
    4: .adaptive,
  ]

  static let rawValueByMode: [ListeningMode: UInt32] = Dictionary(
    uniqueKeysWithValues: modeByRawValue.map { ($1, $0) }
  )
}
