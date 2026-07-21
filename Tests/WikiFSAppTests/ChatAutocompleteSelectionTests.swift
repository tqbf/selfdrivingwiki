#if os(macOS)
import Foundation
import AppKit
import Testing
@testable import WikiFS

/// Pure-function unit tests for the chat autocomplete's pure helpers
/// (`ChatAutocompleteSelection.advance`, the extended `ComposerTextView.keyAction`
/// autocomplete-aware variant, and `ComposerTextView.clampedSwiftOffset`).
///
/// All tests are pure (no live panel, no store, no Tantivy) — fast tier only.
/// Mirrors `OmniboxSelectionTests` in shape. The hosted-window integration is
/// covered by the `ComposerAutocompleteHostedTests` suite.
struct ChatAutocompleteSelectionTests {

    // MARK: - ChatAutocompleteSelection.advance (mirrors OmniboxSelection)

    @Test func emptyListReturnsNil() {
        #expect(ChatAutocompleteSelection.advance(current: nil, count: 0, delta: 1) == nil)
        #expect(ChatAutocompleteSelection.advance(current: nil, count: 0, delta: -1) == nil)
        // Even with a non-nil current, an empty list yields nothing.
        #expect(ChatAutocompleteSelection.advance(current: 2, count: 0, delta: 1) == nil)
    }

    @Test func firstDownFromNilSelectsRowZero() {
        #expect(ChatAutocompleteSelection.advance(current: nil, count: 5, delta: 1) == 0)
    }

    @Test func firstUpFromNilSelectsLastRow() {
        #expect(ChatAutocompleteSelection.advance(current: nil, count: 5, delta: -1) == 4)
    }

    @Test func advanceMovesByOne() {
        #expect(ChatAutocompleteSelection.advance(current: 2, count: 5, delta: 1) == 3)
        #expect(ChatAutocompleteSelection.advance(current: 2, count: 5, delta: -1) == 1)
    }

    @Test func clampsAtLowerBound() {
        #expect(ChatAutocompleteSelection.advance(current: 0, count: 5, delta: -1) == 0)
    }

    @Test func clampsAtUpperBound() {
        #expect(ChatAutocompleteSelection.advance(current: 4, count: 5, delta: 1) == 4)
    }

    @Test func singleRowListClampsBothDirections() {
        #expect(ChatAutocompleteSelection.advance(current: nil, count: 1, delta: 1) == 0)
        #expect(ChatAutocompleteSelection.advance(current: nil, count: 1, delta: -1) == 0)
        #expect(ChatAutocompleteSelection.advance(current: 0, count: 1, delta: 1) == 0)
        #expect(ChatAutocompleteSelection.advance(current: 0, count: 1, delta: -1) == 0)
    }

    // MARK: - ComposerTextView.keyAction autocomplete-aware variant

    private let insertNewline = #selector(NSResponder.insertNewline(_:))

    @Test func plainReturnSendsWhenAutocompleteClosed() {
        #expect(ComposerTextView.keyAction(
            for: insertNewline, modifiers: [], autocompleteOpen: false) == .send)
    }

    @Test func plainReturnInsertsAutocompleteWhenOpen() {
        #expect(ComposerTextView.keyAction(
            for: insertNewline, modifiers: [], autocompleteOpen: true) == .insertAutocomplete)
    }

    @Test func shiftReturnStillInsertsNewlineEvenWhenAutocompleteOpen() {
        // Modifier-key Returns bypass autocomplete — they're explicit newline
        // requests, so the user can still type a multi-line message while the
        // dropdown is showing.
        #expect(ComposerTextView.keyAction(
            for: insertNewline, modifiers: .shift, autocompleteOpen: true) == .insertNewline)
        #expect(ComposerTextView.keyAction(
            for: insertNewline, modifiers: .option, autocompleteOpen: true) == .insertNewline)
    }

    @Test func commandReturnFallsThroughEvenWhenAutocompleteOpen() {
        // Cmd+Return belongs to the send button's keyboard shortcut — never
        // consumed by autocomplete.
        #expect(ComposerTextView.keyAction(
            for: insertNewline, modifiers: .command, autocompleteOpen: true) == .unhandled)
    }

    // MARK: - clampedSwiftOffset (UTF-16 → Character offset conversion)

    @Test func asciiTextPreservesOffset() {
        // For ASCII-only text (the common wiki-link case), UTF-16 offsets ==
        // Character offsets.
        let text = "[[page:Erl"
        #expect(ComposerTextView.clampedSwiftOffset(utf16Offset: 5, in: text) == 5)
        #expect(ComposerTextView.clampedSwiftOffset(utf16Offset: 10, in: text) == 10)
    }

    @Test func negativeOffsetClampsToZero() {
        #expect(ComposerTextView.clampedSwiftOffset(utf16Offset: -3, in: "abc") == 0)
    }

    @Test func overlongOffsetClampsToCount() {
        // Beyond the UTF-16 length → clamp to text.count (the scanner will
        // then re-clamp on its side).
        #expect(ComposerTextView.clampedSwiftOffset(utf16Offset: 99, in: "abc") == 3)
    }

    @Test func nonBMPEmojiIsOneCharacterNotTwoUTF16Units() {
        // "👍" is outside the BMP: two UTF-16 units, one Character. The offset
        // conversion must treat it as ONE Swift Character so the prefix
        // scanner (which uses `Array(text)`) sees the right caret position.
        let text = "👍abc"
        // UTF-16 offset 2 points PAST the emoji (it spans units 0 and 1).
        // The Character offset for that position is 1 (the 'a').
        #expect(ComposerTextView.clampedSwiftOffset(utf16Offset: 2, in: text) == 1)
        #expect(ComposerTextView.clampedSwiftOffset(utf16Offset: 5, in: text) == 4)
    }
}
#endif
