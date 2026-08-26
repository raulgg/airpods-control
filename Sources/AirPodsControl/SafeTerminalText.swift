import Foundation

enum SafeTerminalText {
  static func escaped(_ value: String) -> String {
    value.unicodeScalars.map { scalar in
      switch scalar.value {
      case 0x5C: return "\\\\"
      case 0x0A: return "\\n"
      case 0x0D: return "\\r"
      case 0x09: return "\\t"
      // These Unicode separators also create visual record boundaries even
      // though they are not in the Control general category.
      case 0x2028, 0x2029: return unicodeEscape(scalar.value)
      default:
        if scalar.properties.generalCategory == .control {
          return unicodeEscape(scalar.value)
        }
        return String(scalar)
      }
    }.joined()
  }

  private static func unicodeEscape(_ value: UInt32) -> String {
    let raw = String(value, radix: 16, uppercase: true)
    let padded = String(repeating: "0", count: max(0, 4 - raw.count)) + raw
    return "\\u{\(padded)}"
  }
}
