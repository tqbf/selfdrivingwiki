import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore

/// Tests for `SourceProvenanceLabel` — the pure two-dimensional
/// `{provider} / {content type}` combiner used by `SourceDetailView`'s
/// inline origin tag. Issue #644.
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

    // MARK: - providerImpliesContentType

    @Test func urlProvidersImplyContentType() {
        // URL-based media/web providers — the suffix is redundant.
        let implied = ["website", "markdown-folder", "apple-podcast",
                       "youtube", "vimeo", "spotify", "soundcloud", "remote-media"]
        for agent in implied {
            #expect(SourceProvenanceLabel.providerImpliesContentType(agent),
                    "Expected \(agent) to imply its content type")
        }
    }

    @Test func fileAndZoteroDoNotImplyContentType() {
        // File / Zotero imports can carry anything — the suffix is meaningful.
        #expect(!SourceProvenanceLabel.providerImpliesContentType("local-file"))
        #expect(!SourceProvenanceLabel.providerImpliesContentType("zotero"))
        #expect(!SourceProvenanceLabel.providerImpliesContentType("legacy-import"))
        #expect(!SourceProvenanceLabel.providerImpliesContentType(""))
    }

    // MARK: - combine

    @Test func combineFileWithContentType() {
        // The issue #644 design table — File branch.
        #expect(SourceProvenanceLabel.combine(
            provider: "File", agentName: "local-file",
            ext: "mmd", mimeType: "text/mermaid") == "File / Mermaid")
        #expect(SourceProvenanceLabel.combine(
            provider: "File", agentName: "local-file",
            ext: "pdf", mimeType: "application/pdf") == "File / PDF")
        #expect(SourceProvenanceLabel.combine(
            provider: "File", agentName: "local-file",
            ext: "md", mimeType: "text/markdown") == "File / Markdown")
    }

    @Test func combineZoteroWithContentType() {
        // The issue #644 design table — Zotero branch.
        #expect(SourceProvenanceLabel.combine(
            provider: "Zotero", agentName: "zotero",
            ext: "pdf", mimeType: "application/pdf") == "Zotero / PDF")
        #expect(SourceProvenanceLabel.combine(
            provider: "Zotero", agentName: "zotero",
            ext: "md", mimeType: "text/markdown") == "Zotero / Markdown")
        #expect(SourceProvenanceLabel.combine(
            provider: "Zotero", agentName: "zotero",
            ext: "mmd", mimeType: "text/mermaid") == "Zotero / Mermaid")
    }

    @Test func combineOmitsSuffixWhenContentTypeUnknown() {
        // Unknown content type — collapse to just the provider label so the
        // tag never reads "File / " or "Zotero / ".
        #expect(SourceProvenanceLabel.combine(
            provider: "File", agentName: "local-file",
            ext: "docx", mimeType: nil) == "File")
        #expect(SourceProvenanceLabel.combine(
            provider: "Zotero", agentName: "zotero",
            ext: "", mimeType: "application/octet-stream") == "Zotero")
    }

    @Test func combineOmitsSuffixWhenProviderImpliesContentType() {
        // URL-based providers — the suffix would be redundant. Even when a
        // content type COULD be derived (e.g. a YouTube source somehow has a
        // .mp4 ext), the provider label already tells the user what it is.
        #expect(SourceProvenanceLabel.combine(
            provider: "YouTube", agentName: "youtube",
            ext: "mp4", mimeType: "video/mp4") == "YouTube")
        #expect(SourceProvenanceLabel.combine(
            provider: "Website", agentName: "website",
            ext: "html", mimeType: "text/html") == "Website")
        #expect(SourceProvenanceLabel.combine(
            provider: "Apple Podcast", agentName: "apple-podcast",
            ext: "mp3", mimeType: "audio/mpeg") == "Apple Podcast")
        #expect(SourceProvenanceLabel.combine(
            provider: "Folder", agentName: "markdown-folder",
            ext: "md", mimeType: "text/markdown") == "Folder")
    }

    @Test func combineWorksWithUnexpectedProviderFallback() {
        // The view's default case (anything not explicitly switched on) falls
        // through to "File" with whatever agentName was observed. An unknown
        // agent that ISN'T in the implies list still keeps the suffix, since
        // we can't assume what it carries.
        #expect(SourceProvenanceLabel.combine(
            provider: "File", agentName: "future-provider",
            ext: "pdf", mimeType: nil) == "File / PDF")
    }
}
