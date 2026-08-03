import CoreGraphics

/// Pure sizing math for the toolbar omnibox, factored out of `AddressBarView` so
/// the centered/expandable behavior can be unit-tested without a running window.
///
/// **Design (smaller centered omnibox).** The field lives in a `.principal`
/// toolbar item, which NSToolbar centers in the detail region. Its width stays
/// conservative so fixed leading and trailing toolbar items keep their slots and
/// the toolbar avoids the `»` overflow.
///
/// All that remains is the field's **width**: it grows with the detail region,
/// keeps enough symmetrical margin to clear surrounding chrome, and stops at a
/// compact cap.
enum OmniboxLayout {
    struct Metrics: Equatable {
        /// Breathing room reserved on each side of the centered field when the
        /// left sidebar is shown. This clears the nav-button cluster.
        var sideMarginOpen: CGFloat
        /// Breathing room reserved on each side of the centered field when the
        /// left sidebar is hidden. The detail region then spans the window, so
        /// traffic lights and the system sidebar toggle also need room.
        var sideMarginClosed: CGFloat
        /// The field never shrinks below this (a couple of words) — on a very
        /// narrow window the margins give instead.
        var minWidth: CGFloat
        /// The field never grows beyond this compact cap, so it stays centered
        /// without competing with trailing toolbar controls.
        var maxWidth: CGFloat
        /// Width reserved for trailing toolbar chrome that shares the detail
        /// region with the centered field: the wiki switcher and persistent
        /// right-inspector toggle.
        var trailingChromeWidth: CGFloat

        static let `default` = Metrics(
            sideMarginOpen: 220,
            sideMarginClosed: 320,
            minWidth: 240,
            maxWidth: 560,
            trailingChromeWidth: 220)
    }

    /// The side margin reserved on each side of the centered field, chosen by
    /// sidebar state and trailing toolbar chrome.
    static func sideMargin(sidebarVisible: Bool, metrics: Metrics = .default) -> CGFloat {
        max(sidebarVisible ? metrics.sideMarginOpen : metrics.sideMarginClosed,
            metrics.trailingChromeWidth)
    }

    /// The omnibox field's width for a given detail-region width and sidebar state.
    /// It's the region minus a safe margin on each side, clamped to
    /// `[minWidth, maxWidth]`. Centering itself is handled by `.principal`.
    ///
    /// - Parameters:
    ///   - detailWidth: the width of the detail column the toolbar spans, measured
    ///     by a `GeometryReader` in `ContentView`. `0` before first layout yields
    ///     `minWidth` (never a negative or absurd width).
    ///   - sidebarVisible: whether the left sidebar is shown; selects the margin.
    static func fieldWidth(detailWidth: CGFloat, sidebarVisible: Bool,
                           metrics: Metrics = .default) -> CGFloat {
        guard detailWidth > 0 else { return metrics.minWidth }
        let available = detailWidth - 2 * sideMargin(sidebarVisible: sidebarVisible,
                                                     metrics: metrics)
        return min(max(available, metrics.minWidth), metrics.maxWidth)
    }
}
