import Testing
@testable import WikiFSCore

struct TabBarLayoutTests {
    // Metrics mirror TabBarMetrics in the app layer.
    private let minW: Double = 110
    private let maxW: Double = 200
    private let overflowW: Double = 28

    private func compute(_ count: Int, _ width: Double) -> TabBarLayout {
        TabBarLayout.compute(
            tabCount: count, availableWidth: width,
            minTabWidth: minW, maxTabWidth: maxW, overflowWidth: overflowW)
    }

    @Test func noTabsHasNothingVisible() {
        let l = compute(0, 800)
        #expect(l.visibleCount == 0)
        #expect(!l.showsOverflow)
    }

    @Test func zeroWidthHasNothingVisible() {
        let l = compute(5, 0)
        #expect(l.visibleCount == 0)
        #expect(!l.showsOverflow)
    }

    @Test func fewTabsSitAtMaxWidth() {
        // 2 tabs in a wide window: each capped at max, no overflow.
        let l = compute(2, 1000)
        #expect(l.tabWidth == maxW)
        #expect(l.visibleCount == 2)
        #expect(!l.showsOverflow)
    }

    @Test func tabsShrinkToShareWidth() {
        // 6 tabs in 900pt: 900/6 = 150, between min and max → 150 each.
        let l = compute(6, 900)
        #expect(l.tabWidth == 150)
        #expect(l.visibleCount == 6)
        #expect(!l.showsOverflow)
    }

    @Test func tabsClampAtMinWhenJustFitting() {
        // 8 tabs, exactly 8 * 110 = 880 available → all fit at min, no overflow.
        let l = compute(8, 880)
        #expect(l.tabWidth == minW)
        #expect(l.visibleCount == 8)
        #expect(!l.showsOverflow)
    }

    @Test func overflowWhenMinDoesNotFit() {
        // 10 tabs need 1100 at min; only 700 available → overflow.
        // Room for tabs after reserving the chevron: 700 - 28 = 672.
        // 672 / 110 = 6.10 → 6 visible, chevron shown.
        let l = compute(10, 700)
        #expect(l.tabWidth == minW)
        #expect(l.visibleCount == 6)
        #expect(l.showsOverflow)
    }

    @Test func alwaysAtLeastOneTabVisibleEvenIfNarrow() {
        // Absurdly narrow window with many tabs: still show one + chevron.
        let l = compute(20, 60)
        #expect(l.visibleCount == 1)
        #expect(l.showsOverflow)
    }
}
