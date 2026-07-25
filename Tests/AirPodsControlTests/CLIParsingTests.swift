func testCLIParsing() {
  let aliases: [(String, ListeningMode)] = [
    ("anc", .noiseCancellation),
    ("nc", .noiseCancellation),
    ("trans", .transparency),
    ("automatic", .adaptive),
    ("auto", .adaptive),
  ]

  for (alias, expected) in aliases {
    do {
      let invocation = try parseInvocation(["lm", "set", alias])
      if case let .listeningModeSet(mode) = invocation.command {
        check(mode == expected, "alias \(alias) canonicalizes to \(expected.rawValue)")
      } else {
        check(false, "alias \(alias) parses as listening-mode set")
      }
    } catch {
      check(false, "alias \(alias) parses successfully")
    }
  }

  expectParseFailure(["lm", "set", "normal"], "off has no alias")

  do {
    let invocation = try parseInvocation([
      "--debug", "lm", "--device", "RAUL’S AIRPODS PRO", "get", "--json",
    ])
    check(invocation.debugEnabled, "--debug is accepted anywhere")
    check(invocation.jsonOutput, "--json is accepted anywhere")
    check(
      invocation.requestedDeviceName == "RAUL’S AIRPODS PRO",
      "--device preserves the requested name"
    )
  } catch {
    check(false, "mixed global flag placement parses")
  }

  expectParseFailure(["--device", "A", "--device", "B", "lm", "get"], "duplicate device")
  expectParseFailure(["lm", "get", "--device"], "missing device name")
  expectParseFailure(["--debug", "--debug", "lm", "get"], "duplicate debug")
  expectParseFailure(["--device", "AirPods", "version"], "device is invalid for version")

  do {
    let invocation = try parseInvocation(["support-report"])
    if case .supportReport = invocation.command {
      check(true, "support-report parses as its contributor command")
    } else {
      check(false, "support-report parses as its contributor command")
    }
  } catch {
    check(false, "support-report parses successfully")
  }
  expectParseFailure(["support-report", "extra"], "support-report takes no arguments")
  expectParseFailure(["support-report", "--json"], "support-report rejects JSON output")
  expectParseFailure(["support-report", "--debug"], "support-report rejects debug output")
  expectParseFailure(
    ["--device", "AirPods", "support-report"],
    "support-report rejects raw-name device selection"
  )
}

func testCycleParsing() {
  do {
    let invocation = try parseInvocation(["lm", "cycle"])
    if case let .listeningModeCycle(requested) = invocation.command {
      check(requested == nil, "bare cycle uses the default cycle set")
    } else {
      check(false, "bare cycle parses as listening-mode cycle")
    }
  } catch {
    check(false, "bare cycle parses successfully")
  }

  do {
    let invocation = try parseInvocation(["lm", "cycle", "--modes", "anc,trans"])
    if case let .listeningModeCycle(requested) = invocation.command {
      check(
        requested == [.transparency, .noiseCancellation],
        "cycle modes canonicalize aliases and sort into canonical order"
      )
    } else {
      check(false, "cycle with --modes parses as listening-mode cycle")
    }
  } catch {
    check(false, "cycle with aliased modes parses successfully")
  }

  do {
    let invocation = try parseInvocation(
      ["lm", "cycle", "--modes", "noise-cancellation,off,transparency"]
    )
    if case let .listeningModeCycle(requested) = invocation.command {
      check(
        requested == [.off, .transparency, .noiseCancellation],
        "off sorts first in the cycle set"
      )
    } else {
      check(false, "cycle with off parses as listening-mode cycle")
    }
  } catch {
    check(false, "cycle with off parses successfully")
  }

  expectParseFailure(["lm", "cycle", "extra"], "cycle takes no positional arguments")
  expectParseFailure(["lm", "cycle", "--modes"], "missing cycle modes value")
  expectParseFailure(["lm", "cycle", "--modes", "transparency"], "one mode is not a cycle")
  expectParseFailure(
    ["lm", "cycle", "--modes", "trans,transparency"],
    "aliases dedupe before the two-mode minimum"
  )
  expectParseFailure(["lm", "cycle", "--modes", "transparency,normal"], "unknown cycle token")
  expectParseFailure(["lm", "cycle", "--modes", ",transparency,adaptive"], "empty cycle token")
  expectParseFailure(
    ["lm", "cycle", "--modes", "a,b", "--modes", "a,b"],
    "duplicate --modes flag"
  )
  expectParseFailure(["lm", "get", "--modes", "transparency,adaptive"], "modes only for cycle")
  expectParseFailure(["--modes", "transparency,adaptive", "version"], "modes invalid for version")
}

func testNextCycleMode() {
  let all = ListeningMode.allCases
  let noOff = ListeningMode.allCases.filter { $0 != .off }

  check(
    ListeningMode.next(current: .transparency, within: noOff) == .adaptive,
    "cycle advances in canonical order"
  )
  check(
    ListeningMode.next(current: .noiseCancellation, within: noOff) == .transparency,
    "cycle wraps to the set's first mode"
  )
  check(
    ListeningMode.next(current: .noiseCancellation, within: all) == .off,
    "cycle wraps through off when it is in the set"
  )
  check(
    ListeningMode.next(
      current: .adaptive,
      within: [.transparency, .noiseCancellation]
    ) == .noiseCancellation,
    "a current mode outside the set folds into canonical order"
  )
  check(
    ListeningMode.next(current: .adaptive, within: [.off, .transparency]) == .off,
    "folding wraps past the end of the canonical order"
  )
  check(
    ListeningMode.next(current: .off, within: noOff) == .transparency,
    "cycling out of off enters the set in canonical order"
  )
  check(
    ListeningMode.next(current: nil, within: noOff) == .transparency,
    "an unknown current mode starts at the set's first mode"
  )
}

func runCLIParsingTests() {
  testCLIParsing()
  testCycleParsing()
  testNextCycleMode()
}
