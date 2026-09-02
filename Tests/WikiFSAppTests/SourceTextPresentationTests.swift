#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore
import WikiFSTypes

/// Source-detail presentation after the built-in Mermaid renderer
/// retirement: non-Markdown text sources (including `.mmd`) render as
/// neutral code blocks, the outline derives from the rendered-document
/// presentation, and the only reader-projected diagram tab left belongs to
/// JSON Canvas (still a native built-in). Ingestion metadata
/// (`MimeType.isMermaid`, the `.mmd` MIME fallback) stays covered here too.
struct SourceTextPresentationTests {

    // MARK: - MimeType.isMermaid (ingestion data; unchanged)

    @Test func mimeTypeIsMermaidRecognizesVariants() {
        #expect(MimeType.isMermaid("text/mermaid"))
        #expect(MimeType.isMermaid("text/x-mermaid"))
        // Case-insensitive (RFC 2045).
        #expect(MimeType.isMermaid("TEXT/Mermaid"))
        #expect(!MimeType.isMermaid("text/markdown"))
        #expect(!MimeType.isMermaid("text/plain"))
        #expect(!MimeType.isMermaid(nil))
    }

    @Test func mmdExtensionStillResolvesAMIMEFallback() {
        // The ingestion chain keeps classifying `.mmd` as `text/mermaid`
        // (issue #620) — this is content-type metadata, not renderer policy.
        #expect(MimeType.mime(forExtension: "mmd") == MimeType.mermaid)
        #expect(MimeType.mime(forExtension: "mermaid") == MimeType.mermaid)
        #expect(MimeType.mime(forExtension: "canvas") == MimeType.json)
        #expect(MimeType.mime(forExtension: "zzz") == nil)
    }

    // MARK: - The neutral code-block wrap (planner.sourceMarkdown)

