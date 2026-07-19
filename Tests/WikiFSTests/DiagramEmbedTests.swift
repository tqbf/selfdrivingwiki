import Foundation
import Testing
@testable import WikiFSCore

/// Issue #670 — Mermaid diagram source embeds (`![[source:diagram.mmd]]`).
///
/// A `.mmd` source (or any `text/mermaid` source) embedded in a page renders
/// inline as a `<div class='mermaid'>…</div>` element, picked up by the
/// bundled `mermaid.min.js` (v11) and rendered as an inline SVG — no per-embed
/// JS. The diagram source text travels through the embed target itself
/// (`EmbedTarget.content`) so the renderer stays pure / store-free.
///
/// Three layers tested here:
///   1. `EmbedTarget.Kind.diagram` + the `content` field (#670 §1).
///   2. `WikiRenderContext` resolves a `.mmd` source to a `.diagram` target
///      carrying the source text (#670 §2) — the same text the source-detail
///      Reader tab would show.
///   3. `WikiLinkMarkdown.embedHTML` emits the mermaid div with HTML-escaped
///      content so the page parser can't break on `<`/`>`/`&` inside the
///      diagram source (#670 §3).
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
        // a `<div class='mermaid'>…</div>` against text we can't read. Falls
        // back to nil (the renderer emits a cite link).
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

    // MARK: - embedHTML emits the mermaid div (#670 §3)

    @Test func embedDiagramTargetRendersMermaidDiv() throws {
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
        // The mermaid div with the diagram text — the bundled mermaid.min.js
        // (v11) scans the document for `.mermaid` divs and reads
        // `div.textContent` (which un-escapes `&gt;` back to `>`) before
        // rendering, mirroring the reader's ` ```mermaid ` code-block path
        // (`WikiReaderView.mermaidBootstrapJS`).
        #expect(out.contains("<div class=\"mermaid\">"))
        #expect(out.contains("flowchart LR"))
        // The `-->` arrow is HTML-escaped to `--&gt;` so the parser stays
        // safe; `div.textContent` (read by mermaid) un-escapes it back.
        #expect(out.contains("A --&gt; B"))
        #expect(out.contains("</div>"))
        // The diagram is NOT a wiki-blob (no bytes fetched) and NOT a cite link.
        #expect(!out.contains("wiki-blob://"))
        #expect(!out.contains("wiki://source"))
    }

    @Test func embedDiagramHTMLEscapesAngleBracketsAndAmpersand() throws {
        // The HTML parser would otherwise treat `<`/`>`/`&` in the diagram text
        // as markup. We escape them so the DOM survives intact; the mermaid
        // library reads `div.textContent`, which un-escapes back to the raw
        // diagram source — verified by the reader's existing bootstrap
        // (`WikiReaderView.mermaidBootstrapJS` does the same with
        // `code.textContent` for ` ```mermaid ` code blocks).
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
        // The dangerous chars are HTML-escaped inside the div.
        #expect(out.contains("&lt;"))
        #expect(out.contains("&gt;"))
        #expect(out.contains("&amp;"))
        // The escaped forms do NOT leak the raw bracket chars as bare markup —
        // the div opens and closes around the escaped text.
        #expect(out.contains("<div class=\"mermaid\">"))
        #expect(out.contains("</div>"))
    }

    @Test func embedDiagramWithoutTargetFallsBackToCiteLink() throws {
        // A `.mmd` source name the embedInfo resolver returns nil for → the
        // renderer falls back to the cite-link path (no half-rendered div).
        let out = WikiLinkMarkdown.linkified(
            "![[source:missing-diagram.mmd]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in nil }
        )
        #expect(out.contains("wiki://source"))
        #expect(!out.contains("<div class=\"mermaid\">"))
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
        #expect(!ytOut.contains("<div class=\"mermaid\">"))

        let audioOut = WikiLinkMarkdown.linkified("![[source:stream]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(
                id: audioID, mimeType: "audio/mpeg", target: audio) })
        #expect(audioOut.contains("<audio"))
        #expect(!audioOut.contains("<div class=\"mermaid\">"))

        let videoOut = WikiLinkMarkdown.linkified("![[source:clip]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(
                id: videoID, mimeType: "video/mp4", target: video) })
        #expect(videoOut.contains("<video"))
        #expect(!videoOut.contains("<div class=\"mermaid\">"))
    }
}
