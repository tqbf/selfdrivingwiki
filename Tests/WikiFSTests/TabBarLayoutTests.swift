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

    // MARK: - insertionIndex (drag-to-reorder, #1388)

    private func slot(_ from: Int, _ offset: Double, count: Int = 4) -> Int {
        TabBarLayout.insertionIndex(fromIndex: from, dragOffset: offset, tabWidth: maxW, tabCount: count)
    }

    @Test func noDragLandsInOwnSlot() {
        // Zero translation: slot fromIndex + 1, which targetIndex maps to a no-op.
        #expect(slot(0, 0) == 1)
        #expect(slot(2, 0) == 3)
        #expect(TabBarLayout.targetIndex(fromIndex: 2, slot: 3) == 2)
    }

    @Test func shortDragsStayInPlace() {
        // Tab 1's center starts at 300; a swap happens only when the center
        // crosses a NEIGHBOR's center (100 left / 500 right), Safari-style.
        #expect(slot(1, 99) == 2)
        #expect(slot(1, -99) == 1)
        // Exactly half a width: center on the slot boundary, still home.
        #expect(slot(1, 100) == 2)
        // Slots 1 and 2 both bracket the dragged tab's home position → no-op.
        #expect(TabBarLayout.targetIndex(fromIndex: 1, slot: 2) == 1)
        #expect(TabBarLayout.targetIndex(fromIndex: 1, slot: 1) == 1)
    }

    @Test func crossingNeighborCenterMovesOneSlot() {
        // Center past tab 2's center (500) → slot 3 → final index 2.
        #expect(slot(1, 201) == 3)
        #expect(TabBarLayout.targetIndex(fromIndex: 1, slot: 3) == 2)
        // Center past tab 0's center (100) → slot 0 → final index 0.
        #expect(slot(1, -201) == 0)
        #expect(TabBarLayout.targetIndex(fromIndex: 1, slot: 0) == 0)
    }

    @Test func multiTabDrag() {
        // Drag tab 0 right by 2.5 tab widths → slot 3 → final index 2.
        #expect(slot(0, 500) == 3)
        #expect(TabBarLayout.targetIndex(fromIndex: 0, slot: 3) == 2)
        // Drag tab 3 left by 2.5 tab widths → slot 1 → final index 1.
        #expect(slot(3, -500) == 1)
        #expect(TabBarLayout.targetIndex(fromIndex: 3, slot: 1) == 1)
    }

    @Test func dragClampsToStripEnds() {
        #expect(slot(0, -1000) == 0)
        #expect(slot(3, 1000) == 4)
        #expect(TabBarLayout.targetIndex(fromIndex: 0, slot: 0) == 0)
        #expect(TabBarLayout.targetIndex(fromIndex: 3, slot: 4) == 3)
    }

    @Test func insertionIndexDegenerateInputs() {
        #expect(TabBarLayout.insertionIndex(fromIndex: 0, dragOffset: 50, tabWidth: 0, tabCount: 4) == 0)
        #expect(TabBarLayout.insertionIndex(fromIndex: 0, dragOffset: 50, tabWidth: maxW, tabCount: 0) == 0)
    }
}
