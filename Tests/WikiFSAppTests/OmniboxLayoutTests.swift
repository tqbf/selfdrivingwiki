#if os(macOS)
import CoreGraphics
import Testing
@testable import WikiFS
@testable import WikiFSEngine

/// Sizing behavior of the compact centered toolbar omnibox. Uses a fixed
/// `Metrics` so the thresholds are exact and independent of any future retuning.
/// These tests cover only the pill's *width* as the detail region grows, and
/// that the width leaves enough room for surrounding toolbar chrome.
@Suite struct OmniboxLayoutTests {
    // sideMarginOpen 220, sideMarginClosed 320, min 240, max 560,
    // trailingChromeWidth 220.
    let m = OmniboxLayout.Metrics.default

    // MARK: Grows with the region, keeping safe side margins

    @Test func fieldTakesTheRegionMinusAMarginOnEachSide() {
        // Sidebar shown: 900 - 2*220 = 460.
        #expect(OmniboxLayout.fieldWidth(detailWidth: 900, sidebarVisible: true) == 460)
        // Sidebar hidden: 900 - 2*320 = 260. The larger margin clears the
        // traffic lights + sidebar toggle.
        #expect(OmniboxLayout.fieldWidth(detailWidth: 900, sidebarVisible: false) == 260)
    }

    @Test func widerRegionGrowsTheFieldOneForOneBelowTheCap() {
        for sidebar in [true, false] {
            let narrow = OmniboxLayout.fieldWidth(detailWidth: 900, sidebarVisible: sidebar)
            let wider = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: sidebar)
            #expect(wider - narrow == 100)
        }
    }

    @Test func hiddenSidebarReservesMoreMarginSoTheFieldIsNarrower() {
        // Same region, but hiding the sidebar puts more chrome into the centered
        // field's side margin, so the field must be narrower by twice the margin
        // difference.
        let open = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: true)
        let closed = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: false)
        #expect(open - closed == 2 * (m.sideMarginClosed - m.sideMarginOpen))
    }

    @Test func sideMarginDependsOnSidebarVisibility() {
        #expect(OmniboxLayout.sideMargin(sidebarVisible: true) == m.sideMarginOpen)
        #expect(OmniboxLayout.sideMargin(sidebarVisible: false) == m.sideMarginClosed)
    }

    @Test func trailingChromeIsAlwaysReservedBelowTheCap() {
        let width = OmniboxLayout.fieldWidth(detailWidth: 1000, sidebarVisible: true)
        #expect((1000 - width) / 2 >= m.trailingChromeWidth)
    }

    @Test func sideMarginIsPreservedBelowTheCap() {
        // Widths chosen to sit in each state's growing regime.
        for detailWidth: CGFloat in [700, 900, 1000] {
            let open = OmniboxLayout.fieldWidth(detailWidth: detailWidth, sidebarVisible: true)
            #expect((detailWidth - open) / 2 == m.sideMarginOpen)
        }
        for detailWidth: CGFloat in [900, 1100, 1200] {
            let closed = OmniboxLayout.fieldWidth(detailWidth: detailWidth, sidebarVisible: false)
            #expect((detailWidth - closed) / 2 == m.sideMarginClosed)
        }
    }

    // MARK: Clamps

    @Test func neverShrinksBelowTheFloor() {
        // Very narrow region: region - margins would go below the floor, so the
        // floor holds instead (never a negative width).
        #expect(OmniboxLayout.fieldWidth(detailWidth: 500, sidebarVisible: true) == m.minWidth)
        #expect(OmniboxLayout.fieldWidth(detailWidth: 700, sidebarVisible: false) == m.minWidth)
    }

    @Test func neverGrowsPastTheCap() {
        #expect(OmniboxLayout.fieldWidth(detailWidth: 2000, sidebarVisible: true) == m.maxWidth)
        #expect(OmniboxLayout.fieldWidth(detailWidth: 2000, sidebarVisible: false) == m.maxWidth)
    }

    @Test func marginsGrowPastTheCap() {
        // Once the field is capped, extra window width becomes margin.
        let wide = OmniboxLayout.fieldWidth(detailWidth: 1600, sidebarVisible: true)
        let wider = OmniboxLayout.fieldWidth(detailWidth: 2000, sidebarVisible: true)
        #expect(wide == m.maxWidth)
        #expect(wider == m.maxWidth)
        #expect((1600 - wide) / 2 == 520)
        #expect((2000 - wider) / 2 == 720)
    }

    // MARK: Unmeasured region

    @Test func returnsFloorBeforeGeometryIsKnown() {
        // GeometryReader reports 0 until first layout; never a negative width.
        #expect(OmniboxLayout.fieldWidth(detailWidth: 0, sidebarVisible: true) == m.minWidth)
        #expect(OmniboxLayout.fieldWidth(detailWidth: 0, sidebarVisible: false) == m.minWidth)
    }
}
#endif
