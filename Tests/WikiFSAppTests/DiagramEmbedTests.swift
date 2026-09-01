#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Mermaid diagram source embeds (`![[source:diagram.mmd]]`) after the
/// built-in renderer retirement.
///
/// A `.mmd` or `text/mermaid` source is ordinary byteful source data now:
/// it resolves no special embed target, and its inline rendering comes from
/// a matching renderer package through the generic source-renderer arm.
/// With no package installed the embed stays a readable transclusion. The
/// compatibility string bridge must keep embed syntax unchanged.
@MainActor
struct DiagramEmbedTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagram-embed-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    // MARK: - EmbedTarget API surface

    @Test func mediaKindsCarryNoDiagramCase() throws {
        // The media target union is closed: provider iframe, direct-remote
        // audio, direct-remote video. A diagram is renderer-package data.
        let iframe = EmbedTarget(kind: .iframe, url: "https://player/1")
        let audio = EmbedTarget(kind: .audio, url: "https://x/ep.mp3")
        let video = EmbedTarget(kind: .video, url: "https://x/clip.mp4")
        #expect(iframe.kind != audio.kind)
        #expect(audio.kind != video.kind)
        #expect(iframe.kind != video.kind)
    }

    // MARK: - WikiRenderContext resolution

    @Test func renderContextResolvesMmdSourceNamesWithoutASpecialTarget() throws {
        // A `.mmd` source — the byteful case `embedDescriptors()` skips —
        // resolves its embed entries by name/id, but carries no special
        // target: rendering is a renderer-package concern, not a host one.
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let diagram = "flowchart LR\n  A --> B\n  B --> C"
        let src = try store.addSource(
            filename: "Flow.mmd", data: Data(diagram.utf8))
        model.reloadFromStore()

        let ctx = WikiRenderContext.build(from: model)

        // Name resolution still works — resolved by filename (lowercased
        // "flow.mmd"), by ext-stripped ("flow"), and by canonical id.
        let byName = try #require(ctx.embedInfo("flow.mmd"))
        #expect(byName.id == src.id)
        #expect(byName.target == nil)
        let byStripped = try #require(ctx.embedInfo("flow"))
        #expect(byStripped.id == src.id)
        let byID = try #require(ctx.embedInfo(src.id.rawValue.lowercased()))
        #expect(byID.id == src.id)
        // The extension map carries the fallback matcher data.
        #expect(ctx.sourceIDToExtension[src.id] == "mmd")
    }

    @Test func renderContextResolvesTextMermaidMimeSourceWithoutASpecialTarget() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let diagram = "sequenceDiagram\n  Alice->>Bob: Hi"
        _ = try store.addSource(
            filename: "sequence.txt", data: Data(diagram.utf8),
            mimeType: "text/mermaid")
        model.reloadFromStore()

        let ctx = WikiRenderContext.build(from: model)
        let info = try #require(ctx.embedInfo("sequence.txt"))
        #expect(info.target == nil)
        #expect(info.mimeType == "text/mermaid")
    }

    @Test func canonicalAliasedMmdEmbedFallsBackToReadableCodeWithoutAPackage() throws {
        // No package claims the format, so the embed lowers as a readable
        // code fallback / transclusion — the same no-package contract as any
        // other renderer-package format.
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

        // No inline package session mounts, and no host-side mermaid markup
        // exists at all — the reader owns no diagram DOM.
        #expect(!html.contains("sdw-inline-mermaid"))
        #expect(!html.contains("sdw-inline-renderer"))
        #expect(!html.contains("class=\"mermaid\""))
        #expect(!html.contains("sdw-renderer-card"))
    }

    @Test func canonicalAliasedExcalidrawSourceUsesGenericInlineRendererAttachment() throws {
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
            fileExtension: "json",
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
        let html = WikiReaderView.documentHTML(body)

        #expect(body.contains("class=\"sdw-inline-renderer\""))
        #expect(body.contains("data-renderer-role=\"inlineContent\""))
        #expect(body.contains("data-renderer-reference=\"org.selfdrivingwiki.excalidraw-readonly/1.0.5/excalidraw\""))
        #expect(body.contains("data-renderer-admitted=\"true\""))
        #expect(body.contains("class=\"sdw-inline-renderer__fallback\""))
        #expect(body.contains("![[source:"))
        #expect(!body.contains("sdw-inline-renderer--dom"))
        #expect(!body.contains("sdw-inline-renderer__svg"))
        #expect(!body.contains("viewBox="))
        #expect(!body.contains("sdw-renderer-card__row"))
        #expect(!body.contains("sdw-renderer-card__disclosure"))
        #expect(html.contains("data-renderer-role=\"inlineContent\""))
    }

    @Test func renderContextDoesNotResolveSpecialTargetsForTextSources() throws {
        // Any byteful text source — markdown, notes, anything — resolves no
        // special embed target; inline rendering is descriptor-driven.
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        _ = try store.addSource(
            filename: "notes.md", data: Data("# Notes\nHello world".utf8))
        model.reloadFromStore()

        let ctx = WikiRenderContext.build(from: model)
        let info = try #require(ctx.embedInfo("notes.md"))
        #expect(info.target == nil)
    }

    // MARK: - Compatibility bridge

    @Test func compatibilityBridgePreservesDiagramEmbedSyntax() throws {
        let id = SourceID(rawValue: "01HDIAGRAM000000000000000A")
        let authored = "![[source:Flow]]"
        let out = WikiLinkMarkdown.linkified(
            authored,
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(
                    id: id, mimeType: "text/mermaid", target: nil)
            }
        )

        #expect(out == authored)
        #expect(!out.contains("```mermaid"))
        #expect(!out.contains("<div"))
    }

}
#endif
