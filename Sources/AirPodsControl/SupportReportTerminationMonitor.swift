import Darwin
import SignalMonitor

final class SupportReportTerminationMonitor {
  private var isDisarmed = false
  private var disarmedSignal: Int32?

  init?() {
    guard airpods_control_signal_monitor_install() == 0 else { return nil }
  }

  var caughtSignal: Int32? {
    let signalNumber = airpods_control_signal_monitor_caught_signal()
    return signalNumber == 0 ? nil : signalNumber
  }

  func disarm() -> Int32? {
    guard !isDisarmed else { return disarmedSignal }
    let signalNumber = airpods_control_signal_monitor_disarm()
    disarmedSignal = signalNumber == 0 ? nil : signalNumber
    isDisarmed = true
    return disarmedSignal
  }

  deinit {
    _ = disarm()
  }
}
