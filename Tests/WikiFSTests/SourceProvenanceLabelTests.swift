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

    /// A fictional stand-in for the reviewed Mermaid claim: package-owned
    /// source metadata, not host policy.
    private let mermaidLikeCatalog: RegisteredRendererSourceTypes = {
        let canonical = try! RendererMIMEType(validating: "text/vnd.example-diagram")
        let aliases = try! Set(["text/mermaid", "text/x-mermaid"].map(RendererMIMEType.init(validating:)))
        let extensions = try! Set(["mmd", "mermaid"].map(RendererFileExtension.init(validating:)))
        let routes = [RendererMatcher.normalizedMIME(canonical)]
            + aliases.map(RendererMatcher.normalizedMIME)
            + extensions.map(RendererMatcher.extensionFallback)
        let asset = RendererAsset(
            path: try! .init(validating: "index.html"),
            digest: try! RendererSHA256Digest(bytes: Array(repeating: 0, count: RendererSHA256Digest.byteCount)))
        let descriptor = try! RendererDescriptor(
            reference: .init(
                packageID: try! .init(validating: "org.example.diagram"),
                version: try! .init(validating: "1.0.0"),
                registrationID: try! .init(validating: "diagram")),
            displayName: "Mermaid",
            implementation: .webPackage(.init(path: asset.path)),
            matchers: routes,
            sourceType: .init(
                canonicalMIMEType: canonical,
                mimeAliases: aliases,
                filenameExtensions: extensions),
            presentations: [.web],
            supportedEmbeddingRoles: [.disclosureRow],
            hasExplicitEmbeddingRoles: true,
            approvedAssets: [asset],
            capabilities: [.inputRead],
            sizeLimits: try! .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try! .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 0)
        return RegisteredRendererSourceTypes(descriptors: [descriptor])
    }()

    @Test func contentTypeLabelByExtension() {
        // Package formats label from the active catalog's display name.
        #expect(SourceProvenanceLabel.contentTypeLabel(
            ext: "mmd", mimeType: nil,
            rendererSourceTypes: mermaidLikeCatalog) == "Mermaid")
        #expect(SourceProvenanceLabel.contentTypeLabel(
            ext: "mermaid", mimeType: nil,
            rendererSourceTypes: mermaidLikeCatalog) == "Mermaid")
        // Without a claim the format is unrecognized (no host-side policy).
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "mmd", mimeType: nil) == nil)
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "pdf", mimeType: nil) == "PDF")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "md", mimeType: nil) == "Markdown")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "markdown", mimeType: nil) == "Markdown")
    }

    @Test func contentTypeLabelIsCaseInsensitive() {
        // SourceSummary.ext is documented as lowercased, but the helper should
        // not silently misclassify if a caller forgets.
        #expect(SourceProvenanceLabel.contentTypeLabel(
            ext: "MMD", mimeType: nil,
            rendererSourceTypes: mermaidLikeCatalog) == "Mermaid")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "PDF", mimeType: nil) == "PDF")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "MD", mimeType: nil) == "Markdown")
    }

    @Test func contentTypeLabelFallsBackToMimeWhenExtUnrecognized() {
        // A `.txt` extension is unrecognized; the catalog's declared MIME
        // aliases still label the row when the package is active.
        #expect(SourceProvenanceLabel.contentTypeLabel(
            ext: "txt", mimeType: "text/mermaid",
            rendererSourceTypes: mermaidLikeCatalog) == "Mermaid")
        #expect(SourceProvenanceLabel.contentTypeLabel(
            ext: "bin", mimeType: "text/x-mermaid",
            rendererSourceTypes: mermaidLikeCatalog) == "Mermaid")
        // Without the claim, a legacy Mermaid MIME is unrecognized.
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "txt", mimeType: "text/mermaid") == nil)
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "", mimeType: "application/pdf") == "PDF")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: nil, mimeType: "text/markdown") == "Markdown")
    }

    @Test func contentTypeLabelReturnsNilForUnrecognized() {
        // docx now maps to the "Word" label (extraction via docx2md).
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "docx", mimeType: nil) == "Word")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "txt", mimeType: "text/plain") == nil)
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: nil, mimeType: nil) == nil)
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "", mimeType: "application/octet-stream") == nil)
        // The MIME fallback arm also maps the wordprocessingml type to "Word";
        // legacy msword (.doc) stays unrecognized.
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document") == "Word")
        #expect(SourceProvenanceLabel.contentTypeLabel(ext: "doc", mimeType: "application/msword") == nil)
    }

    // MARK: - combine

    @Test func combineFileWithContentType() {
        // The issue #644 design table — File branch.
        #expect(SourceProvenanceLabel.combine(
            provider: "File",
            ext: "mmd", mimeType: "text/mermaid",
            rendererSourceTypes: mermaidLikeCatalog) == "File / Mermaid")
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
            ext: "mmd", mimeType: "text/mermaid",
            rendererSourceTypes: mermaidLikeCatalog) == "Zotero / Mermaid")
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
            ext: "docx", mimeType: nil) == "File / Word")
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
