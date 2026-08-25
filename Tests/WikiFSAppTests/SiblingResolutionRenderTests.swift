#if os(macOS)
import Testing
import Foundation
@testable import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Typed sibling-image resolution tests. The document projection maps exact
/// relative targets to source IDs before the HTML lowerer runs.
struct SiblingResolutionRenderTests {

    @Test func relativeImageSrcResolvedToBlobURL() {
        let md = "![foo](images/foo.png)"
        let prepared = ReaderMarkdown.preparedDocument(md)
        let projection = ResolvedDocumentProjection(markdownImages: [
            "images/foo.png": .blob(SourceID(rawValue: "ABC123")),
        ])
        let html = MarkdownHTMLRenderer.render(prepared, projection: projection, options: .disabled)
        #expect(html.contains(#"src="wiki-blob://source/ABC123""#))
        #expect(!html.contains("images/foo.png"))
    }

    @Test func absoluteSrcLeftUntouched() {
        let md = "![logo](https://cdn.example.com/logo.png)"
        let html = MarkdownHTMLRenderer.render(md, options: .disabled)
        #expect(html.contains("https://cdn.example.com/logo.png"))
        #expect(!html.contains("SHOULD_NOT_APPEAR"))
    }

    @Test func dataUriLeftUntouched() {
        let md = "![tiny](data:image/png;base64,iVBOR=)"
        let html = MarkdownHTMLRenderer.render(md, options: .disabled)
        #expect(html.contains("data:image/png"))
    }

    @Test func unresolvedRelativeLeftVerbatim() {
        let md = "![missing](images/not-stored.png)"
        let html = MarkdownHTMLRenderer.render(md, options: .disabled)
        #expect(html.contains("images/not-stored.png"))
    }

    @Test func nilResolverLeavesAllVerbatim() {
        let md = "![foo](images/foo.png)"
        let html = MarkdownHTMLRenderer.render(md, options: .disabled)
        #expect(html.contains("images/foo.png"))
    }
}
#endif
