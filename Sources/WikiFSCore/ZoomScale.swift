import CoreGraphics

/// Pure, stateless namespace for text-zoom arithmetic used by the reader and
/// editor surfaces.
///
/// All state lives in `@AppStorage` on the UI side; this type owns every
/// clamping and stepping calculation so the UI layer is dumb — it passes the
/// current value in and gets the next value out.
///
/// ```swift
/// // zoom in
/// readerZoom = ZoomScale.zoomedIn(readerZoom)
///
/// // zoom out
/// readerZoom = ZoomScale.zoomedOut(readerZoom)
///
/// // reset
/// readerZoom = ZoomScale.defaultScale
/// ```
public enum ZoomScale {

    // MARK: - Constants

    /// Smallest allowed zoom multiplier (50 % of nominal size).
    public static let minimum: CGFloat = 0.5

    /// Largest allowed zoom multiplier (300 % of nominal size).
    public static let maximum: CGFloat = 3.0

    /// The multiplier applied (or its reciprocal removed) on each zoom step.
    public static let stepFactor: CGFloat = 1.1

    /// The zoom that reproduces the current unscaled appearance (`1× = default`).
    public static let defaultScale: CGFloat = 1.0

    // MARK: - Clamping

    /// Returns `scale` clamped to `minimum...maximum`.
    ///
    /// Non-finite input (`NaN`, `±∞`) cannot be ordered meaningfully and would
    /// poison the font-size math downstream, so it coerces to `defaultScale`
    /// rather than leaking through.
    public static func clamped(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return defaultScale }
        return min(maximum, max(minimum, scale))
    }

    // MARK: - Stepping

    /// Returns the next zoom-in value: `current × stepFactor`, clamped to bounds.
    public static func zoomedIn(_ current: CGFloat) -> CGFloat {
        clamped(current * stepFactor)
    }

    /// Returns the next zoom-out value: `current ÷ stepFactor`, clamped to bounds.
    public static func zoomedOut(_ current: CGFloat) -> CGFloat {
        clamped(current / stepFactor)
    }

    // MARK: - Scroll accumulation

    /// Distance a Cmd+scroll gesture must accumulate before it advances one zoom
    /// step. Cmd+scroll (especially on a trackpad) streams many tiny deltas; a
    /// threshold keeps a single flick from rocketing across the whole range.
    public static let scrollStepThreshold: CGFloat = 12

    /// Splits an accumulated scroll-wheel delta into a whole number of zoom steps
    /// plus the leftover remainder to carry into the next event.
    ///
    /// A positive delta zooms in, negative zooms out. Only whole multiples of
    /// `threshold` are consumed; the sub-threshold remainder is returned so
    /// momentum is neither lost nor double-counted across events. Non-finite
    /// input or a non-positive threshold yields no step and drops the remainder.
    public static func scrollSteps(
        accumulated: CGFloat,
        threshold: CGFloat = scrollStepThreshold
    ) -> (steps: Int, remainder: CGFloat) {
        guard threshold > 0, accumulated.isFinite else { return (0, 0) }
        let whole = (accumulated / threshold).rounded(.towardZero)
        return (Int(whole), accumulated - whole * threshold)
    }
}
