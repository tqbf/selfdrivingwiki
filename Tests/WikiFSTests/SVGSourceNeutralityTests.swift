import Foundation
import Testing

/// SVG is renderer-package data, not host policy: production Swift keeps zero
/// SVG rendering code and zero SVG display knowledge. The only allowed
/// mentions are ingestion/content-type metadata (MIME tables, content
/// sniffing, image-embed projection, asset MIME serving) — data rows, not
/// renderer code.
@Suite("SVG source neutrality", .serialized)
struct SVGSourceNeutralityTests {
    /// Files that may mention the format because they carry ingestion or
    /// content-type metadata. Every other Swift file must stay neutral.
    private static let ingestionAllowlist: Set<String> = [
        "Sources/WikiFSTypes/MimeType.swift",
        "Sources/WikiFSTypes/ContentTypeRegistry.swift",
        "Sources/WikiFSCore/Sources/ContentSniff.swift",
        "Sources/WikiFSCore/Sources/FormatMaterializer.swift",
        "Sources/WikiFS/Reader/MarkdownImageEmbedProjection.swift",
        "Sources/WikiFSCore/Renderer/RendererPackageResourceProvider.swift",
    ]

    /// Tokens that existed only because a built-in SVG renderer once shipped.
    /// The renderer/factory symbols are deleted Swift; the token list grows
    /// alongside the forbidden-token pattern of the Mermaid neutrality suite.
    private static let forbiddenTokens = [
        "SVGRendererView",
        "SVGRendererWebView",
        "makeSVG",
        "svgRenderer",
        "svgProjection",
    ]

    @Test("production sources keep SVG out of renderer policy")
    func productionSourcesContainNoActiveSVGPolicy() throws {
        let root = repositoryRoot()
        let sourceRoot = root.appending(path: "Sources")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            let source = try String(contentsOf: url, encoding: .utf8)
            let isAllowlisted = Self.ingestionAllowlist.contains(relative)
            for token in Self.forbiddenTokens {
                #expect(source.contains(token) == false,
                        "\(relative) must not contain \(token)")
            }
            // Renderer-code symbols stay out everywhere; ingestion metadata
            // files may still name the format in their MIME tables.
            if isAllowlisted == false {
                #expect(source.contains("SVGRendererView") == false)
                #expect(source.contains("makeSVG") == false)
            }
        }
        #expect(scanned > 100)
    }

    @Test("the reviewed package owns the SVG display knowledge")
    func theReviewedPackageOwnsTheDisplayKnowledge() throws {
        let root = repositoryRoot()
        let packageRoot = root.appending(path: "RendererPackages/SVG")
        #expect(FileManager.default.fileExists(
            atPath: packageRoot.appending(path: "index.html").path))
        #expect(FileManager.default.fileExists(
            atPath: packageRoot.appending(path: "viewer.js").path))
        #expect(FileManager.default.fileExists(
            atPath: packageRoot.appending(path: "manifest.json").path))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
