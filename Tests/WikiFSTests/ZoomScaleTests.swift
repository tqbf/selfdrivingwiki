import Testing
@testable import WikiFSCore

/// Tests for `ZoomScale` (reader-editor-zoom §1).
///
/// All floating-point comparisons use a tolerance; Double arithmetic can
/// accumulate rounding error so exact equality is not asserted.
struct ZoomScaleTests {

    // MARK: - Tolerance helper

    /// Returns true when `a` and `b` differ by less than `eps`.
    private func isClose(_ a: Double, _ b: Double, eps: Double = 1e-10) -> Bool {
        abs(a - b) < eps
    }

    // MARK: - Constants

    @Test func defaultScaleIsOne() {
        #expect(ZoomScale.defaultScale == 1.0)
    }

    /// The plan locks these values as decisions; pin the literals so a silent
    /// regression (e.g. maximum → 5.0) fails here rather than passing every
    /// other test that references the constants symbolically.
    @Test func specConstantsMatchLockedValues() {
        #expect(ZoomScale.minimum == 0.5)
        #expect(ZoomScale.maximum == 3.0)
        #expect(ZoomScale.stepFactor == 1.1)
    }

    // MARK: - Clamping

    @Test func clampedBelowMinimumReturnsMinimum() {
        #expect(ZoomScale.clamped(0.0) == ZoomScale.minimum)
        #expect(ZoomScale.clamped(-1.0) == ZoomScale.minimum)
        #expect(ZoomScale.clamped(0.49) == ZoomScale.minimum)
    }

    @Test func clampedAboveMaximumReturnsMaximum() {
        #expect(ZoomScale.clamped(10.0) == ZoomScale.maximum)
        #expect(ZoomScale.clamped(3.01) == ZoomScale.maximum)
    }

    @Test func clampedWithinRangeIsUnchanged() {
        let values: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0, 3.0]
        for v in values {
            #expect(ZoomScale.clamped(v) == v)
        }
    }

    @Test func clampedNonFiniteReturnsDefault() {
        // NaN and ±∞ cannot be ordered into the range and must never reach the
        // font math, so they coerce to a finite, in-range default.
        for value: Double in [.nan, .infinity, -.infinity] {
            let result = ZoomScale.clamped(value)
            #expect(result == ZoomScale.defaultScale)
            #expect(result.isFinite)
            #expect(result >= ZoomScale.minimum && result <= ZoomScale.maximum)
        }
    }

    // MARK: - Stepping direction and magnitude

    @Test func zoomedInIncreasesValue() {
        let interior: Double = 1.0
        #expect(ZoomScale.zoomedIn(interior) > interior)
    }

    @Test func zoomedOutDecreasesValue() {
        let interior: Double = 1.0
        #expect(ZoomScale.zoomedOut(interior) < interior)
    }

    @Test func zoomedInAppliesStepFactor() {
        let start: Double = 1.0
        let expected = (start * ZoomScale.stepFactor)
        #expect(isClose(ZoomScale.zoomedIn(start), expected))
    }

    @Test func zoomedOutAppliesStepFactor() {
        let start: Double = 1.0
        let expected = (start / ZoomScale.stepFactor)
        #expect(isClose(ZoomScale.zoomedOut(start), expected))
    }

    // MARK: - Clamping at bounds during stepping

    @Test func zoomedInAtMaximumStaysAtMaximum() {
        #expect(ZoomScale.zoomedIn(ZoomScale.maximum) == ZoomScale.maximum)
    }

    @Test func zoomedInNearMaximumDoesNotExceedMaximum() {
        // One step below maximum — after zooming in the result must not exceed 3.0.
        let nearMax = ZoomScale.maximum / ZoomScale.stepFactor
        #expect(ZoomScale.zoomedIn(nearMax) <= ZoomScale.maximum)
    }

    @Test func zoomedOutAtMinimumStaysAtMinimum() {
        #expect(ZoomScale.zoomedOut(ZoomScale.minimum) == ZoomScale.minimum)
    }

    @Test func zoomedOutNearMinimumDoesNotGoBelowMinimum() {
        // One step above minimum — after zooming out the result must not go below 0.5.
        let nearMin = ZoomScale.minimum * ZoomScale.stepFactor
        #expect(ZoomScale.zoomedOut(nearMin) >= ZoomScale.minimum)
    }

    // MARK: - In / out symmetry

    @Test func zoomedInThenOutReturnsToStart() {
        // For any interior value, out(in(x)) should round-trip back to x.
        let interiorValues: [Double] = [0.7, 1.0, 1.5, 2.0, 2.5]
        for start in interiorValues {
            let roundTripped = ZoomScale.zoomedOut(ZoomScale.zoomedIn(start))
            #expect(isClose(roundTripped, start),
                    "round-trip failed for \(start): got \(roundTripped)")
        }
    }

    // MARK: - Scroll accumulation

    @Test func scrollBelowThresholdTakesNoStepAndCarriesRemainder() {
        let t = ZoomScale.scrollStepThreshold
        let (steps, remainder) = ZoomScale.scrollSteps(accumulated: t - 1, threshold: t)
        #expect(steps == 0)
        #expect(isClose(remainder, t - 1))
    }

    @Test func scrollPositiveDeltaZoomsIn() {
        let t = ZoomScale.scrollStepThreshold
        let (steps, remainder) = ZoomScale.scrollSteps(accumulated: t + 3, threshold: t)
        #expect(steps == 1)
        #expect(isClose(remainder, 3))
    }

    @Test func scrollNegativeDeltaZoomsOut() {
        let t = ZoomScale.scrollStepThreshold
        let (steps, remainder) = ZoomScale.scrollSteps(accumulated: -(t + 3), threshold: t)
        #expect(steps == -1)
        #expect(isClose(remainder, -3))
    }

    @Test func scrollMultipleThresholdsTakeMultipleSteps() {
        let t = ZoomScale.scrollStepThreshold
        let (steps, remainder) = ZoomScale.scrollSteps(accumulated: 2 * t + 5, threshold: t)
        #expect(steps == 2)
        #expect(isClose(remainder, 5))
    }

    /// The remainder must always be smaller in magnitude than the threshold, and
    /// `steps * threshold + remainder` must reconstruct the input exactly — so a
    /// stream of events neither loses nor double-counts momentum.
    @Test func scrollRemainderReconstructsInput() {
        let t = ZoomScale.scrollStepThreshold
        let inputs: [Double] = [0, 5, -5, t, -t, 2 * t + 1, -3 * t - 7, 100, -100]
        for input in inputs {
            let (steps, remainder) = ZoomScale.scrollSteps(accumulated: input, threshold: t)
            #expect(abs(remainder) < t)
            #expect(isClose(Double(steps) * t + remainder, input))
        }
    }

    @Test func scrollNonFiniteOrNonPositiveThresholdYieldsNoStep() {
        for bad: Double in [.nan, .infinity, -.infinity] {
            let (steps, remainder) = ZoomScale.scrollSteps(accumulated: bad)
            #expect(steps == 0)
            #expect(remainder == 0)
        }
        let (steps, remainder) = ZoomScale.scrollSteps(accumulated: 50, threshold: 0)
        #expect(steps == 0)
        #expect(remainder == 0)
    }
}
