import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore

/// Tests for `MermaidSourceDetector` — the pure gate that decides whether a
/// source exposes the Source / Rendered / Split Mermaid tabs in
/// `SourceDetailView`, plus the renderable-markdown wrapping it feeds the
/// reader. Also covers `MimeType.isMermaid`.
struct MermaidSourceDetectorTests {

    // MARK: - MimeType.isMermaid

    @Test func mimeTypeIsMermaidRecognizesVariants() {
        #expect(MimeType.isMermaid("text/mermaid"))
        #expect(MimeType.isMermaid("text/x-mermaid"))
        // Case-insensitive (RFC 2045).
        #expect(MimeType.isMermaid("TEXT/Mermaid"))
        #expect(!MimeType.isMermaid("text/markdown"))
        #expect(!MimeType.isMermaid("text/plain"))
        #expect(!MimeType.isMermaid(nil))
    }

    // MARK: - isMermaidSource: MIME

    @Test func detectsByMime() {
        #expect(MermaidSourceDetector.isMermaidSource(
            mimeType: "text/mermaid", filename: "diagram", content: nil))
        #expect(MermaidSourceDetector.isMermaidSource(
            mimeType: "text/x-mermaid", filename: nil, content: nil))
        #expect(MermaidSourceDetector.isMermaidSource(
            mimeType: "TEXT/MERMAID", filename: nil, content: nil))
    }

    // MARK: - isMermaidSource: extension

    @Test func detectsByMmdExtension() {
        #expect(MermaidSourceDetector.isMermaidSource(
            mimeType: nil, filename: "flow.mmd", content: nil))
        // Case-insensitive extension.
        #expect(MermaidSourceDetector.isMermaidSource(
            mimeType: nil, filename: "Flow.MMD", content: nil))
        // A bare "mmd" (no dot) also counts.
        #expect(MermaidSourceDetector.isMermaidSource(
            mimeType: nil, filename: "mmd", content: nil))
    }

    @Test func doesNotFalsePositiveOnSimilarExtensions() {
        #expect(!MermaidSourceDetector.isMermaidSource(
            mimeType: nil, filename: "notes.md", content: nil))
        #expect(!MermaidSourceDetector.isMermaidSource(
            mimeType: nil, filename: "data.mmdx", content: nil))
        // ".mmd" must be the terminal extension, not a substring.
        #expect(!MermaidSourceDetector.isMermaidSource(
            mimeType: nil, filename: "readme.mmetadata", content: nil))
    }

    // MARK: - isMermaidSource: fenced content

    @Test func detectsFencedMermaidBlockInMarkdown() {
        let md = """
        # Architecture

        ```mermaid
        flowchart TD
            A --> B
        ```

        Done.
        """
        #expect(MermaidSourceDetector.isMermaidSource(
            mimeType: "text/markdown", filename: "arch.md", content: md))
    }

    @Test func detectsTildeFence() {
        let md = "~~~mermaid\ngraph TD\n  A --> B\n~~~\n"
        #expect(MermaidSourceDetector.isMermaidSource(
            mimeType: "text/plain", filename: "g.txt", content: md))
    }

    @Test func doesNotMatchMermaidMentionedAsProse() {
        // The word "mermaid" in prose (no fence) is not a diagram.
        let md = "We use mermaid diagrams elsewhere.\nflowchart TD"
        #expect(!MermaidSourceDetector.isMermaidSource(
            mimeType: "text/markdown", filename: "notes.md", content: md))
    }

    @Test func emptyContentIsNotMermaidUnlessMimeOrExt() {
        #expect(!MermaidSourceDetector.isMermaidSource(
            mimeType: nil, filename: "blank.txt", content: ""))
        #expect(!MermaidSourceDetector.isMermaidSource(
            mimeType: nil, filename: "blank.txt", content: nil))
        // But a .mmd with empty content still counts (it's a mermaid file).
        #expect(MermaidSourceDetector.isMermaidSource(
            mimeType: nil, filename: "blank.mmd", content: ""))
    }

    // MARK: - renderableMarkdown

    @Test func wrapsStandaloneSourceInFence() {
        let raw = "flowchart TD\n    A --> B\n    B --> C"
        let rendered = MermaidSourceDetector.renderableMarkdown(from: raw)
        #expect(rendered == "```mermaid\nflowchart TD\n    A --> B\n    B --> C\n```")
    }

    @Test func wrapsStandaloneSourcePreservingTrailingNewlineTrim() {
        let raw = "graph LR\n  X --> Y\n\n\n"
        let rendered = MermaidSourceDetector.renderableMarkdown(from: raw)
        // Trailing blank lines are trimmed before wrapping.
        #expect(rendered == "```mermaid\ngraph LR\n  X --> Y\n```")
    }

    @Test func passesThroughEmbeddedMermaidUnchanged() {
        // Content that already carries a fenced mermaid block is returned as-is
        // so surrounding prose/headings (and the outline) stay intact.
        let md = """
        # Design

        ```mermaid
        sequenceDiagram
            A->>B: hi
        ```

        Notes.
        """
        #expect(MermaidSourceDetector.renderableMarkdown(from: md) == md)
    }

    @Test func renderableMarkdownNilForEmptyOrWhitespace() {
        #expect(MermaidSourceDetector.renderableMarkdown(from: "") == nil)
        #expect(MermaidSourceDetector.renderableMarkdown(from: "   \n\t ") == nil)
    }

    @Test func renderableMarkdownWrapsContentWithoutFenceEvenIfLooksLikeProse() {
        // A standalone `.mmd` whose body happens to contain the word "mermaid"
        // but no fence is still wrapped (the source is the diagram definition).
        let raw = "%% this is a mermaid diagram\nflowchart TD\n  A --> B"
        let rendered = MermaidSourceDetector.renderableMarkdown(from: raw)
        #expect(rendered == "```mermaid\n%% this is a mermaid diagram\nflowchart TD\n  A --> B\n```")
    }

    // MARK: - codeBlockMarkdown (Reader tab for diagram sources, issue #662)

    @Test func codeBlockMarkdownWrapsStandaloneSourceInPlainFence() {
        // No language tag — the reader renders the body as `<pre><code>` (plain
        // monospace), so the Mermaid library does NOT kick in (that's the point:
        // show the DSL as code, not render the diagram).
        let raw = "flowchart TD\n    A --> B\n    B --> C"
        let codeBlock = MermaidSourceDetector.codeBlockMarkdown(from: raw)
        #expect(codeBlock == "````\nflowchart TD\n    A --> B\n    B --> C\n````")
    }

    @Test func codeBlockMarkdownTrimsTrailingBlankLines() {
        let raw = "graph LR\n  X --> Y\n\n\n"
        let codeBlock = MermaidSourceDetector.codeBlockMarkdown(from: raw)
        #expect(codeBlock == "````\ngraph LR\n  X --> Y\n````")
    }

    @Test func codeBlockMarkdownNilForEmptyOrWhitespace() {
        #expect(MermaidSourceDetector.codeBlockMarkdown(from: "") == nil)
        #expect(MermaidSourceDetector.codeBlockMarkdown(from: "   \n\t ") == nil)
    }

    @Test func codeBlockMarkdownSurvivesInnerThreeBacktickRuns() {
        // A 4-backtick outer fence stays open even if the content contains a
        // 3-backtick run (rare in `.mmd`/JSON, but possible). The wrapper must
        // not terminate early — the inner ``` becomes content of the block.
        let raw = "comment\n```\nflowchart TD\n  A --> B\n```"
        let codeBlock = MermaidSourceDetector.codeBlockMarkdown(from: raw)
        #expect(codeBlock == "````\ncomment\n```\nflowchart TD\n  A --> B\n```\n````")
    }

    @Test func codeBlockMarkdownPreservesJSONVerbatim() {
        // Excalidraw/Obsidian Canvas are JSON — string content round-trips
        // unchanged (no escaping needed for the markdown pipeline; the renderer
        // escapes `<`/`>`/`&` inside code blocks).
        let raw = "{\"type\":\"excalidraw\",\"version\":2}"
        let codeBlock = MermaidSourceDetector.codeBlockMarkdown(from: raw)
        #expect(codeBlock == "````\n{\"type\":\"excalidraw\",\"version\":2}\n````")
    }

    @Test func codeBlockMarkdownDiffersFromRenderableMarkdown() {
        // The two siblings produce DIFFERENT markdown for the same `.mmd`
        // source: `renderableMarkdown` wraps in a ` ```mermaid ` fence (so the
        // reader renders the diagram), `codeBlockMarkdown` wraps in a plain
        // fence (so the reader shows the source as code). This is the load-
        // bearing distinction that powers Reader-as-code-view vs Rendered-as-
        // diagram in `SourceDetailView.tabbedContent`.
        let raw = "flowchart TD\n  A --> B"
        let rendered = MermaidSourceDetector.renderableMarkdown(from: raw)
        let codeBlock = MermaidSourceDetector.codeBlockMarkdown(from: raw)
        #expect(rendered != codeBlock)
        #expect(rendered?.hasPrefix("```mermaid") == true)
        #expect(codeBlock?.hasPrefix("````\n") == true)
    }
}
