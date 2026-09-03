import Darwin
import Foundation

// Debug diagnostics and support-report prompts are written straight to the
// process's standard error, so assertions can inspect the real output stream.
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