    @Test func sourceMarkdownWrapsNonMarkdownTextInAPlainFourBacktickFence() {
        // No language tag: the Source tab shows the bytes as code — whatever
        // renderer package may claim the format.
        let raw = "flowchart TD\n    A --> B\n    B --> C"
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: MimeType.mermaid)
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: raw)
                == "````\nflowchart TD\n    A --> B\n    B --> C\n````")
    }

    @Test func sourceMarkdownTrimsTrailingBlankLinesBeforeWrapping() {
        let raw = "graph LR\n  X --> Y\n\n\n"
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: MimeType.mermaid)
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: raw)
                == "````\ngraph LR\n  X --> Y\n````")
    }

    @Test func sourceMarkdownKeepsNativeMarkdownUnchanged() {
        // A native Markdown document stays a rendered document — headings and
        // all — with no wrap.
        let md = "# Design\n\n```mermaid\nflowchart TD\n  A --> B\n```\n"
        let source = fixtureSource(filename: "notes.md", ext: "md", mimeType: MimeType.markdown)
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: md) == md)
    }

    @Test func sourceMarkdownKeepsEmptyContentUnchanged() {
        let source = fixtureSource(filename: "blank.mmd", ext: "mmd", mimeType: MimeType.mermaid)
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: "") == "")
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: "   \n\t ") == "   \n\t ")
    }

    @Test func sourceMarkdownSurvivesInnerThreeBacktickRuns() {
        // A 4-backtick outer fence stays open even if the content contains a
        // 3-backtick run; the inner fence is content, not a terminator.
        let raw = "comment\n```\nflowchart TD\n  A --> B\n```"
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: MimeType.mermaid)
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: raw)
                == "````\ncomment\n```\nflowchart TD\n  A --> B\n```\n````")
    }

    @Test func sourceMarkdownWrapsJSONVerbatim() {
        let raw = "{\"type\":\"excalidraw\",\"version\":2}"
        let source = fixtureSource(filename: "drawing.excalidraw", ext: "excalidraw", mimeType: "application/json")
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: raw)
                == "````\n{\"type\":\"excalidraw\",\"version\":2}\n````")
    }

    // MARK: - Reader-projected diagram tabs (characterization)

    @Test func mmdSourceGainsNoReaderProjectedTab() {
        // The old built-in's `[.reader, .rendered]` projection is gone: a
        // `.mmd` source presents like any other renderer-package text source.
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: nil)
        let bytes = Data("flowchart TD\n    A --> B".utf8)
        let result = SourceDetailPresentationCharacterization.characterize(
            source: source,
            boundedBytes: bytes,
            currentMarkdown: nil,
            hasProcessedMarkdown: false,
            origin: nil)
        #expect(result.tabs == [])
    }

    @Test func markdownDocumentWithAFencedDiagramKeepsItsReaderTab() {
        // A markdown document with an embedded fence is a normal native
        // Markdown source: the markdown content area renders it (fences
        // become claimed disclosure rows there). The redundant
        // reader-projected "Rendered" tab is gone — the accepted
        // simplification; the Reader already renders the same document.
        let source = fixtureSource(filename: "arch.md", ext: "md", mimeType: MimeType.markdown)
        let bytes = Data("# Architecture\n\n```mermaid\nflowchart TD\n  A --> B\n```\n".utf8)
        let result = SourceDetailPresentationCharacterization.characterize(
            source: source,
            boundedBytes: bytes,
            currentMarkdown: "# Architecture",
            hasProcessedMarkdown: true,
            origin: nil)
        #expect(result.contentArea == .markdown)
        #expect(result.tabs == [])
        #expect(!result.tabs.contains(.rendered))
        // The document itself stays a rendered Markdown document.
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(
            for: source, content: String(decoding: bytes, as: UTF8.self)).hasPrefix("# Architecture"))
    }

    @Test func canvasSourceKeepsItsReaderProjectedPresentation() {
        // JSON Canvas is still a native built-in renderer: it keeps the
        // reader-projected tab.
        let source = fixtureSource(filename: "board.canvas", ext: "canvas", mimeType: "application/json")
        let bytes = Data("{\"nodes\":[],\"edges\":[]}".utf8)
        let result = SourceDetailPresentationCharacterization.characterize(
            source: source,
            boundedBytes: bytes,
            currentMarkdown: nil,
            hasProcessedMarkdown: false,
            origin: nil)
        #expect(result.tabs == [.reader, .rendered])
    }

    // MARK: - The outline derivation (no host format branch)

    @Test func outlineAppliesOnlyToRenderedMarkdownDocuments() {
        // The outline parses markdown headings, so it is meaningful only when
        // the Source tab shows a rendered Markdown document. A `.mmd` source
        // renders as a code block — no outline — without any host-side format
        // branch. Tested through the same static derivation the view uses.
        #expect(SourceDetailView.outlineApplicablePresentation(
            mimeType: MimeType.markdown, ext: "md", hasMarkdown: false))
        #expect(SourceDetailView.outlineApplicablePresentation(
            mimeType: nil, ext: "pdf", hasMarkdown: true))
        // A .mmd source: text-presentable, but not a Markdown document and
        // no extraction head — no outline.
        #expect(!SourceDetailView.outlineApplicablePresentation(
            mimeType: MimeType.mermaid, ext: "mmd", hasMarkdown: false))
        // Other package text formats: same derivation.
        #expect(!SourceDetailView.outlineApplicablePresentation(
            mimeType: "application/json", ext: "excalidraw", hasMarkdown: false))
        #expect(!SourceDetailView.outlineApplicablePresentation(
            mimeType: "application/json", ext: "canvas", hasMarkdown: false))
    }

    // MARK: - Text presentability is unchanged (byte-authoritative)

    @Test func mmdSourceStaysTextPresentable() {
        // A `.mmd` source still qualifies for the readable Source tab: its
        // MIME is text-presentable and its bytes are UTF-8. This is what
        // keeps the code-block presentation reachable at all.
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: MimeType.mermaid)
        let bytes = Data("flowchart TD\n    A --> B".utf8)
        #expect(MimeType.isSourceTextPresentable(source.mimeType))
        #expect(SourceRendererPresentationPlanner.usesMarkdownSourcePresentation(
            for: source,
            boundedBytes: bytes,
            currentMarkdown: nil))
    }

    // MARK: - Fixtures

    private func fixtureSource(
        filename: String,
        ext: String,
        mimeType: String?
    ) -> SourceSummary {
        SourceSummary(
            id: SourceID(rawValue: "01JSOURCETEXTFIXTURE000001"),
            filename: filename,
            ext: ext,
            mimeType: mimeType,
            byteSize: 24,
            createdAt: .distantPast,
            updatedAt: .distantPast,
            version: 1)
    }
}
#endif
