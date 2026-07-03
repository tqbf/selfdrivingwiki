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
        /// Space reserved to the field's right for the wiki switcher (at the
        /// baseline name length) plus the transcript toggle, when they're shown.
        var trailingWithSwitcher: CGFloat
        /// Space reserved when the switcher + transcript have spilled into the `»`
        /// overflow — only the small overflow button remains, so the field fills
        /// nearly to the window edge.
        var trailingOverflow: CGFloat
        /// The field never shrinks below this (a couple of words); past this point
        /// the switcher is pushed into overflow rather than the field shrinking more.
        var minWidth: CGFloat
        /// The field never grows beyond this, so it isn't an unreadable line on a
        /// very wide monitor.
        var maxWidth: CGFloat
        /// Fixed chrome to the field's left (Back/Forward/magnifier + gaps) when the
        /// sidebar is *shown*. The traffic-light + sidebar-toggle zone then sits over
        /// the sidebar, outside the measured detail region, so only the nav buttons
        /// remain between the detail region's edge and the field.
        var openLeadingChrome: CGFloat
        /// Fixed chrome to the field's left when the sidebar is *hidden*. The detail
        /// region now spans the whole window, so it includes the traffic lights +
        /// sidebar toggle ahead of the nav buttons — a larger offset.
        var closedLeadingChrome: CGFloat

        static let `default` = Metrics(
            trailingWithSwitcher: 180,
            trailingOverflow: 60,
            minWidth: 120,
            maxWidth: 1200,
            openLeadingChrome: 64,
            closedLeadingChrome: 208)
    }

    /// Fixed chrome to the field's left, measured from the detail region's leading
    /// edge. It differs by sidebar state only because the traffic-light + toggle
    /// zone sits over the detail region when the sidebar is hidden and over the
    /// sidebar when it's shown (see the `Metrics` fields).
    static func leadingChrome(sidebarVisible: Bool, metrics: Metrics = .default) -> CGFloat {
        sidebarVisible ? metrics.openLeadingChrome : metrics.closedLeadingChrome
    }

    /// The omnibox field's width, driven by the reliably-measurable detail-region
    /// width and sidebar state. Delegates to the core `fieldWidth(windowWidth:
    /// fieldLeadingX:…)` — the detail width plays the role of the window width and
    /// the fixed leading chrome the role of the field's leading edge, because the
    /// core only ever uses their difference (the span right of the field's start).
    /// This keeps the stretch/shrink/overflow-expand behavior identical while
    /// sourcing it from a measurement the toolbar can't strand.
    static func fieldWidth(detailWidth: CGFloat, sidebarVisible: Bool,
                           switcherExtra: CGFloat, metrics: Metrics = .default) -> CGFloat {
        fieldWidth(windowWidth: detailWidth,
                   fieldLeadingX: leadingChrome(sidebarVisible: sidebarVisible, metrics: metrics),
                   switcherExtra: switcherExtra, metrics: metrics)
    }

    /// The field width if the switcher is kept on-screen: the field fills from its
    /// leading edge to just short of the switcher. Can fall below `minWidth`,
    /// which is the signal that the switcher no longer fits.
    static func widthKeepingSwitcher(windowWidth: CGFloat, fieldLeadingX: CGFloat,
                                     switcherExtra: CGFloat, metrics: Metrics = .default) -> CGFloat {
        windowWidth - metrics.trailingWithSwitcher - switcherExtra - fieldLeadingX
    }

    /// Whether the wiki switcher fits on-screen beside a field no narrower than
    /// `minWidth`. When false, NSToolbar drops the switcher into the `»` overflow
    /// and the field reclaims that trailing space (see `fieldWidth`).
    static func switcherFits(windowWidth: CGFloat, fieldLeadingX: CGFloat,
                             switcherExtra: CGFloat, metrics: Metrics = .default) -> Bool {
        widthKeepingSwitcher(windowWidth: windowWidth, fieldLeadingX: fieldLeadingX,
                             switcherExtra: switcherExtra, metrics: metrics) >= metrics.minWidth
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
        let kept = widthKeepingSwitcher(windowWidth: windowWidth, fieldLeadingX: fieldLeadingX,
                                        switcherExtra: switcherExtra, metrics: metrics)
        let raw = kept >= metrics.minWidth
            ? kept
            : windowWidth - metrics.trailingOverflow - fieldLeadingX
        return min(max(raw, metrics.minWidth), metrics.maxWidth)
    }
}
