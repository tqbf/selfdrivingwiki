#if os(macOS)
import CoreGraphics
import Testing
@testable import WikiFS
@testable import WikiFSEngine

/// Sizing behavior of the centered toolbar omnibox. Uses a fixed `Metrics` so the
/// thresholds are exact and independent of any future retuning. Centering itself
/// is NSToolbar's job (the field is a `.principal` item); these tests cover only
/// the pill's *width* as the detail region grows, and that the width leaves a
/// large enough margin to clear the leading chrome in each sidebar state.
@Suite struct OmniboxLayoutTests {
    // sideMarginOpen 150, sideMarginClosed 290, min 240, max 820.
    let m = OmniboxLayout.Metrics.default

    // MARK: Grows with the region, keeping side margins

    @Test func fieldTakesTheRegionMinusAMarginOnEachSide() {
        // Sidebar shown: 900 - 2*150 = 600.
        #expect(OmniboxLayout.fieldWidth(detailWidth: 900, sidebarVisible: true) == 600)
        // Sidebar hidden: 900 - 2*290 = 320 (a larger margin clears the traffic
        // lights + toggle that now sit in the field's left margin).
        #expect(OmniboxLayout.fieldWidth(detailWidth: 900, sidebarVisible: false) == 320)
    }

    @Test func widerRegionGrowsTheFieldOneForOneBelowTheCap() {
        for sidebar in [true, false] {
            let narrow = OmniboxLayout.fieldWidth(detailWidth: 900, sidebarVisible: sidebar)
            let wider = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: sidebar)
            #expect(wider - narrow == 100)
        }
    }

    @Test func hiddenSidebarReservesMoreMarginSoTheFieldIsNarrower() {
        // Same region, but hiding the sidebar puts more chrome in the left margin,
        // so the field must be narrower by exactly twice the margin difference.
        let open = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: true)
        let closed = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: false)
        #expect(open - closed == 2 * (m.sideMarginClosed - m.sideMarginOpen))
    }

    @Test func sideMarginIsPreservedBelowTheCap() {
        // (region - field) / 2 == the state's side margin, so the centered pill
        // can never touch the region edges (the old overflow trigger). Widths
        // chosen to sit in each state's growing regime.
        for detailWidth: CGFloat in [700, 900, 1100] {
            let open = OmniboxLayout.fieldWidth(detailWidth: detailWidth, sidebarVisible: true)
            #expect((detailWidth - open) / 2 == m.sideMarginOpen)
        }
        for detailWidth: CGFloat in [900, 1100, 1300] {
            let closed = OmniboxLayout.fieldWidth(detailWidth: detailWidth, sidebarVisible: false)
            #expect((detailWidth - closed) / 2 == m.sideMarginClosed)
        }
    }

    // MARK: Clamps

    @Test func neverShrinksBelowTheFloor() {
        // Very narrow region: region - margins would go below the floor, so the
        // floor holds and the margins give instead (never a negative width).
        #expect(OmniboxLayout.fieldWidth(detailWidth: 500, sidebarVisible: true) == m.minWidth)
        #expect(OmniboxLayout.fieldWidth(detailWidth: 700, sidebarVisible: false) == m.minWidth)
    }

    @Test func neverGrowsPastTheCap() {
        #expect(OmniboxLayout.fieldWidth(detailWidth: 2000, sidebarVisible: true) == m.maxWidth)
        #expect(OmniboxLayout.fieldWidth(detailWidth: 2000, sidebarVisible: false) == m.maxWidth)
    }

    @Test func marginsGrowPastTheCap() {
        // Once the field is capped, extra window width becomes margin — the pill
        // stays a fixed readable width and floats centered with more air around it.
        let wide = OmniboxLayout.fieldWidth(detailWidth: 1600, sidebarVisible: true)
        let wider = OmniboxLayout.fieldWidth(detailWidth: 2000, sidebarVisible: true)
        #expect(wide == m.maxWidth)
        #expect(wider == m.maxWidth)
        #expect((1600 - wide) / 2 == 390)
        #expect((2000 - wider) / 2 == 590)
    }

    // MARK: Unmeasured region

    @Test func returnsFloorBeforeGeometryIsKnown() {
        // GeometryReader reports 0 until first layout; never a negative width.
        #expect(OmniboxLayout.fieldWidth(detailWidth: 0, sidebarVisible: true) == m.minWidth)
        #expect(OmniboxLayout.fieldWidth(detailWidth: 0, sidebarVisible: false) == m.minWidth)
    }
}
#endif
