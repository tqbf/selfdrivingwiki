import Foundation
import Testing
@testable import WikiFSLinks

/// Pure-function unit tests for `WikiLinkPrefixScanner` — the chat composer's
/// `[[kind:partial` trigger detector (issues #436 / #638, plan §6a).
///
/// All tests are pure (no AppKit, no DB) — fast tier only. The scanner lives
/// in `WikiFSLinks` (Foundation-only) so it's testable directly without the
/// app target.
struct WikiLinkPrefixScannerTests {

    // MARK: - Basic detection (AC #1)

    @Test func detectsOpenPagePrefixAtEndOfText() {
        let text = "Hello [[page:Erl"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger != nil)
        #expect(trigger?.kind == .page)
        #expect(trigger?.partial == "Erl")
        // The range covers the full `[[page:Erl` span.
        let span = String(text[trigger!.range])
        #expect(span == "[[page:Erl")
    }

    @Test func detectsOpenSourcePrefix() {
        let text = "[[source:Erlang Spec"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger?.kind == .source)
        #expect(trigger?.partial == "Erlang Spec")
    }

    @Test func detectsOpenChatPrefix() {
        let text = "[[chat:Standup notes"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger?.kind == .chat)
        #expect(trigger?.partial == "Standup notes")
    }

    @Test func bareOpenBracketsDefaultToPage() {
        // Per WikiLinkParser.classify (:52), bare `[[Foo` is a page link.
        let text = "Some text [[Erickson"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger?.kind == .page)
        #expect(trigger?.partial == "Erickson")
    }

    // MARK: - Rejection: closed/aliased links (AC #6 — don't fire once closed)

    @Test func closedLinkAfterCaretReturnsNil() {
        let text = "… [[page:Foo]] more text"
        // Caret in "more text" — there's a closed link before it.
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger == nil)
    }

    @Test func caretInsideClosedLinkReturnsNil() {
        // The link is closed — autocomplete shouldn't fire mid-link.
        let text = "[[page:Erl]]"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger == nil)
    }

    @Test func pipeAliasReturnsNil() {
        // `|` starts the alias; we don't autocomplete inside an aliased link.
        let text = "[[page:Erl|Erlan"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger == nil)
    }

    // MARK: - Rejection: empty / minimal triggers

    @Test func emptyPartialAfterKindPrefixReturnsNil() {
        // Don't fire on bare `[[page:` — the user hasn't typed anything yet.
        let text = "[[page:"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger == nil)
    }

    @Test func whitespaceOnlyPartialReturnsNil() {
        let text = "[[page:   "
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger == nil)
    }

    @Test func noOpenBracketsReturnsNil() {
        let text = "Just some plain text"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger == nil)
    }

    // MARK: - Reviewer correction #4: newline + paste guards

    @Test func newlineInPartialReturnsNil() {
        // Multi-line trigger — the user pressed Return inside the trigger.
        // Autocomplete shouldn't fire across a newline (paste + multi-line guard).
        let text = "[[page:Erl\nmore"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger == nil)
    }

    @Test func carriageReturnInPartialReturnsNil() {
        let text = "[[page:Erl\rmore"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger == nil)
    }

    @Test func overlongPartialReturnsNil() {
        // Paste guard: a `[[…` followed by a long string is a paste, not a
        // title being typed. The scanner bails at `maxPartialSpan`.
        let long = String(repeating: "a", count: WikiLinkPrefixScanner.maxPartialSpan + 1)
        let text = "[[page:\(long)"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger == nil)
    }

    @Test func atMaxPartialSpanIsAccepted() {
        // Boundary: the cap is inclusive (a `partial` of exactly
        // `maxPartialSpan - "<kind>:"` chars is still fine).
        let span = WikiLinkPrefixScanner.maxPartialSpan - 1
        let partial = String(repeating: "a", count: span)
        let text = "[[\(partial)"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger != nil)
        #expect(trigger?.partial == partial)
    }

    // MARK: - Caret position mid-text

    @Test func caretMidTokenReadsPartialPrefix() {
        // `[[page:Erickson` with the caret after "Eri" should yield partial "Eri".
        let text = "[[page:Erickson"
        let caret = "[[page:Eri".count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger?.partial == "Eri")
        // Range covers only `[[page:Eri` (up to the caret).
        let span = String(text[trigger!.range])
        #expect(span == "[[page:Eri")
    }

    @Test func caretAfterClosedLinkAndNewOpenLinkDetectsTheNewOne() {
        // A closed link earlier in the text + a fresh open `[[page:X` at the
        // caret: the scanner should find the most-recent `[[`, not the
        // already-closed one.
        let text = "see [[page:Closed]] and [[page:Erl"
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger?.kind == .page)
        #expect(trigger?.partial == "Erl")
    }

    // MARK: - Trim behavior

    @Test func surroundingWhitespaceInPartialIsTrimmed() {
        let text = "[[page:  Erl  "
        let caret = text.count
        let trigger = WikiLinkPrefixScanner.openLink(at: caret, in: text)
        #expect(trigger?.partial == "Erl")
    }
}
