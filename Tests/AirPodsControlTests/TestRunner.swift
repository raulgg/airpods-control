import Darwin

@main
struct TestRunner {
  static func main() {
    if let status = runAllowOffCacheLockHolderCommandIfRequested() {
      exit(status)
    }

    runTestGroup("Allow Off cache", runListeningModeAllowOffCacheTests)
    runTestGroup("listening mode coordinator", runListeningModeCoordinatorTests)
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
    runTestGroup(
      "support report write tester",
      runSupportReportWriteTesterTests
    )

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
