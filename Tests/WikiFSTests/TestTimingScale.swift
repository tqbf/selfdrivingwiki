import Foundation

/// Wall-clock scaling for deadline-sensitive timing windows in tests.
///
/// CI's 3-vCPU runner exhibits multi-second cooperative-thread-pool
/// scheduling latency under load (the #664/#1003/#1021 family), which makes
/// fixed millisecond-scale budgets and one-shot flag assertions flaky even in
/// `.serialized` suites. Deadline-based tests multiply their windows by this
/// factor: 1× on developer machines (6+ cores — tests stay fast), 4× on
/// small-core CI runners. Scale DURATIONS ONLY — never weaken ordering or
/// equality assertions; a scaled window still tests the same race, just with
/// more headroom for scheduler noise.
///
/// `TEST_TIMING_SCALE` overrides the computed factor (minimum 1) so a laptop
/// can rehearse the CI-shaped windows locally.
enum TestTimingScale {
    static let factor: Double = {
        if let raw = ProcessInfo.processInfo.environment["TEST_TIMING_SCALE"],
           let overridden = Double(raw), overridden >= 1 {
            return overridden
        }
        return ProcessInfo.processInfo.activeProcessorCount >= 6 ? 1 : 4
    }()

    /// Scale a millisecond duration.
    static func milliseconds(_ ms: Int) -> Int {
        Int((Double(ms) * factor).rounded())
    }
}
