import Darwin
import Foundation

@main
struct OutputContractMain {
  static func main() {
    let rendered: String
    let exitCode: Int32
    switch CommandLine.arguments.dropFirst().first {
    case "json":
      exitCode = 0
      rendered = CLIOutputSerializer.json([
        "bool": .bool(true),
        "integer": .integer(7),
        "nested": .object([
          "control": .string("line\n\tesc\u{001B}"),
          "quote": .string("a\"b"),
          "slash": .string("a/b"),
        ]),
        "null": .null,
      ])
    case "plain":
      exitCode = 0
      rendered = CLIOutputSerializer.plain("plain output")
    case "signal":
      let reason = TerminalReason.caughtSignal(2)
      exitCode = reason.exitCode
      let payload = reason.addingEnvelope(to: [:])
      rendered = CLIOutputSerializer.json(payload)
    default:
      fatalError("expected json, plain, or signal")
    }

    print(rendered, terminator: "")
    exit(exitCode)
  }
}
