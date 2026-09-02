import Testing

@testable import AirPodsControlCore

@Suite("CLI parsing")
struct CLIParsingTests {
  @Test(
    "Canonicalizes listening-mode aliases",
    arguments: [
      AliasCase("anc", expected: "noise-cancellation"),
      AliasCase("nc", expected: "noise-cancellation"),
      AliasCase("trans", expected: "transparency"),
      AliasCase("automatic", expected: "adaptive"),
      AliasCase("auto", expected: "adaptive"),
    ]
  )
  func canonicalizesListeningModeAlias(_ example: AliasCase) throws {
    let invocation = try parseInvocation(["lm", "set", example.token])
    let mode = try #require(listeningModeSet(from: invocation.command))

    #expect(mode.rawValue == example.expected)
  }

  @Test("Accepts global options anywhere")
  func acceptsGlobalOptionsAnywhere() throws {
    let invocation = try parseInvocation([
      "--debug", "lm", "--device", "RAUL’S AIRPODS PRO", "get", "--json",
    ])

    #expect(invocation.debugEnabled)
    #expect(invocation.jsonOutput)
    #expect(invocation.requestedDeviceName == "RAUL’S AIRPODS PRO")
  }

  @Test(
    "Rejects invalid global and set arguments",
    arguments: [
      InvalidInvocation("off has no alias", ["lm", "set", "normal"]),
      InvalidInvocation(
        "duplicate device",
        ["--device", "A", "--device", "B", "lm", "get"]
      ),
      InvalidInvocation("missing device name", ["lm", "get", "--device"]),
      InvalidInvocation(
        "option-like device name",
        ["lm", "get", "--device", "--modes"]
      ),
      InvalidInvocation(
        "duplicate debug",
        ["--debug", "--debug", "lm", "get"]
      ),
      InvalidInvocation(
        "device is invalid for version",
        ["--device", "AirPods", "version"]
      ),
    ]
  )
  func rejectsInvalidGlobalAndSetArguments(
    _ example: InvalidInvocation
  ) {
    #expect(throws: CLIParseError.self) {
      _ = try parseInvocation(example.arguments)
    }
  }

  @Test(
    "Parses support-report write-test preferences",
    arguments: [
      WritePreferenceCase("asks by default", ["support-report"], .ask),
      WritePreferenceCase(
        "consents without asking",
        ["support-report", "--with-write-tests"],
        .always
      ),
      WritePreferenceCase(
        "declines anywhere in the invocation",
        ["--no-write-tests", "support-report"],
        .never
      ),
    ]
  )
  func parsesSupportReportPreference(
    _ example: WritePreferenceCase
  ) throws {
    let invocation = try parseInvocation(example.arguments)
    let preference = try #require(writePreference(from: invocation.command))

    #expect(preference == example.expected)
  }

  @Test("Accepts debug for support-report without changing consent or output")
  func acceptsSupportReportDebug() throws {
    let invocation = try parseInvocation(["support-report", "--debug"])
    let preference = try #require(writePreference(from: invocation.command))

    #expect(invocation.debugEnabled)
    #expect(!invocation.jsonOutput)
    #expect(preference == .ask)
  }

  @Test(
    "Rejects invalid support-report arguments",
    arguments: [
      InvalidInvocation(
        "mutually exclusive write-test flags",
        ["support-report", "--with-write-tests", "--no-write-tests"]
      ),
      InvalidInvocation(
        "duplicate consent flags",
        ["support-report", "--with-write-tests", "--with-write-tests"]
      ),
      InvalidInvocation(
        "consent flag on another command",
        ["lm", "get", "--with-write-tests"]
      ),
      InvalidInvocation(
        "decline flag on version",
        ["--no-write-tests", "version"]
      ),
      InvalidInvocation(
        "positional argument",
        ["support-report", "extra"]
      ),
      InvalidInvocation("JSON output", ["support-report", "--json"]),
      InvalidInvocation(
        "raw-name device selection",
        ["--device", "AirPods", "support-report"]
      ),
    ]
  )
  func rejectsInvalidSupportReportArguments(
    _ example: InvalidInvocation
  ) {
    #expect(throws: CLIParseError.self) {
      _ = try parseInvocation(example.arguments)
    }
  }

  @Test("Parses status with operational global options")
  func parsesStatusWithGlobalOptions() throws {
    let invocation = try parseInvocation([
      "--debug", "status", "--device", "Studio Beats", "--json",
    ])

    #expect(isStatusCommand(invocation.command))
    #expect(invocation.debugEnabled)
    #expect(invocation.jsonOutput)
    #expect(invocation.requestedDeviceName == "Studio Beats")
  }

  @Test(
    "Rejects invalid status arguments",
    arguments: [
      InvalidInvocation("alias", ["st"]),
      InvalidInvocation("positional argument", ["status", "extra"]),
      InvalidInvocation(
        "cycle modes",
        ["status", "--modes", "transparency,adaptive"]
      ),
      InvalidInvocation(
        "write-test consent",
        ["status", "--with-write-tests"]
      ),
      InvalidInvocation(
        "write-test decline",
        ["status", "--no-write-tests"]
      ),
    ]
  )
  func rejectsInvalidStatusArguments(_ example: InvalidInvocation) {
    #expect(throws: CLIParseError.self) {
      _ = try parseInvocation(example.arguments)
    }
  }

  @Test("Uses the default listening-mode cycle when modes are omitted")
  func parsesDefaultCycle() throws {
    let invocation = try parseInvocation(["lm", "cycle"])
    let selection = try #require(cycleSelection(from: invocation.command))

    #expect(selection == .defaultModes)
  }

  @Test(
    "Canonicalizes explicit cycle modes",
    arguments: [
      CycleCase(
        "aliases",
        "anc,trans",
        ["transparency", "noise-cancellation"]
      ),
      CycleCase(
        "off sorts first",
        "noise-cancellation,off,transparency",
        ["off", "transparency", "noise-cancellation"]
      ),
    ]
  )
  func canonicalizesExplicitCycleModes(_ example: CycleCase) throws {
    let invocation = try parseInvocation([
      "lm", "cycle", "--modes", example.argument,
    ])
    let selection = try #require(cycleSelection(from: invocation.command))

    #expect(selection == .explicit(example.expected))
  }

  @Test(
    "Rejects invalid cycle arguments",
    arguments: [
      InvalidInvocation("positional argument", ["lm", "cycle", "extra"]),
      InvalidInvocation("missing modes value", ["lm", "cycle", "--modes"]),
      InvalidInvocation(
        "one mode",
        ["lm", "cycle", "--modes", "transparency"]
      ),
      InvalidInvocation(
        "aliases deduplicate",
        ["lm", "cycle", "--modes", "trans,transparency"]
      ),
      InvalidInvocation(
        "unknown mode",
        ["lm", "cycle", "--modes", "transparency,normal"]
      ),
      InvalidInvocation(
        "empty mode",
        ["lm", "cycle", "--modes", ",transparency,adaptive"]
      ),
      InvalidInvocation(
        "duplicate modes flag",
        ["lm", "cycle", "--modes", "a,b", "--modes", "a,b"]
      ),
      InvalidInvocation(
        "modes on get",
        ["lm", "get", "--modes", "transparency,adaptive"]
      ),
      InvalidInvocation(
        "modes on version",
        ["--modes", "transparency,adaptive", "version"]
      ),
    ]
  )
  func rejectsInvalidCycleArguments(_ example: InvalidInvocation) {
    #expect(throws: CLIParseError.self) {
      _ = try parseInvocation(example.arguments)
    }
  }

  @Test(
    "Selects the next mode in canonical order",
    arguments: [
      NextModeCase(
        "advances",
        current: "transparency",
        within: ["transparency", "adaptive", "noise-cancellation"],
        expected: "adaptive"
      ),
      NextModeCase(
        "wraps",
        current: "noise-cancellation",
        within: ["transparency", "adaptive", "noise-cancellation"],
        expected: "transparency"
      ),
      NextModeCase(
        "wraps through off",
        current: "noise-cancellation",
        within: ["off", "transparency", "adaptive", "noise-cancellation"],
        expected: "off"
      ),
      NextModeCase(
        "folds an excluded current mode",
        current: "adaptive",
        within: ["transparency", "noise-cancellation"],
        expected: "noise-cancellation"
      ),
      NextModeCase(
        "folding wraps",
        current: "adaptive",
        within: ["off", "transparency"],
        expected: "off"
      ),
      NextModeCase(
        "cycles out of off",
        current: "off",
        within: ["transparency", "adaptive", "noise-cancellation"],
        expected: "transparency"
      ),
      NextModeCase(
        "starts an unknown mode at the beginning",
        current: nil,
        within: ["transparency", "adaptive", "noise-cancellation"],
        expected: "transparency"
      ),
    ]
  )
  func selectsNextCycleMode(_ example: NextModeCase) throws {
    let current = try example.current.map {
      try #require(ListeningMode(token: $0))
    }
    let cycle = try example.within.map {
      try #require(ListeningMode(token: $0))
    }

    #expect(
      ListeningMode.next(current: current, within: cycle).rawValue
        == example.expected
    )
  }
}

