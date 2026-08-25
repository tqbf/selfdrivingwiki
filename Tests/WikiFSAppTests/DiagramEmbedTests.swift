#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Issue #670 — Mermaid diagram source embeds (`![[source:diagram.mmd]]`).
///
/// A `.mmd` or `text/mermaid` source resolves to exact Mermaid source facts.
/// The typed document resolver lowers these facts as inline content. The
/// compatibility string bridge must keep embed syntax unchanged.
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

    // MARK: - Compatibility bridge

    @Test func compatibilityBridgePreservesDiagramEmbedSyntax() throws {
        let id = SourceID(rawValue: "01HDIAGRAM000000000000000A")
        let target = EmbedTarget(
            kind: .diagram, url: id.rawValue,
            content: "flowchart LR\n  A --> B")
        let authored = "![[source:Flow]]"
        let out = WikiLinkMarkdown.linkified(
            authored,
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(
                    id: id, mimeType: "text/mermaid", target: target)
            }
        )

        #expect(out == authored)
        #expect(!out.contains("```mermaid"))
        #expect(!out.contains("<div"))
    }

}
#endif
