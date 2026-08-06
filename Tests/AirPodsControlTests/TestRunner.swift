import Darwin

@main
struct TestRunner {
  static func main() {
    runCLIParsingTests()
    runListeningModeTests()
    runCommandExecutionTests()
    runPrivateAudioDiscoveryTests()
    runPrivateAudioTests()
    runAppleAudioProductsTests()
    runSupportReportTests()
    runSupportReportWriteFlowTests()
    runSupportReportWriteTesterTests()

    if failureCount > 0 {
      fputs("Swift tests failed: \(failureCount)\n", stderr)
      exit(1)
    }
    print("Swift command and private-audio tests passed")
  }
}
