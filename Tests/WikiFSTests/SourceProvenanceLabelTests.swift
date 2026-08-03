import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore

/// Tests for `SourceProvenanceLabel` — the pure two-dimensional
/// `{provider} / {content type}` combiner used by `SourceDetailView`'s
/// inline origin tag. Issue #644.
///
/// No provider is assumed to imply a content type — the suffix is always
/// derived from the actual file extension / MIME type.
struct SourceProvenanceLabelTests {

    // MARK: - contentTypeLabel

    @Test func contentTypeLabelByExtension() {
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "mmd", mimeType: nil) == "Mermaid")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "mermaid", mimeType: nil) == "Mermaid")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "pdf", mimeType: nil) == "PDF")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "md", mimeType: nil) == "Markdown")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "markdown", mimeType: nil) == "Markdown")
    }

    @Test func contentTypeLabelIsCaseInsensitive() {
        // SourceSummary.ext is documented as lowercased, but the helper should
        // not silently misclassify if a caller forgets.
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "MMD", mimeType: nil) == "Mermaid")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "PDF", mimeType: nil) == "PDF")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "MD", mimeType: nil) == "Markdown")
    }

    @Test func contentTypeLabelFallsBackToMimeWhenExtUnrecognized() {
        // A `.txt` extension is unrecognized, but a text/mermaid MIME still
        // classifies as Mermaid (covers legacy rows whose ext was lost).
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "txt", mimeType: "text/mermaid") == "Mermaid")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "", mimeType: "application/pdf") == "PDF")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: nil, mimeType: "text/markdown") == "Markdown")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "bin", mimeType: "text/x-mermaid") == "Mermaid")
    }

    @Test func contentTypeLabelReturnsNilForUnrecognized() {
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "docx", mimeType: nil) == nil)
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "txt", mimeType: "text/plain") == nil)
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: nil, mimeType: nil) == nil)
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "", mimeType: "application/octet-stream") == nil)
    }

    // MARK: - combine

    @Test func combineFileWithContentType() {
        // The issue #644 design table — File branch.
        #expect(SourceProvenanceLabel.combine(
            provider: "File",
            ext: "mmd", mimeType: "text/mermaid") == "File / Mermaid")
        #expect(SourceProvenanceLabel.combine(
            provider: "File",
            ext: "pdf", mimeType: "application/pdf") == "File / PDF")
        #expect(SourceProvenanceLabel.combine(
            provider: "File",
            ext: "md", mimeType: "text/markdown") == "File / Markdown")
    }

    @Test func combineZoteroWithContentType() {
        // The issue #644 design table — Zotero branch.
        #expect(SourceProvenanceLabel.combine(
            provider: "Zotero",
            ext: "pdf", mimeType: "application/pdf") == "Zotero / PDF")
        #expect(SourceProvenanceLabel.combine(
            provider: "Zotero",
            ext: "md", mimeType: "text/markdown") == "Zotero / Markdown")
        #expect(SourceProvenanceLabel.combine(
            provider: "Zotero",
            ext: "mmd", mimeType: "text/mermaid") == "Zotero / Mermaid")
    }

    @Test func combineFolderWithContentType() {
        // A markdown-folder import is stored as markdown, so the chip reads
        // "Folder / Markdown" — the content type is never assumed.
        #expect(SourceProvenanceLabel.combine(
            provider: "Folder",
            ext: "md", mimeType: "text/markdown") == "Folder / Markdown")
        // If a folder somehow contained a PDF, it would read "Folder / PDF".
        #expect(SourceProvenanceLabel.combine(
            provider: "Folder",
            ext: "pdf", mimeType: "application/pdf") == "Folder / PDF")
    }

    @Test func combineWebsiteWithContentType() {
        // No provider implies a content type — a website source stored as
        // markdown reads "Website / Markdown".
        #expect(SourceProvenanceLabel.combine(
            provider: "Website",
            ext: "md", mimeType: "text/markdown") == "Website / Markdown")
        #expect(SourceProvenanceLabel.combine(
            provider: "Website",
            ext: "pdf", mimeType: "application/pdf") == "Website / PDF")
    }

    @Test func combineOmitsSuffixWhenContentTypeUnknown() {
        // Unknown content type — collapse to just the provider label so the
        // tag never reads "File / " or "Zotero / ".
        #expect(SourceProvenanceLabel.combine(
            provider: "File",
            ext: "docx", mimeType: nil) == "File")
        #expect(SourceProvenanceLabel.combine(
            provider: "Zotero",
            ext: "", mimeType: "application/octet-stream") == "Zotero")
        // A YouTube source with no derivable ext/MIME reads just "YouTube".
        #expect(SourceProvenanceLabel.combine(
            provider: "YouTube",
            ext: nil, mimeType: nil) == "YouTube")
    }

    @Test func combineWorksWithUnexpectedProviderFallback() {
        // The view's default case (anything not explicitly switched on) falls
        // through to "File" with whatever agentName was observed. An unknown
        // agent still keeps the suffix, since we can't assume what it carries.
        #expect(SourceProvenanceLabel.combine(
            provider: "File",
            ext: "pdf", mimeType: nil) == "File / PDF")
    }
}
