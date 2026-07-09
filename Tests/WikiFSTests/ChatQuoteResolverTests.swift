import Foundation
import Testing
import WikiFSCore

/// Unit tests for `ChatQuoteResolver` — the pure `[[chat:Title#"quote"]]` →
/// message resolution (issue #281). Mirrors the source quote-anchor coverage:
/// quote stripping, whitespace/case-tolerant first-match, nil when absent, and
/// matching across the prose event kinds the transcript renders.
struct ChatQuoteResolverTests {

    // MARK: - quoteText (delimiter stripping)

    @Test func quoteTextStripsSurroundingQuotes() {
        #expect(ChatQuoteResolver.quoteText(#""the fix""#) == "the fix")
    }

    @Test func quoteTextPreservesInnerQuotes() {
        #expect(ChatQuoteResolver.quoteText(#""she said "hi""#) == #"she said "hi"#)
    }

    @Test func quoteTextHandlesBareFragment() {
        // A fragment without delimiters still resolves (defensive).
        #expect(ChatQuoteResolver.quoteText("the fix") == "the fix")
    }

    @Test func quoteTextTrimsWhitespace() {
        #expect(ChatQuoteResolver.quoteText(#"  "the fix"  "#) == "the fix")
    }

    // MARK: - messageIndex (resolution)

    @Test func matchesAssistantTextExact() {
        let events: [AgentEvent] = [
            .userText("what happened?"),
            .assistantText("The fix was in didDeleteItems."),
        ]
        #expect(ChatQuoteResolver.messageIndex(of: #""The fix was in didDeleteItems""#, in: events) == 1)
    }

    @Test func matchesCaseInsensitively() {
        let events: [AgentEvent] = [(.assistantText("The Fix Was Here") as AgentEvent)]
        #expect(ChatQuoteResolver.messageIndex(of: #""the fix was here""#, in: events) == 0)
    }

    @Test func matchesAcrossCollapsedWhitespace() {
        // The transcript wraps the passage across lines / extra spaces; the
        // quote author wrote it on one line. Both normalize to single spaces.
        let events: [AgentEvent] = [
            .assistantText("The   fix\nwas\n  in didDeleteItems."),
        ]
        #expect(ChatQuoteResolver.messageIndex(of: #""the fix was in didDeleteItems""#, in: events) == 0)
    }

    @Test func matchesPartialQuoteSubstring() {
        // A quote anchor cites a passage, not a whole message.
        let events: [AgentEvent] = [
            .assistantText("First we tried X. The fix was in didDeleteItems. Then we verified."),
        ]
        #expect(ChatQuoteResolver.messageIndex(of: #""the fix was in didDeleteItems""#, in: events) == 0)
    }

    @Test func firstMatchWinsOnRepeat() {
        let events: [AgentEvent] = [
            .assistantText("the fix was here"),
            .assistantText("the fix was here again"),
        ]
        #expect(ChatQuoteResolver.messageIndex(of: #""the fix was here""#, in: events) == 0)
    }

    @Test func returnsNilWhenAbsent() {
        let events: [AgentEvent] = [.assistantText("nothing relevant here")]
        #expect(ChatQuoteResolver.messageIndex(of: #""the fix""#, in: events) == nil)
    }

    @Test func returnsNilForEmptyQuote() {
        let events: [AgentEvent] = [.assistantText("something")]
        #expect(ChatQuoteResolver.messageIndex(of: #""""#, in: events) == nil)
        #expect(ChatQuoteResolver.messageIndex(of: "", in: events) == nil)
    }

    @Test func matchesUserText() {
        let events: [AgentEvent] = [
            .userText("remind me: the fix was in didDeleteItems"),
            .assistantText("noted"),
        ]
        #expect(ChatQuoteResolver.messageIndex(of: #""the fix was in didDeleteItems""#, in: events) == 0)
    }

    @Test func matchesResultEvent() {
        let events: [AgentEvent] = [
            .userText("q"),
            .assistantText("working…"),
            .result(isError: false, text: "Done. The fix was in didDeleteItems."),
        ]
        #expect(ChatQuoteResolver.messageIndex(of: #""the fix was in didDeleteItems""#, in: events) == 2)
    }

    @Test func skipsNonSearchableEvents() {
        // systemInit / deltas / messageStop render no searchable row and are
        // skipped — the index points at the real prose event.
        let events: [AgentEvent] = [
            .systemInit(model: "claude"),
            .assistantTextDelta("partial"),
            .assistantText("The fix was in didDeleteItems."),
            .messageStop,
        ]
        #expect(ChatQuoteResolver.messageIndex(of: #""the fix was in didDeleteItems""#, in: events) == 2)
    }

    @Test func matchesToolUseSummary() {
        let events: [AgentEvent] = [
            .userText("q"),
            .toolUse(name: "Read", inputSummary: "the fix was in didDeleteItems"),
        ]
        #expect(ChatQuoteResolver.messageIndex(of: #""the fix was in didDeleteItems""#, in: events) == 1)
    }

    // MARK: - searchableText

    @Test func searchableTextForProseEvents() {
        #expect(ChatQuoteResolver.searchableText(.userText("hi")) == "hi")
        #expect(ChatQuoteResolver.searchableText(.assistantText("hello")) == "hello")
        #expect(ChatQuoteResolver.searchableText(.result(isError: false, text: "done")) == "done")
    }

    @Test func searchableTextEmptyForNonRendered() {
        #expect(ChatQuoteResolver.searchableText(.systemInit(model: "x")).isEmpty)
        #expect(ChatQuoteResolver.searchableText(.assistantTextDelta("x")).isEmpty)
        #expect(ChatQuoteResolver.searchableText(.messageStop).isEmpty)
    }
}
