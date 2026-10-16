import Foundation
import IOKit.pwr_mgt

/// Measures how long the Mac slept during a run: lid closed, a sleep the user chose, or an idle
/// sleep the assertion did not hold off.
struct SleepMeter {
    // Both clocks tick the same way; only the first keeps counting while the Mac is asleep.
    private let total = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    private let awake = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    /// Rounded to a tenth of a second; nil below one second, which is clock noise, not sleep.
    var asleepSeconds: Double? {
        let slept = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - total)
            - Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - awake)
        let seconds = (slept / 1e8).rounded() / 10
        return seconds >= 1 ? seconds : nil
    }
}

/// Holds off idle sleep while a job runs, so a run started just before the Mac would doze off
/// finishes instead of freezing until the next wake. The display still sleeps, and closing the lid
/// still sleeps the Mac.
struct IdleSleepAssertion {
    private var id = IOPMAssertionID(0)
    private let held: Bool

    /// - Parameter limit: released by the system after this many seconds even if the run hangs.
    init(jobID: String, limit: TimeInterval) {
        held = IOPMAssertionCreateWithDescription(
            "PreventUserIdleSystemSleep" as CFString, "Chores: running \(jobID)" as CFString,
            nil, nil, nil, limit, "TimeoutActionRelease" as CFString, &id) == kIOReturnSuccess
    }

    func release() {
        if held { IOPMAssertionRelease(id) }
    }
}
