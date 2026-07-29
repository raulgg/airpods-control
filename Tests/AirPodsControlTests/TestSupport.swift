import Foundation

var failureCount = 0

func check(_ condition: @autoclosure () -> Bool, _ description: String) {
  if !condition() {
    fputs("FAIL: \(description)\n", stderr)
    failureCount += 1
  }
}

func expectParseFailure(_ args: [String], _ description: String) {
  do {
    _ = try parseInvocation(args)
    check(false, description)
  } catch {
    check(true, description)
  }
}

func commandOutcome(
  _ arguments: [String],
  device: any CompatibleAudioDevice
) -> CommandOutcome {
  let invocation = try! parseInvocation(arguments)
  return CommandExecution.execute(invocation) { _, _ in device }
}

// Builds a read-only document for tests. Tests with writes should capture the
// snapshot first, run the writes, and then build the document.
func passiveSupportReport(
  device: any CompatibleAudioDevice,
  operatingSystemVersion: OperatingSystemVersion =
    ProcessInfo.processInfo.operatingSystemVersion
) -> SupportReportDocument? {
  SupportReportSnapshot.capture(
    device: device,
    operatingSystemVersion: operatingSystemVersion
  ).map { SupportReportDocument.make(snapshot: $0) }
}

extension SupportReportDocument {
  var terminalOutput: String {
    SupportReportTerminalRenderer.render(self)
  }

  var githubIssueDraft: SupportReportIssueDraft {
    SupportReportGitHubRenderer.render(self)
  }
}

extension CommandOutcome {
  var supportReportOutput: String {
    supportReport?.terminalOutput ?? plain
  }

  var supportReportIssueDraft: SupportReportIssueDraft? {
    guard let supportReport, supportReport.interruptedBySignal == nil else {
      return nil
    }
    return supportReport.githubIssueDraft
  }
}

// Case accessors so tests can assert one payload field without unpacking the
// whole outcome. Production code switches instead; keep it that way.
extension CapabilityWriteTestOutcome {
  var testRun: Run? {
    if case let .ran(run) = self { return run }
    return nil
  }

  var skipReason: String? {
    if case let .skipped(reason) = self { return reason }
    return nil
  }
}

extension RestorationOutcome {
  var attempted: Attempt? {
    if case let .attempted(attempt) = self { return attempt }
    return nil
  }

  var stateNeverChanged: Bool {
    if case .stateNeverChanged = self { return true }
    return false
  }
}
