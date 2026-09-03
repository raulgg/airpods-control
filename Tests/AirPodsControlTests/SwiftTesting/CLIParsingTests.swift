import Testing

@testable import AirPodsControlCore

@Suite("CLI parsing")
struct CLIParsingTests {
  @Test("Parses representative command workflows")
  func parsesCommandWorkflows() throws {
    let aliases: [(String, ListeningMode)] = [
      ("anc", .noiseCancellation),
      ("nc", .noiseCancellation),
      ("trans", .transparency),
      ("automatic", .adaptive),
      ("auto", .adaptive),
    ]
    for (alias, expected) in aliases {
      let invocation = try parseInvocation(["lm", "set", alias])
      let mode = try #require(listeningModeSet(from: invocation.command))
      #expect(mode == expected)
    }

    let get = try parseInvocation([
      "--debug", "lm", "--device", "RAUL’S AIRPODS PRO", "get", "--json",
    ])
    #expect(get.debugEnabled)
    #expect(get.jsonOutput)
    #expect(get.requestedDeviceName == "RAUL’S AIRPODS PRO")

    let supportReportCases: [([String], ExpectedWritePreference)] = [
      (["support-report"], .ask),
      (["support-report", "--with-write-tests"], .always),
      (["--no-write-tests", "support-report"], .never),
    ]
    for (arguments, expected) in supportReportCases {
      let invocation = try parseInvocation(arguments)
      let preference = try #require(writePreference(from: invocation.command))
      #expect(preference == expected)
    }

    let supportReport = try parseInvocation(["support-report", "--debug"])
    #expect(supportReport.debugEnabled)
    #expect(!supportReport.jsonOutput)
    #expect(writePreference(from: supportReport.command) == .ask)

    let status = try parseInvocation([
      "--debug", "status", "--device", "Studio Beats", "--json",
    ])
    #expect(isStatusCommand(status.command))
    #expect(status.debugEnabled)
    #expect(status.jsonOutput)
    #expect(status.requestedDeviceName == "Studio Beats")

    let defaultCycle = try parseInvocation(["lm", "cycle"])
    #expect(cycleModes(from: defaultCycle.command) == [])

    let explicitCycles: [(String, [ListeningMode])] = [
      ("anc,trans", [.transparency, .noiseCancellation]),
      (
        "noise-cancellation,off,transparency",
        [.off, .transparency, .noiseCancellation]
      ),
    ]
    for (argument, expected) in explicitCycles {
      let invocation = try parseInvocation([
        "lm", "cycle", "--modes", argument,
      ])
      #expect(cycleModes(from: invocation.command) == expected)
    }
  }

  @Test("Rejects invalid command workflows")
  func rejectsInvalidCommandWorkflows() {
    let invalidInvocations = [
      ["lm", "set", "normal"],
      ["--device", "A", "--device", "B", "lm", "get"],
      ["lm", "get", "--device"],
      ["lm", "get", "--device", "--modes"],
      ["--debug", "--debug", "lm", "get"],
      ["--device", "AirPods", "version"],
      ["support-report", "--with-write-tests", "--no-write-tests"],
      ["support-report", "--with-write-tests", "--with-write-tests"],
      ["lm", "get", "--with-write-tests"],
      ["--no-write-tests", "version"],
      ["support-report", "extra"],
      ["support-report", "--json"],
      ["--device", "AirPods", "support-report"],
      ["st"],
      ["status", "extra"],
      ["status", "--modes", "transparency,adaptive"],
      ["status", "--with-write-tests"],
      ["status", "--no-write-tests"],
      ["lm", "cycle", "extra"],
      ["lm", "cycle", "--modes"],
      ["lm", "cycle", "--modes", "transparency"],
      ["lm", "cycle", "--modes", "trans,transparency"],
      ["lm", "cycle", "--modes", "transparency,normal"],
      ["lm", "cycle", "--modes", ",transparency,adaptive"],
      ["lm", "cycle", "--modes", "a,b", "--modes", "a,b"],
      ["lm", "get", "--modes", "transparency,adaptive"],
      ["--modes", "transparency,adaptive", "version"],
    ]

    for arguments in invalidInvocations {
      #expect(throws: CLIParseError.self, "Accepted \(arguments)") {
        _ = try parseInvocation(arguments)
      }
    }
  }

  @Test("Selects the next mode through a complete cycle")
  func selectsNextCycleMode() {
    let noOff = ListeningMode.allCases.filter { $0 != .off }
    let cases: [(ListeningMode?, [ListeningMode], ListeningMode)] = [
      (.transparency, noOff, .adaptive),
      (.noiseCancellation, noOff, .transparency),
      (.noiseCancellation, ListeningMode.allCases, .off),
      (.adaptive, [.transparency, .noiseCancellation], .noiseCancellation),
      (.adaptive, [.off, .transparency], .off),
      (.off, noOff, .transparency),
      (nil, noOff, .transparency),
    ]

    for (current, cycle, expected) in cases {
      #expect(ListeningMode.next(current: current, within: cycle) == expected)
    }
  }
}

private enum ExpectedWritePreference: Equatable {
  case ask
  case always
  case never
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

private func cycleModes(from command: CLICommand) -> [ListeningMode]? {
  guard case let .listeningModeCycle(requested) = command else { return nil }
  return requested ?? []
}
