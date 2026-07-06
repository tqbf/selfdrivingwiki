import Testing
import Foundation
@testable import WikiFSCore
@testable import WikiFS

/// Phase 4 render-time sibling resolution tests (AC.4). Verifies that
/// `MarkdownHTMLRenderer.render(_, imageResolver:)` rewrites relative image srcs
/// to `wiki-blob://source/<id>` while leaving absolute/data/wiki srcs untouched.
struct SiblingResolutionRenderTests {

    @Test func relativeImageSrcResolvedToBlobURL() {
        let resolver: (String) -> String? = { src in
            // Simulate a sibling map: images/foo.png → source ABC.
            if src == "images/foo.png" { return "wiki-blob://source/ABC123" }
            return nil
        }
        let md = "![foo](images/foo.png)"
        let html = MarkdownHTMLRenderer.render(md, imageResolver: resolver)
        #expect(html.contains(#"src="wiki-blob://source/ABC123""#))
        #expect(!html.contains("images/foo.png"))
    }

    @Test func absoluteSrcLeftUntouched() {
        let resolver: (String) -> String? = { _ in "wiki-blob://source/SHOULD_NOT_APPEAR" }
        let md = "![logo](https://cdn.example.com/logo.png)"
        let html = MarkdownHTMLRenderer.render(md, imageResolver: resolver)
        #expect(html.contains("https://cdn.example.com/logo.png"))
        #expect(!html.contains("SHOULD_NOT_APPEAR"))
    }

    @Test func dataUriLeftUntouched() {
        let resolver: (String) -> String? = { _ in "wiki-blob://source/NO" }
        let md = "![tiny](data:image/png;base64,iVBOR=)"
        let html = MarkdownHTMLRenderer.render(md, imageResolver: resolver)
        #expect(html.contains("data:image/png"))
    }

    @Test func unresolvedRelativeLeftVerbatim() {
        let resolver: (String) -> String? = { _ in nil }
        let md = "![missing](images/not-stored.png)"
        let html = MarkdownHTMLRenderer.render(md, imageResolver: resolver)
        #expect(html.contains("images/not-stored.png"))
    }

    @Test func nilResolverLeavesAllVerbatim() {
        let md = "![foo](images/foo.png)"
        let html = MarkdownHTMLRenderer.render(md)
        #expect(html.contains("images/foo.png"))
    }
}
