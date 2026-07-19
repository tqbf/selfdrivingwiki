import Foundation
import AppKit
import Testing
@testable import WikiFS

/// Pure-function unit tests for `ChatAutocompletePanel.origin(...)` — the
/// caret-relative placement math (a `nonisolated static` helper on the
/// `@MainActor` panel class). No live NSPanel, no NSWindow, no AppKit layout
/// — these tests assert the screen-coordinate origin computation purely from
/// `NSRect` arithmetic.
///
/// Companion to `ChatAutocompleteSelectionTests`: that suite covers selection
/// advancement; this one covers the new (caret-based, not view-bounds)
/// dropdown positioning introduced when the panel was generalized from
/// `present(above:)` to `present(caretRect:in:placement:)`.
///
/// Screen coordinates on macOS are bottom-left origin. The panel's "origin" is
/// its BOTTOM-LEFT corner, so:
///   - above → origin.y = caretRect.maxY + gap (panel bottom sits `gap` above
///     the caret's top edge, extends upward).
///   - below → origin.y = caretRect.minY - panel.height - gap (panel top sits
///     `gap` below the caret's bottom edge, extends downward).
struct ChatAutocompletePanelPlacementTests {

    /// Window used in the room-measurement tests. (`window.frame` is a value
    /// type — pure to construct; never lives in a live AppKit window.)
    private let window = NSRect(x: 0, y: 0, width: 800, height: 600)
    private let panelSize = NSSize(width: 460, height: 100)

    // MARK: - `.above` placement

    @Test func abovePlacesPanelJustAboveCaretWhenRoom() {
        // Caret at y=100–120 (one line near the bottom of the window).
        // Panel (100pt tall) should sit just above with 4pt gap:
        // origin.y = 120 + 4 = 124, origin.x = caret.minX = 100.
        let caret = NSRect(x: 100, y: 100, width: 0, height: 20)
        let origin = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .above)
        #expect(origin == NSPoint(x: 100, y: 124))
    }

    @Test func aboveFallsBackToBelowWhenNoRoomAbove() {
        // Caret at y=580–600 — within 8pt of the parent window's top (592).
        // No room above (panel would need 100pt + 4 gap, only has 0); falls
        // back to below: origin.y = 580 - 100 - 4 = 476.
        let caret = NSRect(x: 100, y: 580, width: 0, height: 20)
        let origin = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .above)
        #expect(origin == NSPoint(x: 100, y: 476))
    }

    // MARK: - `.below` placement

    @Test func belowPlacesPanelJustBelowCaretWhenRoom() {
        // Caret at y=200–220. Panel (100pt tall) should sit just below with
        // 4pt gap: origin.y = 200 - 100 - 4 = 96 (panel top at 196, leaving
        // 4pt gap below the caret's bottom). origin.x = caret.minX.
        let caret = NSRect(x: 100, y: 200, width: 0, height: 20)
        let origin = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .below)
        #expect(origin == NSPoint(x: 100, y: 96))
    }

    @Test func belowFallsBackToAboveWhenNoRoomBelow() {
        // Caret at y=50–70. Room below = 50 - 4 - 100 - 8 = -62 (negative →
        // doesn't fit). Falls back to above: origin.y = 70 + 4 = 74.
        let caret = NSRect(x: 100, y: 50, width: 0, height: 20)
        let origin = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .below)
        #expect(origin == NSPoint(x: 100, y: 74))
    }

    // MARK: - `.auto` placement (picks the roomier side)

    @Test func autoPicksAboveWhenMoreRoomAbove() {
        // Caret near bottom of window (y=100–120). More room above than below.
        let caret = NSRect(x: 100, y: 100, width: 0, height: 20)
        let origin = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .auto)
        #expect(origin == NSPoint(x: 100, y: 124))
    }

    @Test func autoPicksBelowWhenMoreRoomBelow() {
        // Caret near top of window (y=500–520). More room below than above.
        let caret = NSRect(x: 100, y: 500, width: 0, height: 20)
        let origin = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .auto)
        // Below: origin.y = 500 - 100 - 4 = 396.
        #expect(origin == NSPoint(x: 100, y: 396))
    }

    @Test func autoDefaultsToAboveOnExactTie() {
        // Construct a tie: roomAbove == roomBelow.
        // roomAbove = 592 - 100 - caret.maxY - 4 = 488 - caret.maxY
        // roomBelow = caret.minY - 4 - 100 - 8 = caret.minY - 112
        // For a height-0 caret (point), caret.maxY == caret.minY:
        //   488 - y = y - 112 → 2y = 600 → y = 300
        let caret = NSRect(x: 100, y: 300, width: 0, height: 0)
        let aboveRoom = (window.maxY - 8) - panelSize.height - caret.maxY - 4
        let belowRoom = caret.minY - (window.minY + 8) - panelSize.height - 4
        #expect(aboveRoom == belowRoom, "sanity: caret y should produce an exact tie")
        let origin = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .auto)
        // Tie → above. origin.y = caret.maxY + 4 = 300 + 4 = 304.
        #expect(origin == NSPoint(x: 100, y: 304))
    }

    // MARK: - Gap + horizontal offset

    @Test func customGapAppliedBetweenCaretAndPanel() {
        // gap = 10 (instead of default 4). Caret at y=100–120, placement above.
        // origin.y = 120 + 10 = 130.
        let caret = NSRect(x: 100, y: 100, width: 0, height: 20)
        let origin = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .above, gap: 10)
        #expect(origin == NSPoint(x: 100, y: 130))
    }

    @Test func horizontalOffsetShiftsXCoordinate() {
        // Same setup as abovePlacesPanelJustAboveCaretWhenRoom, but shifted
        // right by 20pt.
        let caret = NSRect(x: 100, y: 100, width: 0, height: 20)
        let origin = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .above,
            gap: 4, horizontalOffset: 20)
        #expect(origin == NSPoint(x: 120, y: 124))
    }

    // MARK: - Default gap matches the historical 4pt convention

    @Test func defaultGapIsHistoricalFourPoints() {
        // Document the default value — 4pt matches the chat composer's
        // historical visual gap and the omnibox's below-anchor gap.
        let caret = NSRect(x: 0, y: 0, width: 0, height: 0)
        let withDefault = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .above)
        let withExplicitFour = ChatAutocompletePanel.origin(
            caretRect: caret, panelSize: panelSize,
            windowFrame: window, placement: .above, gap: 4)
        #expect(withDefault == withExplicitFour)
    }
}
