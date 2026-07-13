import Testing
@testable import WikiFS
@testable import WikiFSEngine

/// Pure logic behind omnibox arrow-key navigation (issue #155). The actual
/// AppKit event interception lives in `OmniboxSearchField.Coordinator`
/// (`NSEvent` local monitor); these tests lock the selection-advancement math
/// it drives — the first-down selects the top row, up/down step and clamp at
/// the ends, and an empty list yields nothing.
@Suite struct OmniboxSelectionTests {

    // MARK: - First press (nothing selected yet)

    @Test func firstDownSelectsTheTopRow() {
        #expect(OmniboxSelection.advance(current: nil, count: 5, delta: 1) == 0)
    }

    @Test func firstUpSelectsTheLastRow() {
        #expect(OmniboxSelection.advance(current: nil, count: 5, delta: -1) == 4)
    }

    @Test func firstUpOnASingleItemSelectsIt() {
        #expect(OmniboxSelection.advance(current: nil, count: 1, delta: -1) == 0)
    }

    // MARK: - Stepping

    @Test func downStepsTowardTheEnd() {
        var index: Int? = OmniboxSelection.advance(current: nil, count: 4, delta: 1)
        index = OmniboxSelection.advance(current: index, count: 4, delta: 1)
        #expect(index == 1)
        index = OmniboxSelection.advance(current: index, count: 4, delta: 1)
        #expect(index == 2)
        index = OmniboxSelection.advance(current: index, count: 4, delta: 1)
        #expect(index == 3)
    }

    @Test func upStepsTowardTheStart() {
        var index: Int? = OmniboxSelection.advance(current: nil, count: 4, delta: -1) // 3
        index = OmniboxSelection.advance(current: index, count: 4, delta: -1) // 2
        index = OmniboxSelection.advance(current: index, count: 4, delta: -1) // 1
        index = OmniboxSelection.advance(current: index, count: 4, delta: -1) // 0
        #expect(index == 0)
    }

    // MARK: - Clamping (no wrap)

    @Test func downClampsAtTheLastRow() {
        // Already at the end: stays put, never wraps to the top.
        #expect(OmniboxSelection.advance(current: 3, count: 4, delta: 1) == 3)
        #expect(OmniboxSelection.advance(current: 3, count: 4, delta: 5) == 3)
    }

    @Test func upClampsAtTheFirstRow() {
        // Already at the start: stays put, never wraps to the bottom.
        #expect(OmniboxSelection.advance(current: 0, count: 4, delta: -1) == 0)
        #expect(OmniboxSelection.advance(current: 0, count: 4, delta: -5) == 0)
    }

    @Test func clampsPastTheEndInOneStep() {
        // A single large delta never overshoots the bounds.
        #expect(OmniboxSelection.advance(current: 1, count: 4, delta: 100) == 3)
        #expect(OmniboxSelection.advance(current: 2, count: 4, delta: -100) == 0)
    }

    // MARK: - Empty list

    @Test func emptyListYieldsNoSelection() {
        #expect(OmniboxSelection.advance(current: nil, count: 0, delta: 1) == nil)
        #expect(OmniboxSelection.advance(current: 0, count: 0, delta: 1) == nil)
    }

    @Test func singleItemListClampsImmediately() {
        #expect(OmniboxSelection.advance(current: nil, count: 1, delta: 1) == 0)
        #expect(OmniboxSelection.advance(current: 0, count: 1, delta: 1) == 0)
        #expect(OmniboxSelection.advance(current: 0, count: 1, delta: -1) == 0)
    }
}
