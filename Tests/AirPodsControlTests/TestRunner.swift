import Darwin

@main
struct TestRunner {
  static func main() {
    runCLIParsingTests()
    runListeningModeTests()
    runCommandExecutionTests()
    runPrivateAudioTests()
    runSupportReportTests()
    runSupportWriteTestsTests()

    if failureCount > 0 {
      fputs("Swift tests failed: \(failureCount)\n", stderr)
      exit(1)
    }
    print("Swift command and private-audio tests passed")
  }
}
