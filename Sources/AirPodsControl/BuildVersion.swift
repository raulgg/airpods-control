enum BuildVersion {
  #if SWIFT_PACKAGE
  static let current = "0.0.0-test"
  #else
  static let current = VERSION
  #endif
}
