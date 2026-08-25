import Darwin

@main
struct TestRunner {
  static func main() {
    runCLIParsingTests()
    runInteractiveDeviceChooserTests()
    runListeningModeTests()
    runListeningModeCoordinatorTests()
    runCommandExecutionTests()
    runPrivateAudioDiscoveryTests()
    runCoreAudioListeningModePropertyTests()
    runHALListeningModeCandidateTests()
    runAudioRoutingTests()
    runStatusCommandTests()
    runPrivateAudioTests()
    runAppleAudioProductsTests()
    runSupportReportTests()
    runSupportReportWriteFlowTests()
    runSupportReportWriteTesterTests()
    runSupportReportProgressTests()

    if failureCount > 0 {
      fputs("Swift tests failed: \(failureCount)\n", stderr)
      exit(1)
    }
    print("Swift command and private-audio tests passed")
  }
}
