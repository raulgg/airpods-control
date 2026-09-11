import Foundation

// The command payload is deliberately closed over the values JSON can carry.
// Keep the Foundation bridge below explicit so a new command cannot smuggle an
// arbitrary Swift value into the process output.
enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int32)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  var foundationValue: Any {
    switch self {
    case .null:
      return NSNull()
    case let .bool(value):
      return value
    case let .integer(value):
      return value
    case let .string(value):
      return value
    case let .array(values):
      return values.map(\.foundationValue)
    case let .object(values):
      return values.reduce(into: [String: Any]()) { result, entry in
        result[entry.key] = entry.value.foundationValue
      }
    }
  }
}

enum CLIOutputSerializer {
  static func json(_ payload: [String: JSONValue]) -> String {
    let value = JSONValue.object(payload).foundationValue
    // JSONValue has no representation for values JSONSerialization cannot
    // encode, so this preserves the command's existing fail-fast behavior.
    let data = try! JSONSerialization.data(
      withJSONObject: value,
      options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  static func plain(_ text: String) -> String {
    text + "\n"
  }
}
