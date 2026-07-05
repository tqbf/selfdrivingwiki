import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Tests for the agent transcript's wiki-link linkify pre-pass. Assistant/result
/// rows run their markdown through `ReaderMarkdown.prepared` so `[[wiki-links]]`
/// render as clickable `wiki://` anchors; user text is left literal (a user
/// typing `[[Foo]]` is not a link). Covers AC.3 at the row-render seam.
@MainActor
struct AgentTranscriptLinkifyTests {

    private typealias Transcript = AgentTranscriptWebView.Coordinator

    @Test func renderedMarkdownLinkifiesWikiLinks() {
        let html = Transcript.renderedMarkdown("See [[Page Name]] here.")
        #expect(html.contains("<a "))
        #expect(html.contains("wiki://"))
        #expect(html.contains("Page%20Name"))
    }

    @Test func feedAssistantRowLinkifies() {
        let html = Transcript.feedRowHTML(for: .assistantText("See [[Page]] here."))
        #expect(html.contains("wiki://"))
        #expect(html.contains("<a "))
    }

    @Test func feedUserRowStaysLiteral() {
        let html = Transcript.feedRowHTML(for: .userText("See [[Page]] here."))
        // No anchor tag — the raw brackets survive as literal text.
        #expect(!html.contains("<a "))
        #expect(!html.contains("wiki://"))
        #expect(html.contains("[[Page]]"))
    }

    @Test func feedResultRowLinkifies() {
        let html = Transcript.feedRowHTML(for: .result(isError: false, text: "See [[Page]] here."))
        #expect(html.contains("wiki://"))
    }

    @Test func chatAssistantRowLinkifies() {
        let html = Transcript.chatRowHTML(for: .assistantText("See [[Page]] here."))
        #expect(html.contains("wiki://"))
        #expect(html.contains("<a "))
    }

    @Test func chatUserRowStaysLiteral() {
        let html = Transcript.chatRowHTML(for: .userText("See [[Page]] here."))
        #expect(!html.contains("<a "))
        #expect(!html.contains("wiki://"))
    }

    @Test func chatResultRowLinkifies() {
        let html = Transcript.chatRowHTML(for: .result(isError: false, text: "See [[Page]] here."))
        #expect(html.contains("wiki://"))
    }

    // MARK: - Concise tool-call summaries (issue #173)

    @Test func chatToolUseRowRendersConciseSummary() {
        let html = Transcript.chatRowHTML(for: .toolUse(name: "Read", inputSummary: "page.md"))
        #expect(html.contains("chat-tool"))
        #expect(html.contains("Read"))
        #expect(html.contains("page.md"))
        // Not a chat bubble — it's a status line.
        #expect(!html.contains("bubble"))
    }

    @Test func chatToolUseRowWithoutSummaryStillShowsName() {
        let html = Transcript.chatRowHTML(for: .toolUse(name: "Grep", inputSummary: ""))
        #expect(html.contains("Grep"))
        #expect(html.contains("chat-tool"))
    }

    @Test func chatToolResultErrorRowRenders() {
        let html = Transcript.chatRowHTML(for: .toolResult(isError: true, summary: "file not found"))
        #expect(html.contains("chat-tool"))
        #expect(html.contains("is-error"))
        #expect(html.contains("file not found"))
    }

    @Test func chatToolResultSuccessRowIsEmpty() {
        let html = Transcript.chatRowHTML(for: .toolResult(isError: false, summary: "ok"))
        #expect(html.isEmpty)
    }
}
