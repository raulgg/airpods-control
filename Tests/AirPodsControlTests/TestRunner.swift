import Darwin

@main
struct TestRunner {
  static func main() {
    if let status = runAllowOffCacheLockHolderCommandIfRequested() {
      exit(status)
    }

    runCLIParsingTests()
    runInteractiveDeviceChooserTests()
    runListeningModeTests()
    runListeningModeAllowOffCacheTests()
    runListeningModeCoordinatorTests()
    runCommandExecutionTests()
    runPrivateAudioDiscoveryTests()
    runCoreAudioListeningModePropertyTests()
    runCoreAudioInEarPlacementPropertyTests()
    runHALListeningModeCandidateTests()
    runAudioRoutingTests()
    runStatusCommandTests()
    runPrivateAudioTests()
    runAppleAudioProductsTests()
    runAirPodsBLEFrameTests()
    runBluetoothAssociationStoreTests()
    runBluetoothScannerTests()
    runBluetoothPlacementTests()
    runBluetoothStatusCoordinatorTests()
    runBluetoothCommandTests()
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
