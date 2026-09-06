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
/// JSON Canvas (still a native built-in). Mermaid MIME knowledge is
/// package-owned; without an active claim the format falls back generically.
struct SourceTextPresentationTests {

    // MARK: - Renderer-owned extensions have no host MIME fallback

    @Test func mmdExtensionHasNoHostMIMEFallback() {
        // Mermaid MIME policy moved into the reviewed package manifest. The
        // host table keeps only project-owned formats (JSON Canvas metadata).
        #expect(MimeType.mime(forExtension: "mmd") == nil)
        #expect(MimeType.mime(forExtension: "mermaid") == nil)
        #expect(MimeType.mime(forExtension: "canvas") == MimeType.json)
        #expect(MimeType.mime(forExtension: "zzz") == nil)
    }

    // MARK: - The neutral code-block wrap (planner.sourceMarkdown)

    @Test func sourceMarkdownWrapsNonMarkdownTextInAPlainFourBacktickFence() {
        // No language tag: the Source tab shows the bytes as code — whatever
        // renderer package may claim the format.
        let raw = "flowchart TD\n    A --> B\n    B --> C"
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: "text/mermaid")
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: raw)
                == "````\nflowchart TD\n    A --> B\n    B --> C\n````")
    }

    @Test func sourceMarkdownTrimsTrailingBlankLinesBeforeWrapping() {
        let raw = "graph LR\n  X --> Y\n\n\n"
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: "text/mermaid")
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
        let source = fixtureSource(filename: "blank.mmd", ext: "mmd", mimeType: "text/mermaid")
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: "") == "")
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: "   \n\t ") == "   \n\t ")
    }

    @Test func sourceMarkdownSurvivesInnerThreeBacktickRuns() {
        // A 4-backtick outer fence stays open even if the content contains a
        // 3-backtick run; the inner fence is content, not a terminator.
        let raw = "comment\n```\nflowchart TD\n  A --> B\n```"
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: "text/mermaid")
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: raw)
                == "````\ncomment\n```\nflowchart TD\n  A --> B\n```\n````")
    }

    @Test func sourceMarkdownWrapsJSONVerbatim() {
        let raw = "{\"type\":\"excalidraw\",\"version\":2}"
        let source = fixtureSource(filename: "drawing.excalidraw", ext: "excalidraw", mimeType: "application/json")
        #expect(SourceRendererPresentationPlanner.sourceMarkdown(for: source, content: raw)
                == "````\n{\"type\":\"excalidraw\",\"version\":2}\n````")
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
            mimeType: "text/mermaid", ext: "mmd", hasMarkdown: false))
        // Other package text formats: same derivation.
        #expect(!SourceDetailView.outlineApplicablePresentation(
            mimeType: "application/json", ext: "excalidraw", hasMarkdown: false))
        #expect(!SourceDetailView.outlineApplicablePresentation(
            mimeType: "application/json", ext: "canvas", hasMarkdown: false))
    }

    // MARK: - Text presentability is unchanged (byte-authoritative)

    @Test func mmdSourceStaysTextPresentable() {
        // A `.mmd` source still qualifies for the readable Source tab: its
        // bytes are UTF-8 text, so the generic fallback keeps the code-block
        // presentation reachable even without an active package claim.
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: "text/mermaid")
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
