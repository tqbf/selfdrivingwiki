import Foundation
import Testing
@testable import WikiFSCore

/// Unit tests for the image-src rewriter used by the `by-name` FileProvider
/// projection to resolve relative image paths in markdown-native snapshot
/// sources. No store, no view: namespace resolution is injected, exactly as
/// `Projection` supplies.
struct SourceImageRewriterTests {

    // Canonical ULIDs for fixture sibling images.
    private static let pic1ID = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private static let pic2ID = "01BBBBBBBBBBBBBBBBBBBBBBBB"

    private typealias Target = RelativeLinkRewriter.Target

    /// Resolver that maps two snapshot images.
    private func resolver(baseDir: [String] = ["sources", "by-name"]) -> SourceImageRewriter.Resolver {
        let siblingImages: [String: Target] = [
            "assets/pic.png": Target(path: ["sources", "by-name", "pic--\(Self.pic1ID.dropFirst(22)).png"],
                                     title: "pic.png"),
            "images/diagram.svg": Target(path: ["sources", "by-name", "diagram--\(Self.pic2ID.dropFirst(22)).svg"],
                                         title: "diagram.svg"),
        ]
        return SourceImageRewriter.Resolver(baseDir: baseDir, resolve: { path in
            siblingImages[path]
        })
    }

    /// Convenience: rewrite from the sources/by-name view.
    private func rewrite(_ body: String, baseDir: [String] = ["sources", "by-name"]) -> String {
        SourceImageRewriter.rewrite(body, resolver: resolver(baseDir: baseDir))
    }

    // MARK: - Basic image rewriting

    @Test func relativeImageSrcIsRewrittenToResolved() {
        let input = "![diagram](assets/pic.png)"
        let output = rewrite(input)
        #expect(output.contains("![diagram](pic"))
        #expect(output.contains(".png)"))
        #expect(!output.contains("assets/"))
    }

    @Test func multipleImagesResolveIndependently() {
        let input = "![pic1](assets/pic.png) and ![pic2](images/diagram.svg)"
        let output = rewrite(input)
        #expect(output.contains("![pic1](pic"))
        #expect(output.contains("![pic2](diagram"))
        #expect(!output.contains("assets/") && !output.contains("images/"))
    }

    @Test func altTextIsPreservedVerbatim() {
        let input = "![my special diagram [note]](assets/pic.png)"
        let output = rewrite(input)
        #expect(output.contains("![my special diagram [note]]"))
    }

    // MARK: - Unresolved relative paths

    @Test func unresolvedRelativeSrcLeftVerbatim() {
        let input = "![missing](unknown/file.png)"
        #expect(rewrite(input) == input)
    }

    @Test func absoluteHttpUrlLeftVerbatim() {
        let input = "![external](https://example.com/pic.png)"
        #expect(rewrite(input) == input)
    }

    @Test func absoluteHttpsUrlLeftVerbatim() {
        let input = "![secure](https://cdn.example.com/image.png)"
        #expect(rewrite(input) == input)
    }

    @Test func dataUrlLeftVerbatim() {
        let input = "![inline](data:image/png;base64,iVBORw0KG)"
        #expect(rewrite(input) == input)
    }

    @Test func wikiBlobUrlLeftVerbatim() {
        let input = "![blob](wiki-blob:abc123)"
        #expect(rewrite(input) == input)
    }

    @Test func wikiSchemeUrlLeftVerbatim() {
        let input = "![ref](wiki:source:01ABC)"
        #expect(rewrite(input) == input)
    }

    // MARK: - Code protection

    @Test func imageInInlineCodeLeftVerbatim() {
        let input = "Use `![alt](assets/pic.png)` syntax."
        #expect(rewrite(input) == input)
    }

    @Test func imageInFencedBlockLeftVerbatim() {
        let input = """
        ```markdown
        ![alt](assets/pic.png)
        ```
        """
        #expect(rewrite(input) == input)
    }

    @Test func imageOutsideCodeWithImageInCodeKeepsExternal() {
        let input = """
        ![real](assets/pic.png)

        `![not real](assets/pic.png)`
        """
        let output = rewrite(input)
        // First line rewritten
        #expect(output.contains("![real](pic"))
        // Second line stays verbatim
        #expect(output.contains("`![not real](assets/pic.png)`"))
    }

    // MARK: - Sibling-directory resolution

    @Test func siblingInSameDirectoryNeedsNoDots() {
        // When both the markdown and the sibling are in sources/by-name,
        // the relative path is just the filename.
        let input = "![pic](assets/pic.png)"
        let output = rewrite(input, baseDir: ["sources", "by-name"])
        #expect(output.contains("![pic](pic--") && output.contains(".png)"))
        #expect(!output.contains(".."))
    }
}
