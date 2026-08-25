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

    @Test func canonicalAliasedMmdEmbedRendersInlineForCustomMime() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let diagram = """
        flowchart LR
            Input["Input"] --> Process["Process"]
            Process --> Output["Output"]
        """
        let source = try store.addSource(
            filename: "architecture.mmd",
            data: Data(diagram.utf8),
            mimeType: "application/vnd.chipnuts.karaoke-mmd")
        try store.renameSource(id: source.id, to: "Mermaid Architecture")
        model.reloadFromStore()
        let context = WikiRenderContext.build(from: model)
        let markdown = "![[source:\(source.id.rawValue)|Mermaid Architecture]]"
        let prepared = ReaderMarkdown.preparedDocument(markdown)
        let projection = context.documentEmbedResolver().projection(for: prepared)

        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: projection,
            options: .disabled)

        #expect(html.contains("class=\"mermaid sdw-inline-mermaid\""))
        #expect(html.contains("flowchart LR"))
        #expect(!html.contains("sdw-transclusion"))
        #expect(!html.contains("sdw-renderer-card"))
    }

    @Test func canonicalAliasedExcalidrawSourceRendersInlineWithViewerGeometry() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let bytes = Data(##"{"type":"excalidraw","version":2,"elements":[{"id":"box","type":"rectangle","x":40,"y":80,"width":180,"height":90,"angle":0,"strokeColor":"#1e3a8a","backgroundColor":"#dbeafe","strokeWidth":2,"opacity":100,"roundness":{"type":3},"isDeleted":false},{"id":"label","type":"text","x":88,"y":110,"width":84,"height":30,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","strokeWidth":1,"opacity":100,"roundness":null,"isDeleted":false,"text":"Input <trusted>","fontSize":24},{"id":"flow","type":"arrow","x":220,"y":125,"width":80,"height":0,"angle":0,"strokeColor":"#475569","backgroundColor":"transparent","strokeWidth":2,"opacity":100,"roundness":{"type":2},"isDeleted":false,"points":[[0,0],[80,0]],"endArrowhead":"triangle"}],"appState":{"viewBackgroundColor":"#ffffff"}}"##.utf8)
        let source = try store.addSource(
            filename: "architecture.json",
            data: bytes,
            mimeType: "application/json")
        try store.renameSource(id: source.id, to: "Excalidraw Architecture")
        model.reloadFromStore()
        let context = WikiRenderContext.build(from: model)
        let activeVersion = try store.activeContentVersion(sourceID: source.id)
        let pinnedVersion = try #require(activeVersion)
        let projectedSource = try WikiReaderRep.Coordinator.pinnedImageSource(
            sourceID: source.id,
            version: pinnedVersion,
            inputByteCount: { input in try store.rendererInputByteCount(input) },
            readBytes: { versionID in try store.sourceContent(versionID: versionID) })
        let pinnedSource = try #require(projectedSource)
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package = try RendererPackageValidator(
            packageRoot: tempDatabaseURL().deletingLastPathComponent())
            .validate(directory: packageRoot.appending(path: "RendererPackages/Excalidraw"))
        #expect(package.manifest.descriptors.count == 1)
        let descriptor = try #require(package.manifest.descriptors.first)
        let markdown = "![[source:\(source.id.rawValue)|Excalidraw architecture]]"
        let candidates = WikiReaderRep.Coordinator.sourceRendererCandidates(
            markdown: markdown,
            context: context,
            store: store,
            installedDescriptors: [descriptor])
        #expect(candidates[source.id]?.input == .source(pinnedSource))
        let bareCandidates = WikiReaderRep.Coordinator.sourceRendererCandidates(
            markdown: "![[Excalidraw Architecture]]",
            context: context,
            store: store,
            installedDescriptors: [descriptor])
        #expect(bareCandidates[source.id]?.input == .source(pinnedSource))
        let pageID = PageID(rawValue: "01HTESTEXCALIDRAWPAGE000001")
        let pageVersionID = PageVersionID(rawValue: "01HTESTEXCALIDRAWPV0000001")
        let identity = MarkdownDocumentIdentity(pageID: pageID, pageVersionID: pageVersionID)
        let admission = RendererEmbedActivationAdmission(
            pageID: pageID,
            pageVersionID: pageVersionID,
            capability: .init(rawValue: "excalidraw-test-capability"),
            generation: 1)
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: nil,
            documentIdentity: identity,
            rendererActivationAdmission: admission)
        let prepared = ReaderMarkdown.preparedDocument(markdown, documentIdentity: identity)
        let projection = context.documentEmbedResolver(
            sourceRendererCandidates: candidates).projection(for: prepared)
        let body = MarkdownHTMLRenderer.render(
            prepared,
            projection: projection,
            options: options)
        let html = WikiReaderView.documentHTML(body, mermaidLibrary: nil)

        #expect(body.contains("class=\"sdw-inline-renderer sdw-inline-renderer--dom\""))
        #expect(body.contains("class=\"sdw-inline-renderer__svg\""))
        #expect(body.contains("data-renderer-role=\"inlineContent\""))
        #expect(body.contains("viewBox=\"16 56 308 138\""))
        #expect(body.contains("Input &lt;trusted&gt;"))
        #expect(body.contains("Open interactive renderer"))
        #expect(!body.contains("data-renderer-admitted=\"true\""))
        #expect(!body.contains("id=\"sdw-inline-renderer-"))
        #expect(!body.contains("sdw-renderer-card__row"))
        #expect(!body.contains("sdw-renderer-card__disclosure"))
        #expect(html.contains(".sdw-inline-renderer__svg"))
        #expect(html.contains("min-height: 480px"))
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
