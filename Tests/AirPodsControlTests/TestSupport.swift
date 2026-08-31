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

// Debug diagnostics and support-report prompts are written straight to the
// process's standard error, so asserting on them means redirecting the real file
// descriptor. Nothing inside body may call check(): its failure text would be
// captured instead of reported.
func capturingStandardError(_ body: () -> Void) -> String? {
  guard let capture = tmpfile() else { return nil }
  fflush(stderr)
  let original = dup(STDERR_FILENO)
  guard original >= 0 else {
    fclose(capture)
    return nil
  }
  dup2(fileno(capture), STDERR_FILENO)

  body()

  fflush(stderr)
  dup2(original, STDERR_FILENO)
  close(original)

  rewind(capture)
  var captured = [UInt8]()
  var buffer = [UInt8](repeating: 0, count: 1024)
  while true {
    let readCount = fread(&buffer, 1, buffer.count, capture)
    guard readCount > 0 else { break }
    captured.append(contentsOf: buffer[0..<readCount])
  }
  fclose(capture)
  return String(decoding: captured, as: UTF8.self)
}

func commandOutcome(
  _ arguments: [String],
  device: any CompatibleAudioDevice
) -> CommandOutcome {
  let invocation = try! parseInvocation(arguments)
  return CommandExecution.execute(invocation) { _, _ in device }
}

extension FakeCompatibleAudioDevice: ListeningModeTransport {
  var listeningModeTransportKind: ListeningModeTransportKind { .av }
}

extension CommandExecution {
  static func execute(
    _ invocation: CLIInvocation,
    resolveDevice: (
      _ requestedName: String?,
      _ logger: DebugLogger
    ) -> (any CompatibleAudioDevice)?,
    supportReport: SupportReportCommand = SupportReportCommand()
  ) -> CommandOutcome {
    if ListeningModeCommand(invocation.command) != nil {
      return executeListeningMode(
        invocation,
        resolveSession: { command, requestedName, logger in
          guard let transport = resolveDevice(requestedName, logger)
            as? any ListeningModeTransport
          else { return .noDevice }
          let name = transport.name ?? "Compatible device"
          let coordinator = ListeningModeCoordinator(
            candidates: [
              ListeningModeCandidate(
                displayName: name,
                selectableNames: [name],
                avTransport: transport,
                halTransport: nil,
                route: .unknown
              )
            ],
            logger: logger
          )
          return coordinator.resolve(
            command: command,
            named: requestedName,
            chooseAmbiguous: { _ in .unavailable }
          )
        }
      )
    }
    return execute(
      invocation,
      resolveDevices: { requestedName, _, logger in
        guard let device = resolveDevice(requestedName, logger) else {
          return .failed(.noDevice)
        }
        return .devices([device])
      },
      supportReport: supportReport
    )
  }
}

// Builds a read-only document for tests. Tests with writes should capture the
// snapshot first, run the writes, and then build the document.
func passiveSupportReport(
  device: any CompatibleAudioDevice,
  operatingSystemVersion: OperatingSystemVersion =
    ProcessInfo.processInfo.operatingSystemVersion
) -> SupportReportDocument? {
  .some(
    SupportReportDocument.make(
      snapshot: SupportReportSnapshot.capture(
        device: device,
        operatingSystemVersion: operatingSystemVersion
      )
    )
  )
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
