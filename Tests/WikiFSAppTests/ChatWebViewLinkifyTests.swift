#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore
@testable import WikiFSTypes

/// Tests for the agent transcript's wiki-link linkify pre-pass. Assistant/result
/// rows run their markdown through `ReaderMarkdown.prepared` so `[[wiki-links]]`
/// render as clickable `wiki://` anchors. User text is also rendered through
/// the markdown renderer so attachment references from drag-to-chat (#385)
/// render as clickable links.
///
/// Phase A.2 adds a `WikiRenderContext`-aware renderer (`renderedMarkdown(_:context:)`
/// and `chatDisplayRowHTML(_:context:)`) so
/// chat transcript rows render source references exactly as the reader does — healed
/// display names, `&pin=` quote links, `![[source:…]]` embeds via `wiki-blob://`,
/// and ghost styling for broken links. See the "Phase A.2" section below.
@MainActor
struct ChatWebViewLinkifyTests {

    private typealias Transcript = ChatWebView.Coordinator

    private let turnID = ChatTurnID(rawValue: "turn-linkify")

    private func assistantRow(
        _ text: String,
        state: ChatDisplayContentState = .final
    ) -> ChatDisplayRow {
        .assistantMessage(
            id: ChatMessageID(rawValue: "assistant-linkify"),
            turnID: turnID,
            text: text,
            createdAt: .distantPast,
            contentState: state
        )
    }

    @Test func renderedMarkdownLinkifiesWikiLinks() {
        let html = Transcript.renderedMarkdown("See [[Page Name]] here.")
        #expect(html.contains("<a "))
        #expect(html.contains("wiki://"))
        #expect(html.contains("Page%20Name"))
    }

    @Test func typedAssistantRowLinkifies() {
        let html = Transcript.chatDisplayRowHTML(assistantRow("See [[Page]] here."))
        #expect(html.contains("wiki://"))
        #expect(html.contains("<a "))
    }

    @Test func typedUserRowLinkifiesWikiLinks() {
        let row = ChatDisplayRow.userMessage(
            id: ChatMessageID(rawValue: "user-linkify"),
            turnID: turnID,
            text: "See [[Page]] here.",
            createdAt: .distantPast
        )
        let html = Transcript.chatDisplayRowHTML(row)
        #expect(html.contains("<a "))
        #expect(html.contains("wiki://"))
    }

    @Test func typedAssistantRowHasEscapedRawCopyText() {
        let html = Transcript.chatDisplayRowHTML(assistantRow(#"Say "hi" <b> & bye"#))
        #expect(html.contains("copy-btn"))
        #expect(html.contains("&quot;hi&quot;"))
        #expect(html.contains("&lt;b&gt;"))
        #expect(html.contains("&amp; bye"))
    }

    @Test func typedToolRowUsesDisclosureMarkup() {
        let row = ChatDisplayRow.toolCall(
            id: ToolCallID(rawValue: "tool-linkify"),
            turnID: turnID,
            toolName: "Read",
            status: .running,
            detail: "page.md",
            output: nil,
            permissionRequestID: nil,
            updatedAt: .distantPast
        )
        let html = Transcript.chatDisplayRowHTML(row)
        #expect(html.contains("<details"))
        #expect(html.contains("Read"))
        #expect(html.contains("page.md"))
    }

    // MARK: - Phase A.2: nil-context path is behavior-preserving
    //
    // The historical callers that pass NO context (e.g. AgentQueueView's
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

}

/// Phase A.2 — the `WikiRenderContext`-aware transcript render. A persisted
/// chat containing a canonical `[[source:ULID|old name]]` (heals to the current
/// name), a `#"quote"` link with `@vN` (emits `&pin=`), an `![[source:…]]`
/// image embed (inline `wiki-blob://`), and a broken link (ghost `wiki://missing`)
/// must render through `renderedMarkdown(_:context:)` / `chatDisplayRowHTML(_:context:)`
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
                                          paperID: SourceID,
                                          v2ID: SourceMarkdownVersionID) {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let home = try store.createPage(title: "Home")
        let paper = try store.addSource(
            filename: "Paper.pdf", data: Data("%PDF".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: "application/pdf", provenance: nil, role: .primary,
            originalPath: nil, activityID: nil)
        try store.renameSource(id: paper.id, to: "My Paper")
        _ = try store.appendProcessedMarkdown(
            sourceID: paper.id, content: "v1 body", origin: .extraction, note: nil)
        let v2 = try store.appendProcessedMarkdown(
            sourceID: paper.id, content: "the quoted text", origin: .extraction, note: nil)
        _ = try store.appendProcessedMarkdown(
            sourceID: paper.id, content: "v3 body", origin: .extraction, note: nil)
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

    @Test func typedAssistantRowThreadsContextIntoAssistantMarkup() throws {
        let (model, _, paperID, _) = try makeFixture()
        let ctx = WikiRenderContext.build(from: model)
        let row = Transcript.chatDisplayRowHTML(
            .assistantMessage(
                id: ChatMessageID(rawValue: "context-assistant"),
                turnID: ChatTurnID(rawValue: "context-turn"),
                text: "See [[source:\(paperID.rawValue)|stale]].",
                createdAt: .distantPast,
                contentState: .final
            ),
            context: ctx
        )
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
        let streaming = Transcript.chatDisplayRowHTML(
            .assistantMessage(
                id: ChatMessageID(rawValue: "streaming-assistant"),
                turnID: ChatTurnID(rawValue: "streaming-turn"),
                text: text,
                createdAt: .distantPast,
                contentState: .streaming
            ),
            context: ctx
        )
        let finalized = Transcript.chatDisplayRowHTML(
            .assistantMessage(
                id: ChatMessageID(rawValue: "final-assistant"),
                turnID: ChatTurnID(rawValue: "streaming-turn"),
                text: text,
                createdAt: .distantPast,
                contentState: .final
            ),
            context: ctx
        )
        // Streaming: no embed; the link still heals.
        #expect(!streaming.contains("wiki-blob://source/\(paperID.rawValue)"))
        #expect(streaming.contains("My Paper"))
        // Finalized: the embed now appears.
        #expect(finalized.contains("wiki-blob://source/\(paperID.rawValue)"))
        #expect(finalized.contains("wiki-embed"))
    }
}
#endif
