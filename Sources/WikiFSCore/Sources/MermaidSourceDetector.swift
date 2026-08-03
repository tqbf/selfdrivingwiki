import Foundation

/// Pure detection of whether a source should expose the Mermaid diagram tabs
/// (Source / Rendered / Split) in `SourceDetailView`.
///
/// A source is a "Mermaid source" when any of these hold:
/// - its MIME type is a recognized Mermaid variant (`text/mermaid`,
///   `text/x-mermaid`),
/// - its filename ends in `.mmd`, or
/// - its content contains at least one fenced ` ```mermaid ` block.
///
/// The fence scan reuses `MermaidValidator.mermaidBlocks(in:)` (a pure line
/// scanner with no JS dependency), so this stays cheap and side-effect-free.
/// Pure + unit-tested; the view threads in the resolved mime/filename/content.
public enum MermaidSourceDetector {

    /// `.mmd` — the conventional standalone Mermaid source extension.
    public static let mermaidExtension = "mmd"

    /// Whether `(mimeType, filename, content)` describes a Mermaid source.
    ///
    /// `content` may be `nil` when the source bytes haven't loaded yet — the
    /// mime/extension checks still run, so a `.mmd` file shows its diagram tabs
    /// before the text arrives.
    public static func isMermaidSource(
        mimeType: String?,
        filename: String?,
        content: String?
    ) -> Bool {
        if MimeType.isMermaid(mimeType) { return true }
        if let filename {
            let lower = filename.lowercased()
            if lower.hasSuffix(".\(mermaidExtension)") || lower == mermaidExtension {
                return true
            }
        }
        if let content, !MermaidValidator.mermaidBlocks(in: content).isEmpty {
            return true
        }
        return false
    }

    /// The mermaid source the "Rendered" tab should draw: when `content` is a
    /// standalone `.mmd` file (no fenced block), wrap the raw text in a
    /// ` ```mermaid ` fence so the reader's render pipeline picks it up; when the
    /// content already carries fenced mermaid blocks (an embedded markdown doc),
    /// pass it through unchanged so headings/outline still apply.
    ///
    /// Returns `nil` only when `content` is empty/whitespace (nothing to render).
    public static func renderableMarkdown(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Already has a fenced mermaid block → render the document as-is so any
        // surrounding prose/headings stay intact (and the outline is meaningful).
        if !MermaidValidator.mermaidBlocks(in: content).isEmpty { return content }
        // Standalone source (`.mmd` or `text/mermaid`): wrap once in a fence so
        // the reader converts it to `<pre><code class="language-mermaid">` and
        // inlines the Mermaid library + bootstrap.
        return "```mermaid\n\(trimmed)\n```"
    }

    /// The Reader-tab markdown for a STANDALONE diagram source (`.mmd` /
    /// `text/mermaid`; future: `.excalidraw` / `.canvas`): the raw source text
    /// wrapped in a plain (no-language) CommonMark code fence so the reader
    /// renders `<pre><code>` — monospace, newlines preserved, no markdown
    /// parsing of the body. Diagram DSLs confuse the markdown pipeline (mermaid
    /// `flowchart LR` parsed as prose, `.excalidraw` JSON as flat text), so the
    /// Reader tab shows them as the code they are while the Rendered tab still
    /// renders the diagram (issue #662).
    ///
    /// Uses a 4-backtick fence so any 3-backtick sequences inside the content
    /// (rare in mermaid DSL or JSON, but possible) don't terminate the wrapper
    /// early. Returns `nil` only when `content` is empty/whitespace (nothing to
    /// show). Sibling of `renderableMarkdown(from:)`: that one wraps to RENDER
    /// a diagram; this one wraps to DISPLAY source code.
    public static func codeBlockMarkdown(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "````\n\(trimmed)\n````"
    }
}