struct AliasCase: Sendable, CustomTestStringConvertible {
  let token: String
  let expected: String

  init(_ token: String, expected: String) {
    self.token = token
    self.expected = expected
  }

  var testDescription: String { token }
}

struct InvalidInvocation: Sendable, CustomTestStringConvertible {
  let name: String
  let arguments: [String]

  init(_ name: String, _ arguments: [String]) {
    self.name = name
    self.arguments = arguments
  }

  var testDescription: String { name }
}

enum ExpectedWritePreference: Sendable {
  case ask
  case always
  case never
}

struct WritePreferenceCase: Sendable, CustomTestStringConvertible {
  let name: String
  let arguments: [String]
  let expected: ExpectedWritePreference

  init(
    _ name: String,
    _ arguments: [String],
    _ expected: ExpectedWritePreference
  ) {
    self.name = name
    self.arguments = arguments
    self.expected = expected
  }

  var testDescription: String { name }
}

enum CycleSelection: Equatable {
  case defaultModes
  case explicit([String])
}

struct CycleCase: Sendable, CustomTestStringConvertible {
  let name: String
  let argument: String
  let expected: [String]

  init(_ name: String, _ argument: String, _ expected: [String]) {
    self.name = name
    self.argument = argument
    self.expected = expected
  }

  var testDescription: String { name }
}

struct NextModeCase: Sendable, CustomTestStringConvertible {
  let name: String
  let current: String?
  let within: [String]
  let expected: String

  init(
    _ name: String,
    current: String?,
    within: [String],
    expected: String
  ) {
    self.name = name
    self.current = current
    self.within = within
    self.expected = expected
  }

  var testDescription: String { name }
}

private func listeningModeSet(from command: CLICommand) -> ListeningMode? {
  guard case let .listeningModeSet(mode) = command else { return nil }
  return mode
}

private func isStatusCommand(_ command: CLICommand) -> Bool {
  if case .status = command { return true }
  return false
}

private func writePreference(
  from command: CLICommand
) -> ExpectedWritePreference? {
  guard case let .supportReport(writeTests: preference) = command else {
    return nil
  }
  switch preference {
  case .ask: return .ask
  case .always: return .always
  case .never: return .never
  }
}

private func cycleSelection(from command: CLICommand) -> CycleSelection? {
  guard case let .listeningModeCycle(requested) = command else { return nil }
  guard let requested else { return .defaultModes }
  return .explicit(requested.map(\.rawValue))
}
