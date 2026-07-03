import CoreGraphics
import Testing
@testable import WikiFS

/// Sizing/overflow behavior of the toolbar omnibox. Uses a fixed `Metrics` so the
/// thresholds are exact and independent of the real switcher/transcript widths.
@Suite struct OmniboxLayoutTests {
    // trailingWithSwitcher 180, trailingOverflow 60, min 120, max 1200.
    let m = OmniboxLayout.Metrics.default

    // MARK: Switcher visible

    @Test func fillsToTheSwitcherOnAWideWindow() {
        // 1200 - 180 (switcher+transcript) - 0 (baseline name) - 200 (leading) = 820.
        let w = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 0)
        #expect(w == 820)
        #expect(OmniboxLayout.switcherFits(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 0))
    }

    @Test func aLongerWikiNameShrinksTheField() {
        let base = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 0)
        let long = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 150)
        #expect(long == base - 150)
        #expect(long == 670)
    }

    @Test func aShorterWikiNameLetsTheFieldGrow() {
        let base = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 0)
        let short = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: -40)
        #expect(short == base + 40)
    }

    @Test func openSidebarPushesTheLeadingEdgeAndShrinksTheField() {
        // A larger leading edge (sidebar open) yields a narrower field, 1-for-1.
        let closed = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 0)
        let open = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 380, switcherExtra: 0)
        #expect(open == closed - 180)
    }

    // MARK: Overflow threshold + expansion

    @Test func switcherStaysUntilTheFieldReachesItsFloor() {
        // 500 - 180 - 200 = 120 == floor: switcher still fits, exactly.
        #expect(OmniboxLayout.switcherFits(windowWidth: 500, fieldLeadingX: 200, switcherExtra: 0))
        #expect(OmniboxLayout.fieldWidth(windowWidth: 500, fieldLeadingX: 200, switcherExtra: 0) == 120)
    }

    @Test func switcherOverflowsJustBelowTheFloor() {
        // 490 - 180 - 200 = 110 < floor: switcher drops into » overflow.
        #expect(!OmniboxLayout.switcherFits(windowWidth: 490, fieldLeadingX: 200, switcherExtra: 0))
    }

    @Test func fieldExpandsToFillFreedSpaceOnceSwitcherOverflows() {
        // At 490 the switcher overflows; the field must expand past its floor to
        // fill the freed trailing space (490 - 60 overflow - 200 leading = 230),
        // not stay stranded at the 120 floor.
        let w = OmniboxLayout.fieldWidth(windowWidth: 490, fieldLeadingX: 200, switcherExtra: 0)
        #expect(w == 230)
        #expect(w > m.minWidth)
    }

    @Test func crossingTheThresholdJumpsWiderNotNarrower() {
        // Just above the threshold the switcher shows (field at floor); just below,
        // it overflows and the field jumps *wider* to reclaim the space.
        let showing = OmniboxLayout.fieldWidth(windowWidth: 500, fieldLeadingX: 200, switcherExtra: 0)
        let overflowed = OmniboxLayout.fieldWidth(windowWidth: 490, fieldLeadingX: 200, switcherExtra: 0)
        #expect(showing == 120)
        #expect(overflowed > showing)
    }

    @Test func aLongWikiNameTriggersOverflowSooner() {
        // Same window; a long name reserves more, so the switcher overflows at a
        // width where a baseline name would still fit.
        #expect(OmniboxLayout.switcherFits(windowWidth: 620, fieldLeadingX: 200, switcherExtra: 0))
        #expect(!OmniboxLayout.switcherFits(windowWidth: 620, fieldLeadingX: 200, switcherExtra: 150))
    }

    // MARK: Clamps

    @Test func neverShrinksBelowTheFloor() {
        // Tiny window, everything overflows: still clamped to the floor.
        let w = OmniboxLayout.fieldWidth(windowWidth: 300, fieldLeadingX: 200, switcherExtra: 0)
        #expect(w == m.minWidth)
    }

    @Test func neverGrowsPastTheCap() {
        let w = OmniboxLayout.fieldWidth(windowWidth: 2000, fieldLeadingX: 200, switcherExtra: 0)
        #expect(w == m.maxWidth)
    }

    @Test func returnsFloorBeforeGeometryIsKnown() {
        // windowWidth 0 → not yet measured → floor, never a negative width.
        #expect(OmniboxLayout.fieldWidth(windowWidth: 0, fieldLeadingX: 0, switcherExtra: 0) == m.minWidth)
    }

    // MARK: Detail-width driver (sidebar-aware)
    //
    // The view can't reliably measure the field's own leading edge — the toolbar
    // yanks it out of the window on overflow, stranding the reading. Instead it
    // measures the detail region's width (never in overflow) and the sidebar state,
    // and `fieldWidth(detailWidth:sidebarVisible:…)` derives the field width from
    // them. These lock that derivation and the leading-chrome branch.

    @Test func leadingChromeDiffersBySidebarState() {
        // Sidebar shown: only the nav buttons sit left of the field (traffic lights
        // + toggle are over the sidebar). Sidebar hidden: the detail region spans
        // the whole window, so it also includes that traffic-light + toggle zone.
        #expect(OmniboxLayout.leadingChrome(sidebarVisible: true) == m.openLeadingChrome)
        #expect(OmniboxLayout.leadingChrome(sidebarVisible: false) == m.closedLeadingChrome)
        #expect(m.openLeadingChrome < m.closedLeadingChrome)
    }

    @Test func detailWidthDriverDelegatesToTheCore() {
        // The detail-width overload is exactly the core math with detailWidth as the
        // window width and the fixed leading chrome as the field's leading edge.
        let closed = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: false, switcherExtra: 0)
        #expect(closed == OmniboxLayout.fieldWidth(windowWidth: 1000, fieldLeadingX: m.closedLeadingChrome, switcherExtra: 0))
        let open = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: true, switcherExtra: 0)
        #expect(open == OmniboxLayout.fieldWidth(windowWidth: 1000, fieldLeadingX: m.openLeadingChrome, switcherExtra: 0))
    }

    @Test func openSidebarLeavesMoreRoomForTheFieldAtAGivenDetailWidth() {
        // For the SAME detail width, the sidebar-shown case reserves less leading
        // chrome, so the field is wider by exactly that difference. (In practice the
        // detail width also shrinks when the sidebar opens; this isolates the chrome.)
        let closed = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: false, switcherExtra: 0)
        let open = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: true, switcherExtra: 0)
        #expect(open - closed == m.closedLeadingChrome - m.openLeadingChrome)
    }

    @Test func overflowExpansionStillWorksThroughTheDetailWidthDriver() {
        // A detail region too narrow to keep the switcher: the field must expand past
        // its floor to reclaim the freed trailing space (same behavior as the core,
        // reached via the detail-width overload).
        let w = OmniboxLayout.fieldWidth(detailWidth: 360, sidebarVisible: true, switcherExtra: 0)
        // 360 - 64 chrome - 180 keepsSwitcher = 116 < 120 floor → overflow path:
        // 360 - 64 - 60 overflow = 236.
        #expect(w == 236)
        #expect(w > m.minWidth)
    }

    @Test func returnsFloorBeforeTheDetailWidthIsMeasured() {
        // GeometryReader reports 0 until first layout; never a negative width.
        #expect(OmniboxLayout.fieldWidth(detailWidth: 0, sidebarVisible: true, switcherExtra: 0) == m.minWidth)
        #expect(OmniboxLayout.fieldWidth(detailWidth: 0, sidebarVisible: false, switcherExtra: 0) == m.minWidth)
    }
}
