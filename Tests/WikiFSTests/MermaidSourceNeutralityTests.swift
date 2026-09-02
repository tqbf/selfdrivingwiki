import Foundation
import Testing

/// Mermaid is renderer-package data, not host policy: production Swift keeps
/// zero Mermaid rendering code and zero Mermaid JS bytes. The only allowed
/// mentions are ingestion/content-type metadata (MIME tables, native-text
/// classification, provenance labels) — data rows, not renderer code — and
/// the bundled agent prompt, which documents authoring.
@Suite("Mermaid source neutrality", .serialized)
struct MermaidSourceNeutralityTests {
    /// Files that may mention the format because they carry ingestion or
    /// content-type metadata. Every other Swift file must stay neutral.
    private static let ingestionAllowlist: Set<String> = [
        "Sources/WikiFSTypes/MimeType.swift",
        "Sources/WikiFSTypes/ContentTypeRegistry.swift",
        "Sources/WikiFSCore/Sources/SourceProvenanceLabel.swift",
    ]

    /// Tokens that exist only because a built-in renderer or a bundled
    /// validator once shipped. `merval` is the retired third-party
    /// validator; the renderer/validator/detector symbols are deleted
    /// Swift; the class/attribute tokens are deleted reader DOM plumbing.
    private static let forbiddenTokens = [
        "MermaidRenderer",
        "MermaidValidator",
        "MermaidSourceDetector",
        "mermaidBootstrapJS",
        "sdw-inline-mermaid",
        "sdw-mermaid-row",
        "data-mermaid-disclosure",
        "mermaid.min.js",
        "merval",
        "renderableMermaidMarkdown",
        "mermaidProjection",
        "mermaidDiagramSource",
        "mermaidSaveWarning",
        "mermaidFenceAlias",
        "__merval",
    ]

    @Test("production sources keep Mermaid out of renderer policy")
    func productionSourcesContainNoActiveMermaidPolicy() throws {
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
            // The un-allowlisted files may not name the format at all —
            // not in code, not in comments. A renderer-package format is
            // data: the host spells it nowhere.
            if isAllowlisted == false {
                #expect(source.localizedCaseInsensitiveContains("mermaid") == false,
                        "\(relative) names the format outside the ingestion allowlist")
            }
        }
        #expect(scanned > 100)
    }

    @Test("SwiftPM and build packaging carry no Mermaid asset or package reference")
    func packageManifestAndBuildScriptDoNotBundleMermaid() throws {
        let root = repositoryRoot()
        let package = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let build = try String(contentsOf: root.appending(path: "build.sh"), encoding: .utf8)

        // No asset is copied, declared, or referenced anywhere in packaging.
        #expect(package.localizedCaseInsensitiveContains("mermaid") == false)
        #expect(build.localizedCaseInsensitiveContains("mermaid") == false)
        #expect(package.contains("RendererPackages/Mermaid") == false)
        #expect(build.contains("RendererPackages/Mermaid") == false)
        #expect(build.contains("mermaid.js") == false)
        // The repo resources no longer carry the vendored bytes.
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "Resources/mermaid.min.js").path) == false)
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "Resources/merval.bundle.js").path) == false)
    }

    @Test("the reviewed package owns the vendored engine bytes")
    func theReviewedPackageOwnsTheEngineBytes() throws {
        let root = repositoryRoot()
        let packageRoot = root.appending(path: "RendererPackages/Mermaid")
        #expect(FileManager.default.fileExists(
            atPath: packageRoot.appending(path: "mermaid.min.js").path))
        #expect(FileManager.default.fileExists(
            atPath: packageRoot.appending(path: "validate.js").path))
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
