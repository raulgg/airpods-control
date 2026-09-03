import Darwin

@main
struct TestRunner {
  static func main() {
    if let status = runAllowOffCacheLockHolderCommandIfRequested() {
      exit(status)
    }

    runTestGroup("Allow Off cache", runListeningModeAllowOffCacheTests)
    runTestGroup("listening mode coordinator", runListeningModeCoordinatorTests)
    runTestGroup("command execution", runCommandExecutionTests)
    runTestGroup("private audio discovery", runPrivateAudioDiscoveryTests)
    runTestGroup(
      "Core Audio listening mode property",
      runCoreAudioListeningModePropertyTests
    )
    runTestGroup(
      "Core Audio in-ear placement property",
      runCoreAudioInEarPlacementPropertyTests
    )
    runTestGroup(
      "HAL listening mode candidate",
      runHALListeningModeCandidateTests
    )
    runTestGroup("audio routing", runAudioRoutingTests)
    runTestGroup("status command", runStatusCommandTests)
    runTestGroup("private audio", runPrivateAudioTests)
    runTestGroup("support report", runSupportReportTests)
    runTestGroup("support report write flow", runSupportReportWriteFlowTests)
    runTestGroup(
      "support report write tester",
      runSupportReportWriteTesterTests
    )
    runTestGroup("support report progress", runSupportReportProgressTests)

    if failureCount > 0 {
      fputs("Swift tests failed: \(failureCount)\n", stderr)
      exit(1)
    }
    print("Swift command and private-audio tests passed")
  }

  private static func runTestGroup(_ name: String, _ body: () -> Void) {
    let failuresBefore = failureCount
    body()
    let newFailures = failureCount - failuresBefore
    print("Swift test group: \(name) (+\(newFailures) failures)")
  }
}
