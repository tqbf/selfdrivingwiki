#if os(macOS)
import CoreGraphics
import Testing
@testable import WikiFS
@testable import WikiFSEngine

/// Sizing/overflow behavior of the toolbar omnibox. Uses a fixed `Metrics` so the
/// thresholds are exact and independent of the real switcher/transcript widths.
@Suite struct OmniboxLayoutTests {
    // trailingWithSwitcher 0 (no trailing toolbar items — the wiki switcher
    // moved into the sidebar header and the Change Log toggle was removed, so
    // the omnibox owns the full toolbar width), trailingOverflow 60, min 120,
    // max 1200.
    let m = OmniboxLayout.Metrics.default

    // MARK: Field fills to the window edge

    @Test func fillsToTheWindowEdgeOnAWideWindow() {
        // 1200 - 0 (no trailing items) - 0 (baseline) - 200 (leading) = 1000.
        let w = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 0)
        #expect(w == 1000)
        #expect(OmniboxLayout.switcherFits(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 0))
    }

    @Test func aLongerWikiNameShrinksTheField() {
        let base = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 0)
        let long = OmniboxLayout.fieldWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 150)
        #expect(long == base - 150)
        #expect(long == 850)
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
    //
    // With `trailingWithSwitcher = 0` there are no trailing toolbar items, so
    // the overflow path is degenerate — it only activates when the window is
    // so narrow that even with zero trailing reservation the field can't reach
    // `minWidth`. In that regime the overflow path yields *less* than `minWidth`
    // (because `trailingOverflow > trailingWithSwitcher`), so the field clamps
    // to `minWidth` either way. The tests below lock that degenerate behavior.

    @Test func switcherStaysUntilTheFieldReachesItsFloor() {
        // 320 - 0 - 200 = 120 == floor: no overflow needed, exactly.
        #expect(OmniboxLayout.switcherFits(windowWidth: 320, fieldLeadingX: 200, switcherExtra: 0))
        #expect(OmniboxLayout.fieldWidth(windowWidth: 320, fieldLeadingX: 200, switcherExtra: 0) == 120)
    }

    @Test func switcherOverflowsJustBelowTheFloor() {
        // 319 - 0 - 200 = 119 < floor: would overflow if there were trailing items.
        #expect(!OmniboxLayout.switcherFits(windowWidth: 319, fieldLeadingX: 200, switcherExtra: 0))
    }

    @Test func fieldClampsToFloorInOverflowRegime() {
        // With no trailing items, the overflow path yields less than minWidth
        // (319 - 60 overflow - 200 = 59 < 120), so the field clamps to floor
        // rather than expanding.
        let w = OmniboxLayout.fieldWidth(windowWidth: 319, fieldLeadingX: 200, switcherExtra: 0)
        #expect(w == m.minWidth)
    }

    @Test func aLongWikiNameTriggersOverflowSooner() {
        // Same window; a long name reserves more, so the field drops below floor
        // at a width where a baseline name would still fit.
        #expect(OmniboxLayout.switcherFits(windowWidth: 350, fieldLeadingX: 200, switcherExtra: 0))
        #expect(!OmniboxLayout.switcherFits(windowWidth: 350, fieldLeadingX: 200, switcherExtra: 150))
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

    // MARK: Overflow spacer (issue #114)
    //
    // Once `fieldWidth` hits `maxWidth` it stops absorbing extra window width, so
    // `fieldLeadingX + fieldWidth + trailingWithSwitcher` no longer sums to
    // `windowWidth` — the invariant that would otherwise keep the trailing items
    // flush against the true edge. `overflowSpacerWidth` reports exactly the
    // shortfall so the toolbar item can absorb it itself. With no trailing items
    // (`trailingWithSwitcher = 0`) the spacer still fills dead space past the cap,
    // keeping the omnibox group's total width tracking the detail region 1:1.

    @Test func overflowSpacerIsZeroBelowTheCap() {
        // 1200 window: field (1000) is well under maxWidth, nothing to absorb.
        let s = OmniboxLayout.overflowSpacerWidth(windowWidth: 1200, fieldLeadingX: 200, switcherExtra: 0)
        #expect(s == 0)
    }

    @Test func overflowSpacerIsZeroExactlyAtTheCap() {
        // kept == maxWidth exactly: 200 + 1200 + 0 = 1400.
        let s = OmniboxLayout.overflowSpacerWidth(windowWidth: 1400, fieldLeadingX: 200, switcherExtra: 0)
        #expect(s == 0)
    }

    @Test func overflowSpacerAbsorbsExactlyWhatTheCapClampedAway() {
        // 2000 window: field clamps to maxWidth (1200); the spacer must make up
        // the rest so fieldLeadingX + fieldWidth + spacer + trailing == windowWidth.
        let w = OmniboxLayout.fieldWidth(windowWidth: 2000, fieldLeadingX: 200, switcherExtra: 0)
        let s = OmniboxLayout.overflowSpacerWidth(windowWidth: 2000, fieldLeadingX: 200, switcherExtra: 0)
        #expect(200 + w + s + m.trailingWithSwitcher == 2000)
        #expect(s == 600)
    }

    @Test func overflowSpacerGrowsOneForOneWithWindowWidthPastTheCap() {
        let base = OmniboxLayout.overflowSpacerWidth(windowWidth: 2000, fieldLeadingX: 200, switcherExtra: 0)
        let wider = OmniboxLayout.overflowSpacerWidth(windowWidth: 2100, fieldLeadingX: 200, switcherExtra: 0)
        #expect(wider == base + 100)
    }

    @Test func overflowSpacerMatchesTheIssueThreshold() {
        // Sidebar open: issue #114's gap starts once detailWidth exceeds
        // maxWidth + trailingWithSwitcher + openLeadingChrome (derived from default
        // metrics rather than hardcoded, so this doesn't fight future retuning).
        // Below/at it the spacer is zero; just past it the gap starts opening.
        let threshold = m.maxWidth + m.trailingWithSwitcher + m.openLeadingChrome
        let atThreshold = OmniboxLayout.overflowSpacerWidth(detailWidth: threshold, sidebarVisible: true, switcherExtra: 0)
        let pastThreshold = OmniboxLayout.overflowSpacerWidth(detailWidth: threshold + 1, sidebarVisible: true, switcherExtra: 0)
        #expect(atThreshold == 0)
        #expect(pastThreshold == 1)
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

    // MARK: Home button leading chrome
    //
    // A wiki with a configured home page (issue #280) adds a fourth nav button,
    // shifting the field's real leading edge right by `homeButtonExtra`. Omitting
    // this previously under-reserved the field's own width by that fixed amount —
    // independent of window width.

    @Test func homeButtonAddsExtraLeadingChromeInBothSidebarStates() {
        #expect(OmniboxLayout.leadingChrome(sidebarVisible: true, homeButtonShown: true)
                == m.openLeadingChrome + m.homeButtonExtra)
        #expect(OmniboxLayout.leadingChrome(sidebarVisible: false, homeButtonShown: true)
                == m.closedLeadingChrome + m.homeButtonExtra)
    }

    @Test func homeButtonShrinksTheFieldByExactlyItsOwnWidth() {
        // Isolates the home-button effect: same detailWidth/sidebar state, only
        // `homeButtonShown` differs, so the field must shrink by exactly
        // `homeButtonExtra` — the button's own width plus its one nav-cluster gap.
        let withoutHome = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: true, switcherExtra: 0)
        let withHome = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: true,
                                                homeButtonShown: true, switcherExtra: 0)
        #expect(withoutHome - withHome == m.homeButtonExtra)
    }

    @Test func homeButtonEncroachmentIsIndependentOfWindowWidth() {
        // The reported bug: unlike an overflow threshold (which clears once the
        // window is wide enough), a missing home-button reservation is a FIXED
        // offset — it never resolves no matter how wide the window gets. Confirm
        // the fixed invariant holds at both a narrow-ish and a very wide
        // detailWidth, with the home button shown.
        for detailWidth: CGFloat in [700, 2200] {
            let field = OmniboxLayout.fieldWidth(detailWidth: detailWidth, sidebarVisible: true,
                                                 homeButtonShown: true, switcherExtra: 73.5)
            let spacer = OmniboxLayout.overflowSpacerWidth(detailWidth: detailWidth, sidebarVisible: true,
                                                           homeButtonShown: true, switcherExtra: 73.5)
            let leading = OmniboxLayout.leadingChrome(sidebarVisible: true, homeButtonShown: true)
            #expect(leading + field + spacer + m.trailingWithSwitcher + 73.5 == detailWidth)
        }
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
        // chrome, so the field is wider by exactly that difference.
        let closed = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: false, switcherExtra: 0)
        let open = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: true, switcherExtra: 0)
        #expect(open - closed == m.closedLeadingChrome - m.openLeadingChrome)
    }

    @Test func overflowClampsToFloorThroughTheDetailWidthDriver() {
        // A detail region too narrow to fit even minWidth (with zero trailing
        // reservation): the field clamps to the floor rather than going negative.
        let w = OmniboxLayout.fieldWidth(detailWidth: 180, sidebarVisible: true, switcherExtra: 0)
        // 180 - 70 chrome - 0 trailing = 110 < 120 floor → overflow path:
        // 180 - 70 - 60 overflow = 50 < 120 → clamped to 120.
        #expect(w == m.minWidth)
    }

    @Test func returnsFloorBeforeTheDetailWidthIsMeasured() {
        // GeometryReader reports 0 until first layout; never a negative width.
        #expect(OmniboxLayout.fieldWidth(detailWidth: 0, sidebarVisible: true, switcherExtra: 0) == m.minWidth)
        #expect(OmniboxLayout.fieldWidth(detailWidth: 0, sidebarVisible: false, switcherExtra: 0) == m.minWidth)
    }
}
#endif
