import CoreGraphics

/// Pure sizing math for the toolbar omnibox, factored out of `AddressBarView` so
/// the stretch/overflow behavior can be unit-tested without a running window.
///
/// The view hands this type two things it can measure *reliably*: the detail
/// column's width (from a `GeometryReader` in the always-visible detail content —
/// never pulled into toolbar overflow) and whether the left sidebar is shown.
/// From those it derives the same `(windowWidth, fieldLeadingX)` the core math
/// wants, without ever measuring the field's own leading edge — which the toolbar
/// yanks out of the window when it overflows, stranding the old measurement. See
/// `fieldWidth(detailWidth:sidebarVisible:switcherExtra:)`.
enum OmniboxLayout {
    struct Metrics: Equatable {
        /// Space reserved to the field's right for the trailing Change Log
        /// toggle (the only toolbar item after the omnibox now that the wiki
        /// switcher has moved into the sidebar header).
        var trailingWithSwitcher: CGFloat
        /// Space reserved when the toggle has spilled into the `»` overflow —
        /// only the small overflow button remains, so the field fills nearly to
        /// the window edge.
        var trailingOverflow: CGFloat
        /// The field never shrinks below this (a couple of words); past this point
        /// the switcher is pushed into overflow rather than the field shrinking more.
        var minWidth: CGFloat
        /// The field never grows beyond this, so it isn't an unreadable line on a
        /// very wide monitor.
        var maxWidth: CGFloat
        /// Fixed chrome to the field's left (Back/Forward, the tight gap between
        /// them, and the wider gap to the omnibox pill — `AddressBarMetrics.
        /// navButtonSpacing`/`navToOmniboxGap`) when the sidebar is *shown*. The
        /// traffic-light + sidebar-toggle zone then sits over the sidebar, outside
        /// the measured detail region, so only the nav cluster + gap remain between
        /// the detail region's edge and the field.
        var openLeadingChrome: CGFloat
        /// Fixed chrome to the field's left when the sidebar is *hidden*. The detail
        /// region now spans the whole window, so it includes the traffic lights +
        /// sidebar toggle ahead of the nav cluster — a larger offset.
        var closedLeadingChrome: CGFloat
        /// Extra leading chrome added when the omnibox's Home button is shown (a
        /// wiki with a configured home page, issue #280, adds a fourth nav
        /// button). Equal to the button's own width (`AddressBarMetrics.
        /// navButtonWidth`, 22) plus the one extra internal nav-cluster gap it
        /// introduces (`AddressBarMetrics.navButtonSpacing`, 4). Previously
        /// omitted entirely: the field's leading edge (and therefore its
        /// trailing edge too, since width is computed from it) silently sat 26pt
        /// further right than this math assumed for any wiki with a home page
        /// configured — a WINDOW-WIDTH-INDEPENDENT encroachment into the
        /// trailing switcher/toggle's reserved space, since it's a fixed offset
        /// baked into every window size alike. That wiki's Toggle Transcript
        /// button would sit in the `»` overflow permanently, not just past some
        /// width threshold.
        var homeButtonExtra: CGFloat

        static let `default` = Metrics(
            trailingWithSwitcher: 110,
            trailingOverflow: 60,
            minWidth: 120,
            maxWidth: 1200,
            openLeadingChrome: 70,
            closedLeadingChrome: 214,
            homeButtonExtra: 26)
    }

    /// Fixed chrome to the field's left, measured from the detail region's leading
    /// edge. It differs by sidebar state only because the traffic-light + toggle
    /// zone sits over the detail region when the sidebar is hidden and over the
    /// sidebar when it's shown (see the `Metrics` fields). `homeButtonShown` adds
    /// `homeButtonExtra` for the wiki's optional fourth nav button (issue #280) —
    /// omitting this when the button is shown was the root cause of the Toggle
    /// Transcript button permanently sitting in the toolbar's `»` overflow for
    /// any wiki with a configured home page, at any window width.
    static func leadingChrome(sidebarVisible: Bool, homeButtonShown: Bool = false,
                             metrics: Metrics = .default) -> CGFloat {
        let base = sidebarVisible ? metrics.openLeadingChrome : metrics.closedLeadingChrome
        return homeButtonShown ? base + metrics.homeButtonExtra : base
    }

    /// The omnibox field's width, driven by the reliably-measurable detail-region
    /// width and sidebar state. Delegates to the core `fieldWidth(windowWidth:
    /// fieldLeadingX:…)` — the detail width plays the role of the window width and
    /// the fixed leading chrome the role of the field's leading edge, because the
    /// core only ever uses their difference (the span right of the field's start).
    /// This keeps the stretch/shrink/overflow-expand behavior identical while
    /// sourcing it from a measurement the toolbar can't strand.
    static func fieldWidth(detailWidth: CGFloat, sidebarVisible: Bool, homeButtonShown: Bool = false,
                           switcherExtra: CGFloat, metrics: Metrics = .default) -> CGFloat {
        fieldWidth(windowWidth: detailWidth,
                   fieldLeadingX: leadingChrome(sidebarVisible: sidebarVisible,
                                               homeButtonShown: homeButtonShown, metrics: metrics),
                   switcherExtra: switcherExtra, metrics: metrics)
    }

