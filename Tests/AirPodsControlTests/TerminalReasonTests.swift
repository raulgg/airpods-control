import Foundation

func runTerminalReasonTests() {
  let normal: [(TerminalReason, Int32, String)] = [
    (.success, 0, "success"),
    (.noDevice, 1, "no-device"),
    (.badArgs, 2, "bad-args"),
    (.noOp, 3, "no-op"),
    (.unsupported, 4, "unsupported"),
    (.readError, 5, "read-error"),
    (.unavailable, 6, "unavailable"),
    (.stateUncertain, 7, "state-uncertain"),
    (.ambiguousDevice, 8, "ambiguous-device"),
  ]

  check(Set(normal.map { $0.1 }).count == normal.count, "normal exit codes are unique")
  for (reason, code, token) in normal {
    check(reason.exitCode == code, "\(token) uses exit code \(code)")
    check(reason.token == token, "exit code \(code) uses token \(token)")
  }

  let success = TerminalReason.success.addingEnvelope(to: ["value": "kept"])
  check(success["result"] as? String == "ok", "success uses the ok result")
  check(success["error"] == nil, "success omits error")
  check(success["value"] as? String == "kept", "success keeps command data")

  let noOp = TerminalReason.noOp.addingEnvelope(to: [:])
  check(noOp["result"] as? String == "no-op", "no-op uses the no-op result")
  check(noOp["error"] == nil, "no-op omits error")

  for (reason, _, token) in normal where reason != .success && reason != .noOp {
    let payload = reason.addingEnvelope(to: [:])
    check(payload["result"] as? String == "error", "\(token) uses the error result")
    check(payload["error"] as? String == token, "\(token) is the canonical JSON error")
  }

  for signal: Int32 in [SIGHUP, SIGINT, SIGTERM] {
    let reason = TerminalReason.caughtSignal(signal)
    let payload = reason.addingEnvelope(to: [:])
    check(reason.exitCode == 128 + signal, "signal \(signal) keeps conventional exit code")
    check(payload["result"] as? String == "interrupted", "signal uses interrupted result")
    check(payload["signal"] as? Int32 == signal, "signal payload keeps its number")
    check(payload["error"] == nil, "signal payload omits error")
  }
}
