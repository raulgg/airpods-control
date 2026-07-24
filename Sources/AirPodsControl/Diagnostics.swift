import Foundation

struct DebugLogger {
  let enabled: Bool

  func debug(_ key: String, _ value: Any?) {
    write(level: "debug", key: key, value: value)
  }

  func info(_ key: String, _ value: Any?) {
    write(level: "info", key: key, value: value)
  }

  func warning(_ key: String, _ value: Any?) {
    write(level: "warning", key: key, value: value)
  }

  private func write(level: String, key: String, value: Any?) {
    guard enabled else { return }
    let rendered: String
    switch value {
    case nil:
      rendered = "null"
    case let string as String:
      rendered = String(reflecting: string)
    case let bool as Bool:
      rendered = bool ? "true" : "false"
    default:
      rendered = String(describing: value!)
    }
    let line = "\(level): \(key)=\(rendered)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}