    /// The field width if the trailing toggle is kept on-screen: the field fills
    /// from its leading edge to just short of the toggle. Can fall below
    /// `minWidth`, which is the signal that the toggle no longer fits.
    static func widthKeepingSwitcher(windowWidth: CGFloat, fieldLeadingX: CGFloat,
                                     switcherExtra: CGFloat, metrics: Metrics = .default) -> CGFloat {
        windowWidth - metrics.trailingWithSwitcher - switcherExtra - fieldLeadingX
    }

    /// Whether the trailing Change Log toggle fits on-screen beside a field no
    /// narrower than `minWidth`. When false, NSToolbar drops the toggle into the
    /// `»` overflow and the field reclaims that trailing space (see `fieldWidth`).
    static func switcherFits(windowWidth: CGFloat, fieldLeadingX: CGFloat,
                             switcherExtra: CGFloat, metrics: Metrics = .default) -> Bool {
        widthKeepingSwitcher(windowWidth: windowWidth, fieldLeadingX: fieldLeadingX,
                             switcherExtra: switcherExtra, metrics: metrics) >= metrics.minWidth
    }

    /// The field width before the `maxWidth` clamp — what the field would need to
    /// be to stay exactly flush against the trailing switcher/overflow button.
    /// Shared by `fieldWidth` (which clamps it for readability) and
    /// `overflowSpacerWidth` (which reports how much of it got clamped away), so
    /// the two always agree on where the true trailing edge is.
    private static func rawFieldWidth(windowWidth: CGFloat, fieldLeadingX: CGFloat,
                                      switcherExtra: CGFloat, metrics: Metrics) -> CGFloat {
        let kept = widthKeepingSwitcher(windowWidth: windowWidth, fieldLeadingX: fieldLeadingX,
                                        switcherExtra: switcherExtra, metrics: metrics)
        return kept >= metrics.minWidth
            ? kept
            : windowWidth - metrics.trailingOverflow - fieldLeadingX
    }

    /// The omnibox field's width. It stretches from its measured leading edge to
    /// just short of the trailing items, shrinks as the window narrows or the wiki
    /// name lengthens, and — once the switcher can no longer fit and drops into the
    /// `»` overflow — expands to fill the freed trailing space.
    ///
    /// - Parameters:
    ///   - windowWidth: the host window's width.
    ///   - fieldLeadingX: the field's x-origin in window coordinates (measured).
    ///   - switcherExtra: how much wider the current wiki name renders than the
    ///     baseline name (may be negative for a shorter name). The switcher's
    ///     fixed icon/chevron overhead is baked into `trailingWithSwitcher`, so
    ///     only the text-width difference is passed here.
    static func fieldWidth(windowWidth: CGFloat, fieldLeadingX: CGFloat,
                           switcherExtra: CGFloat, metrics: Metrics = .default) -> CGFloat {
        guard windowWidth > 0 else { return metrics.minWidth }
        let raw = rawFieldWidth(windowWidth: windowWidth, fieldLeadingX: fieldLeadingX,
                                switcherExtra: switcherExtra, metrics: metrics)
        return min(max(raw, metrics.minWidth), metrics.maxWidth)
    }

    /// Extra invisible width to place immediately after the (possibly capped)
    /// field, inside the same toolbar item, so the trailing wiki switcher and
    /// transcript toggle stay pinned to the window's true trailing edge even once
    /// `fieldWidth` has hit `maxWidth` and stopped growing (issue #114). Below the
    /// cap this is always zero — `fieldWidth` alone already sums exactly to the
    /// trailing edge, same as before this existed.
    static func overflowSpacerWidth(windowWidth: CGFloat, fieldLeadingX: CGFloat,
                                    switcherExtra: CGFloat, metrics: Metrics = .default) -> CGFloat {
        guard windowWidth > 0 else { return 0 }
        let raw = rawFieldWidth(windowWidth: windowWidth, fieldLeadingX: fieldLeadingX,
                                switcherExtra: switcherExtra, metrics: metrics)
        return max(0, raw - metrics.maxWidth)
    }

    /// `overflowSpacerWidth`, sourced from the same measurable `(detailWidth,
    /// sidebarVisible)` pair `fieldWidth(detailWidth:sidebarVisible:switcherExtra:)`
    /// uses, for the same reason: the field's own leading edge gets stranded when
    /// the toolbar pushes it into overflow.
    static func overflowSpacerWidth(detailWidth: CGFloat, sidebarVisible: Bool, homeButtonShown: Bool = false,
                                    switcherExtra: CGFloat, metrics: Metrics = .default) -> CGFloat {
        overflowSpacerWidth(windowWidth: detailWidth,
                            fieldLeadingX: leadingChrome(sidebarVisible: sidebarVisible,
                                                        homeButtonShown: homeButtonShown, metrics: metrics),
                            switcherExtra: switcherExtra, metrics: metrics)
    }
}
