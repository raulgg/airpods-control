enum SupportReportWriteTestProgressOperation: Equatable {
  case listeningMode(ListeningMode)
  case listeningModeRestoration
  case conversationAwareness
  case conversationAwarenessRestoration

  var activeLabel: String { labeled(skipping: false) }

  var skippedLabel: String { labeled(skipping: true) }

  var isListeningModeProgress: Bool {
    switch self {
    case .listeningMode, .listeningModeRestoration: return true
    case .conversationAwareness, .conversationAwarenessRestoration: return false
    }
  }

  private func labeled(skipping: Bool) -> String {
    switch self {
    case let .listeningMode(mode):
      return skipping
        ? "Skipping listening mode: \(mode.displayName)…"
        : "Testing listening mode: \(mode.displayName)…"
    case .listeningModeRestoration:
      return skipping
        ? "Skipping listening mode restoration…"
        : "Restoring listening mode…"
    case .conversationAwareness:
      return skipping
        ? "Skipping Conversation Awareness…"
        : "Testing Conversation Awareness…"
    case .conversationAwarenessRestoration:
      return skipping
        ? "Skipping Conversation Awareness restoration…"
        : "Restoring Conversation Awareness…"
    }
  }
}

struct SupportReportWriteTestProgressPlan {
  let operations: [SupportReportWriteTestProgressOperation]

  init(_ plan: SupportReportWriteTestPlan) {
    var operations: [SupportReportWriteTestProgressOperation] = []
    if plan.willTestListeningModes {
      operations.append(contentsOf: plan.listeningModeTargets.map {
        .listeningMode($0)
      })
      operations.append(.listeningModeRestoration)
    }
    if plan.willTestConversationAwareness {
      operations.append(contentsOf: [
        .conversationAwareness,
        .conversationAwarenessRestoration,
      ])
    }
    self.operations = operations
  }
}

enum SupportReportWriteTestProgressEvent: Equatable {
  case preparing
  case operationStarted(
    SupportReportWriteTestProgressOperation,
    step: Int,
    total: Int
  )
  case operationSkipped(
    SupportReportWriteTestProgressOperation,
    step: Int,
    total: Int
  )
  case interrupted(signal: Int32)
  case restorationFailed
  case finished
}

struct SupportReportWriteTestProgressReporter {
  private let plan: SupportReportWriteTestProgressPlan
  private let report: (SupportReportWriteTestProgressEvent) -> Void

  init(
    plan: SupportReportWriteTestPlan,
    report: @escaping (SupportReportWriteTestProgressEvent) -> Void
  ) {
    self.plan = SupportReportWriteTestProgressPlan(plan)
    self.report = report
  }

  func preparing() {
    report(.preparing)
  }

  func started(_ operation: SupportReportWriteTestProgressOperation) {
    let position = position(of: operation)
    report(.operationStarted(operation, step: position.step, total: position.total))
  }

  func skipped(_ operation: SupportReportWriteTestProgressOperation) {
    let position = position(of: operation)
    report(.operationSkipped(operation, step: position.step, total: position.total))
  }

  func skipped(_ operations: [SupportReportWriteTestProgressOperation]) {
    operations.forEach(skipped)
  }

  func skippedListeningModes() {
    skipped(plan.operations.filter(\.isListeningModeProgress))
  }

  func skippedConversationAwareness() {
    skipped(plan.operations.filter { !$0.isListeningModeProgress })
  }

  func interrupted(by signal: Int32) {
    report(.interrupted(signal: signal))
  }

  func restorationFailed() {
    report(.restorationFailed)
  }

  func finished() {
    report(.finished)
  }

  private func position(
    of operation: SupportReportWriteTestProgressOperation
  ) -> (step: Int, total: Int) {
    guard let index = plan.operations.firstIndex(of: operation) else {
      preconditionFailure("Progress operation is not part of the write-test plan")
    }
    return (index + 1, plan.operations.count)
  }
}
