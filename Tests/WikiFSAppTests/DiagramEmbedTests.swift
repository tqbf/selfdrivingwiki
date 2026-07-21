#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Issue #670 — Mermaid diagram source embeds (`![[source:diagram.mmd]]`).
///
/// A `.mmd` source (or any `text/mermaid` source) embedded in a page renders
/// inline as a fenced ```mermaid code block, picked up by the reader's
/// `mermaidBootstrapJS` (which converts `code.language-mermaid` elements into
/// `<div class="mermaid">` and invokes the bundled `mermaid.min.js` (v11))
/// and rendered as an inline SVG — no per-embed JS. The diagram source text
/// travels through the embed target itself (`EmbedTarget.content`) so the
/// renderer stays pure / store-free.
///
/// Three layers tested here:
///   1. `EmbedTarget.Kind.diagram` + the `content` field (#670 §1).
///   2. `WikiRenderContext` resolves a `.mmd` source to a `.diagram` target
///      carrying the source text (#670 §2) — the same text the source-detail
///      Reader tab would show.
///   3. `WikiLinkMarkdown.embedHTML` emits the diagram as a fenced
///      ```mermaid code block (NOT a raw `<div class="mermaid">` div — that
///      path broke under `MarkdownHTMLRenderer` in paragraph / list / blank-
///      line contexts, #736). The fenced block survives swift-markdown's
///      parse in every context, and the reader's `mermaidBootstrapJS`
///      converts the resulting `code.language-mermaid` element back into a
///      `<div class="mermaid">` with `textContent` = the raw diagram source
///      (#670 §3, #736).
@MainActor
struct DiagramEmbedTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagram-embed-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    // MARK: - EmbedTarget API surface (#670 §1)

    @Test func diagramKindExistsAndCarriesContent() throws {
        // The new `.diagram` kind + `content` field are the public surface the
        // renderer dispatches on. `url` is informational for diagrams.
        let target = EmbedTarget(
            kind: .diagram, url: "01HDIAGRAM0000000000000001",
            content: "flowchart LR\n  A --> B")
        #expect(target.kind == .diagram)
        #expect(target.content == "flowchart LR\n  A --> B")
        #expect(target.url == "01HDIAGRAM0000000000000001")
    }

    @Test func mediaTargetsKeepNilContentByDefault() throws {
        // Existing media embed constructors (provider iframe, direct-remote
        // audio/video) carry no content — backward compat: `content` defaults to
        // nil so unchanged call sites stay clean.
        let iframe = EmbedTarget(kind: .iframe, url: "https://player/1")
        let audio = EmbedTarget(kind: .audio, url: "https://x/ep.mp3")
        let video = EmbedTarget(kind: .video, url: "https://x/clip.mp4")
        #expect(iframe.content == nil)
        #expect(audio.content == nil)
        #expect(video.content == nil)
    }

    @Test func allKindsDistinguishInEquality() throws {
        // `.diagram` must be its own case — not blend into an existing one.
        // Equality on `Kind` is what switch statements compile down to.
        #expect(EmbedTarget.Kind.diagram != .iframe)
        #expect(EmbedTarget.Kind.diagram != .audio)
        #expect(EmbedTarget.Kind.diagram != .video)
    }

    // MARK: - WikiRenderContext resolution (#670 §2)

    @Test func renderContextResolvesMmdSourceToDiagramTarget() throws {
        // A `.mmd` source — the byteful case `embedDescriptors()` skips
        // (`WHERE sv.blob_hash IS NULL`), so the diagram-resolution path
        // in `WikiRenderContext.build(from:)` is what fills its embed entry.
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let diagram = "flowchart LR\n  A --> B\n  B --> C"
        // .mmd extension → `text/mermaid` mime (via `MimeType.mime(forExtension:)`,
        // the #620 fallback for extensions UTType can't resolve).
        let src = try store.addSource(
            filename: "Flow.mmd", data: Data(diagram.utf8))
        model.reloadFromStore()

        let ctx = WikiRenderContext.build(from: model)

        // The source is a `.diagram` target carrying the raw mermaid text —
        // resolved by filename (lowercased "flow.mmd"), by id, and by
        // ext-stripped ("flow").
        let byName = try #require(ctx.embedInfo("flow.mmd"))
        #expect(byName.id == src.id)
        let target = try #require(byName.target)
        #expect(target.kind == .diagram)
        #expect(target.content == diagram)
        #expect(target.url == src.id.rawValue)  // informational
        // By ext-stripped name.
        let byStripped = try #require(ctx.embedInfo("flow"))
        #expect(byStripped.id == src.id)
        // By canonical id (lowercased).
        let byID = try #require(ctx.embedInfo(src.id.rawValue.lowercased()))
        #expect(byID.id == src.id)
    }

    @Test func renderContextResolvesTextMermaidMimeSource() throws {
        // A source with the explicit `text/mermaid` mime (no `.mmd` extension)
        // also resolves to a `.diagram` target — the detector's MIME arm fires.
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let diagram = "sequenceDiagram\n  Alice->>Bob: Hi"
        let src = try store.addSource(
            filename: "sequence.txt", data: Data(diagram.utf8),
            mimeType: "text/mermaid")
        model.reloadFromStore()

        let ctx = WikiRenderContext.build(from: model)
        let info = try #require(ctx.embedInfo("sequence.txt"))
        let target = try #require(info.target)
        #expect(target.kind == .diagram)
        #expect(target.content == diagram)
        #expect(info.id == src.id)
    }

    @Test func renderContextDoesNotResolveNonMermaidTextSource() throws {
        // A generic `.md` source with no fenced ```mermaid block does NOT
        // produce a `.diagram` target — the cheap detector (mime + filename
        // only, `content: nil`) returns false, so the source falls through to
        // the byteful blob / cite-link path unchanged.
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        _ = try store.addSource(
            filename: "notes.md", data: Data("# Notes\nHello world".utf8))
        model.reloadFromStore()

        let ctx = WikiRenderContext.build(from: model)
        let info = try #require(ctx.embedInfo("notes.md"))
        // No diagram target — the source's mime (text/markdown) does not match
        // and the filename isn't `.mmd`.
        #expect(info.target == nil)
    }

    @Test func renderContextEmptyOrUnencodableBytesFallsBackToNoTarget() throws {
        // A `.mmd` source whose bytes couldn't be decoded as UTF-8 does NOT
        // produce a `.diagram` target with garbage content — we refuse to emit
        // a ```mermaid block against text we can't read. Falls back to nil
        // (the renderer emits a cite link).
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        // Invalid UTF-8 — `String(data:encoding:.utf8)` returns nil.
        let badBytes = Data([0xFF, 0xFE, 0xFD])
        _ = try store.addSource(
            filename: "broken.mmd", data: badBytes)
        model.reloadFromStore()

        let ctx = WikiRenderContext.build(from: model)
        let info = try #require(ctx.embedInfo("broken.mmd"))
        // bytes present but un-decodable as UTF-8 → no diagram target.
        #expect(info.target == nil)
    }

    // MARK: - embedHTML emits the mermaid fence (#670 §3)

    @Test func embedDiagramTargetRendersMermaidFence() throws {
        let id = PageID(rawValue: "01HDIAGRAM000000000000000A")
        let target = EmbedTarget(
            kind: .diagram, url: id.rawValue,
            content: "flowchart LR\n  A --> B")
        let out = WikiLinkMarkdown.linkified(
            "![[source:Flow]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(
                    id: id, mimeType: "text/mermaid", target: target)
            }
        )
        // The diagram is emitted as a fenced ```mermaid code block (NOT a raw
        // `<div class="mermaid">` div — that path relied on swift-markdown's
        // HTML-block detection, which breaks mid-paragraph / in-list / with
        // blank lines; #736). The reader's `MarkdownHTMLRenderer.visitCodeBlock`
        // emits `<pre><code class="language-mermaid">…</code></pre>`, and the
        // reader's `mermaidBootstrapJS` reads `code.textContent` (which
        // un-escapes the renderer's `&gt;` back to `>`) before rendering,
        // mirroring the same path every hand-written ```mermaid fence uses.
        #expect(out.contains("```mermaid"))
        #expect(out.contains("flowchart LR"))
        // The diagram source passes through UNESCAPED — visitCodeBlock and the
        // HTML parser both treat the inside of a fenced block as literal text.
        #expect(out.contains("A --> B"))
        // Backing fence closes the block.
        #expect(out.range(of: "```\\s*$", options: .regularExpression) != nil)
        // The diagram is NOT a wiki-blob (no bytes fetched) and NOT a cite link.
        #expect(!out.contains("wiki-blob://"))
        #expect(!out.contains("wiki://source"))
        // No raw div — the old #670 contract that broke under markdown
        // conversion (#736).
        #expect(!out.contains("<div class=\"mermaid\">"))
    }

    @Test func embedDiagramHTMLEscapeNotRequired() throws {
        // A fenced code block treats its contents as literal text — no escaping
        // is needed at the linkify stage. visitCodeBlock will escape once (so
        // the HTML parser stays safe), and `code.textContent` reads back the
        // raw `<`/`>`/`&`. This replaces the old escape-on-emit contract.
        let id = PageID(rawValue: "01HDIAGRAM000000000000000B")
        // A diagram with `<`, `>`, `&` in the body (e.g. a node label).
        let diagram = "flowchart LR\n  A[\"x < y & z > w\"] --> B"
        let target = EmbedTarget(
            kind: .diagram, url: id.rawValue, content: diagram)
        let out = WikiLinkMarkdown.linkified(
            "![[source:Inequality]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(
                    id: id, mimeType: "text/mermaid", target: target)
            }
        )
        // The raw chars survive verbatim — they're escaped by visitCodeBlock,
        // not linkify. We must NOT pre-escape here or mermaid will see a
        // double-escaped `&amp;gt;` after the renderer's pass.
        #expect(out.contains("x < y & z > w"))
        // No raw `<div>` — fenced code only.
        #expect(!out.contains("<div class=\"mermaid\">"))
        #expect(out.contains("```mermaid"))
    }

    @Test func embedDiagramWithBackticksInSourceUsesLongerFence() throws {
        // When the diagram source itself contains a ``` run (or longer), the
        // emitted fence must be one longer so it isn't closed early. CommonMark
        // §4.5: a closing fence must be at least as long as the opening fence.
        let id = PageID(rawValue: "01HDIAGRAM000000000000000C")
        let diagram = "graph TD\n    A[\"has ``` triple backticks\"] --> B"
        let target = EmbedTarget(
            kind: .diagram, url: id.rawValue, content: diagram)
        let out = WikiLinkMarkdown.linkified(
            "![[source:Backticks]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(
                    id: id, mimeType: "text/mermaid", target: target)
            }
        )
        // No 3-backtick fence opens the block (the source contains one — we
        // bump to 4+). Output contains a ```mermaid opening fence ONLY inside
        // the diagram body, never as the actual block opener.
        #expect(out.contains("````mermaid"))
        // The inner ``` triple survives intact (no premature close).
        #expect(out.contains("\"has ``` triple backticks\""))
        // …and the fence closes with at least 4 backticks.
        #expect(out.range(of: "````\\s*$", options: .regularExpression) != nil)
    }

    @Test func embedDiagramWithoutTargetRendersBrokenHeader() throws {
        // Plan v2: a `.mmd` source name the embedInfo resolver returns nil for
        // → the renderer emits a muted broken-source `<details>` (no fetch).
        // Pre-v2 this was a cite link; the v2 contract renders a broken embed
        // so unresolved `![[source:…]]` is visually consistent with missing
        // page embeds.
        let out = WikiLinkMarkdown.linkified(
            "![[source:missing-diagram.mmd]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in nil }
        )
        #expect(out.contains("sdw-transclusion"))
        #expect(out.contains("data-sdw-state=\"missing\""))
        #expect(out.contains("Source not found: missing-diagram.mmd"))
        #expect(!out.contains("```mermaid"))
    }

    @Test func embedDiagramSurvivesMarkdownRenderInAllContexts() throws {
        // #736 — the failing case. The embed HTML, after going through
        // `MarkdownHTMLRenderer.render`, must produce a single intact
        // `<pre><code class="language-mermaid">…</code></pre>` whose
        // textContent equals the original diagram source. The previous raw-
        // `<div>` emit broke in: (a) paragraph surrounds, (b) blank line
        // inside the diagram, (c) inside a list, (d) mid-paragraph.
        let id = PageID(rawValue: "01HDIAGRAM000000000000000D")
        let cases: [(String, String, String)] = [
            ("surrounded-by-paragraphs",
             "intro.\n\n![[source:d.mmd]]\n\noutro.",
             "graph TD\n    A --> B\n    B --> C\n"),
            ("blank-line-in-diagram",
             "intro.\n\n![[source:d.mmd]]\n\noutro.",
             "graph TD\n    A --> B\n\n    B --> C\n"),
            ("inside-list",
             "- before\n- ![[source:d.mmd]]\n- after",
             "graph TD\n    A --> B\n    B --> C\n"),
            ("mid-paragraph",
             "text\n![[source:d.mmd]]\nmore text",
             "graph TD\n    A --> B\n    B --> C\n"),
        ]
        for (label, body, diagramSource) in cases {
            let prepared = WikiLinkMarkdown.linkified(
                body,
                isResolved: { _, _ in true },
                embedInfo: { _ in
                    WikiLinkMarkdown.SourceEmbedInfo(
                        id: id, mimeType: "text/mermaid",
                        target: EmbedTarget(
                            kind: .diagram, url: id.rawValue, content: diagramSource)
                    )
                }
            )
            let html = MarkdownHTMLRenderer.render(prepared)
            // The result contains exactly ONE mermaid code element.
            let mermaidCodeCount = html.components(
                separatedBy: "class=\"language-mermaid\"").count - 1
            #expect(mermaidCodeCount == 1,
                    "\(label): expected one `<code class=\"language-mermaid\">`, got \(mermaidCodeCount). HTML:\n\(html)")
            // The diagram source textContent survives ESSENTIALLY un-escaped
            // (no `&amp;gt;` double-escape, no `<p>` wrapping the contents).
            // visitCodeBlock escapes `>` once → `&gt;` — that's correct.
            #expect(html.contains("A --&gt; B"),
                    "\(label): expected `A --&gt; B` (single-escaped) in HTML:\n\(html)")
            #expect(!html.contains("&amp;gt;"),
                    "\(label): found double-escaped `&amp;gt;` in HTML:\n\(html)")
            #expect(!html.contains("<p>graph TD"),
                    "\(label): found `<p>` wrapping the diagram text in HTML:\n\(html)")
            // The fenced path emits a single `<pre>` wrapping the `<code>`.
            #expect(html.contains("<pre><code class=\"language-mermaid\">"),
                    "\(label): missing `<pre><code class=\"language-mermaid\">`. HTML:\n\(html)")
        }
    }

    // MARK: - No regression: media embeds still resolve

    @Test func mediaEmbedsStillRenderViaEmbedHTML() throws {
        // Spot-check that the existing media embed paths (iframe, audio, video)
        // still render through the same `embedHTML` switch now that `.diagram`
        // is a fourth arm. (Existing `WikiLinkMarkdownTests` cover this in
        // depth; this is the #670 non-regression guard.)
        let ytID = PageID(rawValue: "01HTESTYT00000000000000YA")
        let yt = EmbedTarget(kind: .iframe,
            url: "https://www.youtube-nocookie.com/embed/x")
        let audioID = PageID(rawValue: "01HTESTMP300000000000YA")
        let audio = EmbedTarget(kind: .audio, url: "https://x/live.mp3")
        let videoID = PageID(rawValue: "01HTESTMP40000000000YA")
        let video = EmbedTarget(kind: .video, url: "https://x/clip.mp4")

        let ytOut = WikiLinkMarkdown.linkified("![[source:yt]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(
                id: ytID, mimeType: "video/youtube", target: yt) })
        #expect(ytOut.contains("<iframe"))
        #expect(!ytOut.contains("```mermaid"))

        let audioOut = WikiLinkMarkdown.linkified("![[source:stream]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(
                id: audioID, mimeType: "audio/mpeg", target: audio) })
        #expect(audioOut.contains("<audio"))
        #expect(!audioOut.contains("```mermaid"))

        let videoOut = WikiLinkMarkdown.linkified("![[source:clip]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(
                id: videoID, mimeType: "video/mp4", target: video) })
        #expect(videoOut.contains("<video"))
        #expect(!videoOut.contains("```mermaid"))
    }
}
#endif
