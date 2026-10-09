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
        // Zero translation: slot fromIndex, which targetIndex maps to a no-op.
        #expect(slot(0, 0) == 0)
        #expect(slot(2, 0) == 2)
        #expect(TabBarLayout.targetIndex(fromIndex: 2, slot: 2) == 2)
    }

    @Test func belowThresholdDragsStayInPlace() {
        // Just under the swap threshold (0.25 * 200 = 50pt) either way: still
        // the home slot.
        #expect(slot(1, 49) == 1)
        #expect(slot(1, -49) == 1)
        #expect(TabBarLayout.targetIndex(fromIndex: 1, slot: 1) == 1)
    }

    @Test func thresholdDragMovesOneSlot() {
        // A quarter-width drag swaps one slot (dragSwapThresholdFraction).
        #expect(slot(1, 50) == 3)   // one slot right (lands after tab 2)
        #expect(TabBarLayout.targetIndex(fromIndex: 1, slot: 3) == 2)
        #expect(slot(1, -50) == 0)  // one slot left (lands before tab 0)
        #expect(TabBarLayout.targetIndex(fromIndex: 1, slot: 0) == 0)
    }

    @Test func multiTabDrag() {
        // Each further slot takes a full width: the second swap lands at
        // (2 - 1 + 0.25) * 200 = 250pt.
        #expect(slot(0, 249) == 2)  // one slot right
        #expect(TabBarLayout.targetIndex(fromIndex: 0, slot: 2) == 1)
        #expect(slot(0, 250) == 3)  // two slots right → final index 2
        #expect(TabBarLayout.targetIndex(fromIndex: 0, slot: 3) == 2)
        // Drag tab 3 left by 1.25 tab widths → slot 1 → final index 1.
        #expect(slot(3, -250) == 1)
        #expect(TabBarLayout.targetIndex(fromIndex: 3, slot: 1) == 1)
    }

    @Test func dragClampsToStripEnds() {
        // Past either end: clamp to the strip → no-op past the home end.
        #expect(slot(0, -1000) == 0)
        #expect(slot(3, 1000) == 3)
        #expect(TabBarLayout.targetIndex(fromIndex: 0, slot: 0) == 0)
        #expect(TabBarLayout.targetIndex(fromIndex: 3, slot: 3) == 3)
        // Dragging a middle tab past the right end lands it last.
        #expect(slot(1, 1000) == 4)
        #expect(TabBarLayout.targetIndex(fromIndex: 1, slot: 4) == 3)
    }

    @Test func insertionIndexDegenerateInputs() {
        #expect(TabBarLayout.insertionIndex(fromIndex: 0, dragOffset: 50, tabWidth: 0, tabCount: 4) == 0)
        #expect(TabBarLayout.insertionIndex(fromIndex: 0, dragOffset: 50, tabWidth: maxW, tabCount: 0) == 0)
    }
}
