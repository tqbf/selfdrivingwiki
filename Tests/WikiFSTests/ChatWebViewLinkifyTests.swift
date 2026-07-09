import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Tests for the agent transcript's wiki-link linkify pre-pass. Assistant/result
/// rows run their markdown through `ReaderMarkdown.prepared` so `[[wiki-links]]`
/// render as clickable `wiki://` anchors; user text is left literal (a user
/// typing `[[Foo]]` is not a link). Covers AC.3 at the row-render seam.
///
/// Phase A.2 adds a `WikiRenderContext`-aware variant (`renderedMarkdown(_:context:)`,
/// `feedRowHTML(for:context:isFinal:)`, `chatRowHTML(for:context:isFinal:)`) so
/// chat transcripts render source references exactly as the reader does — healed
/// display names, `&pin=` quote links, `![[source:…]]` embeds via `wiki-blob://`,
/// and ghost styling for broken links. See the "Phase A.2" section below.
@MainActor
struct ChatWebViewLinkifyTests {

    private typealias Transcript = ChatWebView.Coordinator

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

    // MARK: - Copy button (issue #285)

    @Test func chatAssistantRowHasCopyButtonWithRawText() {
        let html = Transcript.chatRowHTML(for: .assistantText("Hello **world**."))
        #expect(html.contains("copy-btn"))
        // The raw markdown (not rendered HTML) is in data-copy.
        #expect(html.contains(#"data-copy="Hello **world**.""#))
    }

    @Test func chatResultRowHasCopyButtonWithRawText() {
        let html = Transcript.chatRowHTML(for: .result(isError: false, text: "Done."))
        #expect(html.contains("copy-btn"))
        #expect(html.contains(#"data-copy="Done.""#))
    }

    @Test func chatUserRowHasNoCopyButton() {
        let html = Transcript.chatRowHTML(for: .userText("Hello"))
        #expect(!html.contains("copy-btn"))
    }

    @Test func chatToolRowsHaveNoCopyButton() {
        let toolUse = Transcript.chatRowHTML(for: .toolUse(name: "Read", inputSummary: "x"))
        let toolResult = Transcript.chatRowHTML(for: .toolResult(isError: true, summary: "fail"))
        #expect(!toolUse.contains("copy-btn"))
        #expect(!toolResult.contains("copy-btn"))
    }

