import Darwin
import Foundation

// Shared across suites because stderr redirection affects the entire process.
private let standardErrorCaptureLock = NSLock()

// Shared across suites that install SupportReportTerminationMonitor, directly
// or through the default support-report write runner. Hold this until all
// signal-handler cleanup finishes; suite serialization cannot protect siblings.
let supportReportSignalMonitorLock = NSLock()

// Debug diagnostics and support-report prompts are written straight to the
// process's standard error, so assertions can inspect the real output stream.
func capturingStandardError(_ body: () throws -> Void) rethrows -> String? {
  standardErrorCaptureLock.lock()
  defer { standardErrorCaptureLock.unlock() }

  guard let capture = tmpfile() else { return nil }
  defer { fclose(capture) }

  fflush(stderr)
  let original = dup(STDERR_FILENO)
  guard original >= 0 else { return nil }
  defer { close(original) }
  guard dup2(fileno(capture), STDERR_FILENO) >= 0 else { return nil }

  do {
    defer {
      fflush(stderr)
      dup2(original, STDERR_FILENO)
    }
    try body()
  }

  rewind(capture)
  var captured = [UInt8]()
  var buffer = [UInt8](repeating: 0, count: 1024)
  while true {
    let readCount = fread(&buffer, 1, buffer.count, capture)
    guard readCount > 0 else { break }
    captured.append(contentsOf: buffer[0..<readCount])
  }
  return String(decoding: captured, as: UTF8.self)

}
