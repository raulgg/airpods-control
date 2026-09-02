import Darwin

@main
struct TestRunner {
  static func main() {
    if let status = runAllowOffCacheLockHolderCommandIfRequested() {
      exit(status)
    }

    runTestGroup("Allow Off cache", runListeningModeAllowOffCacheTests)

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