    @Test func copyDataAttributeEscapesHtmlSpecialChars() {
        let html = Transcript.chatRowHTML(for: .assistantText(#"Say "hi" <b> & bye"#))
        #expect(html.contains("data-copy="))
        // Double quotes → &quot;, < → &lt;, > → &gt;, & → &amp;.
        #expect(html.contains("&quot;hi&quot;"))
        #expect(html.contains("&lt;b&gt;"))
        #expect(html.contains("&amp; bye"))
    }

    @Test func emptyResultRowHasNoCopyButton() {
        let html = Transcript.chatRowHTML(for: .result(isError: false, text: ""))
        #expect(html.isEmpty)
    }

    // MARK: - Phase A.2: nil-context path is behavior-preserving
    //
    // The historical callers that pass NO context (e.g. AgentActivityView's
    // internals feed) must keep the constant-`true` resolution: every link
    // renders resolved, nothing ghosts, no embeds.

    @Test func renderedMarkdownNilContextIsConstantTrue() {
        // nil context (default) → constant-true: a nonexistent target still links
        // (resolves), never to wiki://missing. This is the no-behavior-change
        // baseline for the internals feed.
        let html = Transcript.renderedMarkdown("See [[Ghost Page]] here.")
        #expect(html.contains("<a "))
        #expect(!html.contains("wiki://missing"))
    }

    @Test func feedRowHTMLNilContextDefaultsUnchanged() {
        // Zero-arg convenience (defaults) must match the pre-A.2 output exactly.
        let zeroArg = Transcript.feedRowHTML(for: .assistantText("See [[Ghost]] here."))
        let explicitNil = Transcript.feedRowHTML(for: .assistantText("See [[Ghost]] here."), context: nil, isFinal: true)
        #expect(zeroArg == explicitNil)
        #expect(!zeroArg.contains("wiki://missing"))
    }
}

/// Phase A.2 — the `WikiRenderContext`-aware transcript render. A persisted
/// chat containing a canonical `[[source:ULID|old name]]` (heals to the current
/// name), a `#"quote"` link with `@vN` (emits `&pin=`), an `![[source:…]]`
/// image embed (inline `wiki-blob://`), and a broken link (ghost `wiki://missing`)
/// must render through `renderedMarkdown(_:context:)` / `chatRowHTML(for:context:)`
/// exactly as the reader does. Also covers the two-tier `isFinal` streaming tier
/// (links only while streaming → embeds appear on finalize).
@MainActor
struct AgentTranscriptRenderContextTests {

    private typealias Transcript = ChatWebView.Coordinator

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-ctx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// Same fixture shape as `WikiRenderContextTests`: a page "Home", a byteful
    /// source "Paper.pdf" renamed to "My Paper" with a 3-deep `@vN` chain.
    private func makeFixture() throws -> (model: WikiStoreModel,
                                          homeID: PageID,
                                          paperID: PageID,
                                          v2ID: PageID) {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let home = try store.createPage(title: "Home")
        let paper = try store.addSource(
            filename: "Paper.pdf", data: Data("%PDF".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: "application/pdf", provenance: nil, role: .primary,
            originalPath: nil, activityID: nil)
        try store.renameSource(id: paper.id, to: "My Paper")
        _ = try store.appendProcessedMarkdown(
            sourceID: paper.id, content: "v1 body", origin: "extraction", note: nil)
        let v2 = try store.appendProcessedMarkdown(
            sourceID: paper.id, content: "the quoted text", origin: "extraction", note: nil)
        _ = try store.appendProcessedMarkdown(
            sourceID: paper.id, content: "v3 body", origin: "extraction", note: nil)
        model.reloadFromStore()
        return (model, home.id, paper.id, v2.id)
    }

    @Test func canonicalSourceULIDHealsToCurrentDisplayName() throws {
        let (model, _, paperID, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        // A persisted chat recorded the STALE alias "old name"; at render it must
        // heal to the current display name "My Paper".
        let markdown = "See [[source:\(paperID.rawValue)|old name]] for details."
        let html = Transcript.renderedMarkdown(markdown, context: ctx)
        #expect(html.contains("My Paper"))
        #expect(!html.contains("old name"))
    }

    @Test func quoteLinkWithVersionPinEmitsPinQuery() throws {
        let (model, _, paperID, v2ID) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        // A `[[source:ULID@vN#"quote"]]` link must carry pin=<v2ID> (as `&pin=`
        // or `&amp;pin=` depending on the HTML serializer) so the destination
        // loads the pinned extraction where the quote lives. The `@vN` ordinal
        // precedes the fragment (parser convention; see Phase6PinningPureTests).
        let markdown = "Quote: [[source:\(paperID.rawValue)@v2#\"the quoted text\"]]."
        let html = Transcript.renderedMarkdown(markdown, context: ctx)
        #expect(html.contains("pin=\(v2ID.rawValue)"))
        #expect(html.contains("wiki://"))
    }

    @Test func sourceEmbedRendersInlineBlobURL() throws {
        let (model, _, paperID, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        // An `![[source:Paper.pdf]]` embed renders an inline element pointing at
        // the blob scheme the registered BlobSchemeHandler serves. A PDF dispatches
        // to `<iframe class="wiki-embed-pdf" src="wiki-blob://…">`; an image would
        // be `<img src="wiki-blob://…">`. Either way the blob URL proves the embed
        // resolves through the same serving path as the reader.
        let markdown = "Figure: ![[source:Paper.pdf]]"
        let html = Transcript.renderedMarkdown(markdown, context: ctx)
        #expect(html.contains("wiki-blob://source/\(paperID.rawValue)"))
        #expect(html.contains("wiki-embed"))
    }

    @Test func brokenLinkGhostsViaMissingHost() throws {
        let (model, _, _, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        // A link to a page that doesn't exist → wiki://missing (the reader's
        // ghost marker; CSS dims `a[href^="wiki://missing"]`).
        let html = Transcript.renderedMarkdown("See [[Ghost Page]] here.", context: ctx)
        #expect(html.contains("wiki://missing"))
    }

    @Test func chatRowHTMLThreadsContextIntoAssistantBubble() throws {
        let (model, _, paperID, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        let row = Transcript.chatRowHTML(
            for: .assistantText("See [[source:\(paperID.rawValue)|stale]]."),
            context: ctx, isFinal: true)
        // The healed name appears inside the chat bubble's link; the stale alias
        // does not. Note: the raw text survives in the copy button's `data-copy`
        // attribute (issue #285), so we check the *rendered link* text, not the
        // whole row.
        #expect(row.contains("My Paper"))
        #expect(row.contains(">My Paper</a>"))
        #expect(!row.contains(">stale</a>"))
    }

    // MARK: - Two-tier streaming render (isFinal)

    @Test func streamingTierSuppressesEmbeds() throws {
        let (model, _, paperID, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        // While streaming (isFinal == false), embeds are suppressed so a
        // half-typed `![[source:…` never instantiates a broken iframe/player.
        let markdown = "Figure: ![[source:Paper.pdf]]"
        let streaming = Transcript.renderedMarkdown(markdown, context: ctx, isFinal: false)
        #expect(!streaming.contains("wiki-blob://source/\(paperID.rawValue)"))
        #expect(!streaming.contains("wiki-embed"))
        // Links still render in the streaming tier (links-only).
        let linkStreaming = Transcript.renderedMarkdown(
            "See [[source:\(paperID.rawValue)|stale]].", context: ctx, isFinal: false)
        #expect(linkStreaming.contains("My Paper"))  // healed name still applies
    }

    @Test func finalizedTierRendersEmbeds() throws {
        let (model, _, paperID, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        // On finalize (isFinal == true, the default), the embed renders.
        let markdown = "Figure: ![[source:Paper.pdf]]"
        let finalized = Transcript.renderedMarkdown(markdown, context: ctx, isFinal: true)
        #expect(finalized.contains("wiki-blob://source/\(paperID.rawValue)"))
        #expect(finalized.contains("wiki-embed"))
    }

    @Test func streamingRowThenFinalizedRowChat() throws {
        let (model, _, paperID, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        // Simulate the coordinator's two-tier sequence: the same assistant row is
        // first rendered streaming (links only), then re-rendered final (embeds).
        let text = "Embedded: ![[source:Paper.pdf]] and [[source:\(paperID.rawValue)|old]]."
        let streaming = Transcript.chatRowHTML(for: .assistantText(text), context: ctx, isFinal: false)
        let finalized = Transcript.chatRowHTML(for: .assistantText(text), context: ctx, isFinal: true)
        // Streaming: no embed; the link still heals.
        #expect(!streaming.contains("wiki-blob://source/\(paperID.rawValue)"))
        #expect(streaming.contains("My Paper"))
        // Finalized: the embed now appears.
        #expect(finalized.contains("wiki-blob://source/\(paperID.rawValue)"))
        #expect(finalized.contains("wiki-embed"))
    }
}
