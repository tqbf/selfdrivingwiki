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
}
