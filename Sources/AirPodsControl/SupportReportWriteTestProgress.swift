enum SupportReportWriteTestProgressOperation: Equatable {
  case listeningMode(ListeningMode)
  case listeningModeRestoration
  case conversationAwareness
  case conversationAwarenessRestoration

  var activeLabel: String { labeled(skipping: false) }

  var skippedLabel: String { labeled(skipping: true) }

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
  let listeningModeOperations: [SupportReportWriteTestProgressOperation]
  let conversationAwarenessOperations: [SupportReportWriteTestProgressOperation]

  var operations: [SupportReportWriteTestProgressOperation] {
    listeningModeOperations + conversationAwarenessOperations
  }

  init(_ plan: SupportReportWriteTestPlan) {
    var listeningModeOperations: [SupportReportWriteTestProgressOperation] = []
    if case let .willTest(payload) = plan.listeningModes {
      listeningModeOperations.append(contentsOf: payload.targets.map {
        .listeningMode($0)
      })
      listeningModeOperations.append(.listeningModeRestoration)
    }
    var conversationAwarenessOperations: [SupportReportWriteTestProgressOperation] = []
    if case .willTest = plan.conversationAwareness {
      conversationAwarenessOperations.append(contentsOf: [
        .conversationAwareness,
        .conversationAwarenessRestoration,
      ])
    }
    self.listeningModeOperations = listeningModeOperations
    self.conversationAwarenessOperations = conversationAwarenessOperations
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
    skipped(plan.listeningModeOperations)
  }

  func skippedConversationAwareness() {
    skipped(plan.conversationAwarenessOperations)
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
