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

    // MARK: - liveSlot (live drag-to-reorder, #1388)

    private func live(_ current: Int, _ centerX: Double, count: Int = 4) -> Int {
        TabBarLayout.liveSlot(currentIndex: current, centerX: centerX, tabWidth: maxW, tabCount: count)
    }

    @Test func centerInOwnSlotStays() {
        // Tab 1's home center is 300; nowhere near a neighbor's center.
        #expect(live(1, 300) == 1)
        #expect(live(0, 100) == 0)
        #expect(live(3, 700) == 3)
    }

    @Test func swapTriggersPastNeighborCenterPlusDeadband() {
        // Right neighbor's center: 500. Deadband 8 → swap right at > 508.
        #expect(live(1, 505) == 1)
        #expect(live(1, 509) == 2)
        // Left neighbor's center: 100 → swap left at < 92.
        #expect(live(1, 95) == 1)
        #expect(live(1, 91) == 0)
    }

    @Test func deadbandPreventsBoundaryChatter() {
        // Exactly AT the neighbor's center: no swap in either direction.
        #expect(live(1, 500) == 1)
        #expect(live(1, 100) == 1)
    }

    @Test func fastFlingCrossesMultipleSlotsInOneEvent() {
        // Center at 1000 (past tabs 2, 3, 4's centers at 500/700/900) in a
        // 5-tab strip: lands at index 4.
        #expect(live(1, 1000, count: 5) == 4)
        // Mirror: fling left past tabs 0 and -... clamps at 0.
        #expect(live(3, 50, count: 5) == 0)
    }

    @Test func liveSlotClampsToStripEnds() {
        #expect(live(0, -500) == 0)
        #expect(live(3, 10000) == 3)
    }

    @Test func liveSlotDegenerateInputs() {
        #expect(TabBarLayout.liveSlot(currentIndex: 2, centerX: 500, tabWidth: 0, tabCount: 4) == 2)
        #expect(TabBarLayout.liveSlot(currentIndex: 2, centerX: 500, tabWidth: maxW, tabCount: 0) == 2)
        // Out-of-range current index is clamped before swapping. The clamped
        // tab at slot 3 then moves left to follow the pointer at x = 100.
        #expect(TabBarLayout.liveSlot(currentIndex: 9, centerX: 100, tabWidth: maxW, tabCount: 4) == 1)
    }

    @Test func targetIndexAccountsForRemoval() {
        // Insertion slot → final post-removal index; home slot is a no-op.
        #expect(TabBarLayout.targetIndex(fromIndex: 2, slot: 2) == 2)
        #expect(TabBarLayout.targetIndex(fromIndex: 0, slot: 3) == 2)
        #expect(TabBarLayout.targetIndex(fromIndex: 3, slot: 0) == 0)
    }
}
