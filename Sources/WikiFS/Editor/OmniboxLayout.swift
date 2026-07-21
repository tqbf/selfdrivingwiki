import CoreGraphics

/// Pure sizing math for the toolbar omnibox, factored out of `AddressBarView` so
/// the centered/expandable behavior can be unit-tested without a running window.
///
/// **Design (Safari-style centered omnibox).** The field lives in a `.principal`
/// toolbar item, which NSToolbar *centers* in the detail region for us — so this
/// type no longer tries to predict NSToolbar's internal insets to hand-position
/// the field (the old leading-chrome / trailing-margin / overflow-spacer math,
/// which was a stack of hand-tuned constants that tipped the whole `.navigation`
/// group into the `»` overflow whenever any guess was slightly off).
///
/// All that remains is the field's **width**: it grows with the detail region,
/// keeping a comfortable margin on each side (so it reads as a centered pill, and
/// crucially never approaches 100% of the region — the condition that used to
/// trigger the all-or-nothing toolbar overflow), and it stops growing at a
/// readable cap so it isn't one unbroken line on a very wide monitor. Centering
/// is NSToolbar's job; this is only how wide the pill is at a given window size.
enum OmniboxLayout {
    struct Metrics: Equatable {
        /// Breathing room reserved on *each* side of the centered field when the
        /// **sidebar is shown**. The field is a symmetrically-centered `.principal`
        /// item, so in the growing regime its side margin equals this value — and
        /// NSToolbar bails the whole group to the `»` overflow if centering would
        /// crowd the flush-left leading chrome. With the sidebar shown the traffic
        /// lights sit over the sidebar, so the only leading chrome inside the
        /// detail region is the `OmniboxNavButtons` cluster (~102pt with its
        /// bubble inset); this must clear it with room to spare.
        var sideMarginOpen: CGFloat
        /// Same, but when the **sidebar is hidden** — then the detail region spans
        /// the whole window and the field centers across it, so its left margin
        /// must clear the traffic lights + sidebar-toggle + nav cluster (~250pt),
        /// not just the nav cluster. Symmetric centering can't give the left side
        /// more than the right, so BOTH margins must be this large or the group
        /// overflows on any window narrow enough that the margin drops below the
        /// chrome. This is the single reason the omnibox needs to know the sidebar
        /// state at all.
        var sideMarginClosed: CGFloat
        /// The field never shrinks below this (a couple of words) — on a very
        /// narrow window the margins give instead.
        var minWidth: CGFloat
        /// The field never grows beyond this, so it stays a readable pill rather
        /// than one edge-to-edge line on a wide monitor; past this width the side
        /// margins simply grow.
        var maxWidth: CGFloat

        static let `default` = Metrics(
            sideMarginOpen: 150,
            sideMarginClosed: 290,
            minWidth: 240,
            maxWidth: 820)
    }

    /// The side margin reserved on each side of the centered field, chosen by
    /// sidebar state (see `sideMarginOpen`/`sideMarginClosed`).
    static func sideMargin(sidebarVisible: Bool, metrics: Metrics = .default) -> CGFloat {
        sidebarVisible ? metrics.sideMarginOpen : metrics.sideMarginClosed
    }

    /// The omnibox field's width for a given detail-region width and sidebar state.
    /// It's the region minus a (sidebar-dependent) margin on each side — so the
    /// centered pill keeps enough breathing room to clear the leading chrome and
    /// never fills the region (the old overflow trigger) — clamped to
    /// `[minWidth, maxWidth]`. Centering itself is handled by the `.principal`
    /// toolbar placement; the margin only has to be wide enough that the centered
    /// field doesn't crowd the flush-left chrome (which is larger when the sidebar
    /// is hidden — see `sideMarginClosed`).
    ///
    /// - Parameters:
    ///   - detailWidth: the width of the detail column the toolbar spans, measured
    ///     by a `GeometryReader` in `ContentView`. `0` before first layout yields
    ///     `minWidth` (never a negative or absurd width).
    ///   - sidebarVisible: whether the left sidebar is shown; selects the margin.
    static func fieldWidth(detailWidth: CGFloat, sidebarVisible: Bool,
                           metrics: Metrics = .default) -> CGFloat {
        guard detailWidth > 0 else { return metrics.minWidth }
        let available = detailWidth - 2 * sideMargin(sidebarVisible: sidebarVisible, metrics: metrics)
        return min(max(available, metrics.minWidth), metrics.maxWidth)
    }
}
