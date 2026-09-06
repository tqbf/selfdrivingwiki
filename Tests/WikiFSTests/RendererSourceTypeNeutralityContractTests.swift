import Foundation
import Testing

@testable import WikiFSCore
@testable import WikiFSTypes

/// AC.5 neutrality contract: production Swift carries no Mermaid source
/// policy. The canonical MIME, aliases, extensions, package identity, and
/// provenance label live exclusively in the reviewed package manifest.
@Suite("Renderer source-type neutrality", .serialized)
struct RendererSourceTypeNeutralityContractTests {
    /// Code-level policy literals that must not appear in any production
    /// target. Prose comments that discuss the design generically are not
    /// policy; these literals are.
    private static let forbiddenLiterals = [
        "text/mermaid",
        "text/x-mermaid",
        "text/vnd.mermaid",
        "application/vnd.chipnuts.karaoke-mmd",
        "mermaid-readonly",
        "MimeType.mermaid",
        "MimeType.isMermaid",
        "mermaidVariants",
        "mermaidX",
        "\"mmd\"",
        "\"mermaid\"",
    ]

    private static var productionSwiftFiles: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL])?
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.absoluteString < $1.absoluteString } ?? []
    }

    @Test("production Swift contains no Mermaid source policy")
    func productionSwiftContainsNoMermaidSourcePolicy() throws {
        let files = Self.productionSwiftFiles
        #expect(files.isEmpty == false)
        for literal in Self.forbiddenLiterals {
            let offenders = files.compactMap { file -> String? in
                guard let source = try? String(contentsOf: file, encoding: .utf8),
                      source.contains(literal) else { return nil }
                return file.lastPathComponent
            }
            #expect(offenders.isEmpty, "\(literal) must not appear in production Swift; found in \(offenders)")
        }
    }

    @Test("the reviewed Mermaid manifest exclusively declares the source-type surface")
    func reviewedMermaidManifestExclusivelyDeclaresTheSurface() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            RendererManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("RendererPackages/Mermaid/manifest.json")))
        let descriptor = try #require(manifest.descriptors.only)
        let sourceType = try #require(descriptor.sourceType)

        #expect(sourceType.canonicalMIMEType.rawValue == "text/vnd.mermaid")
        #expect(sourceType.mimeAliases == [
            try .init(validating: "text/mermaid"),
            try .init(validating: "text/x-mermaid"),
            try .init(validating: "application/vnd.chipnuts.karaoke-mmd"),
        ])
        #expect(sourceType.filenameExtensions == [
            try .init(validating: "mmd"),
            try .init(validating: "mermaid"),
        ])
        #expect(descriptor.displayName == "Mermaid")
        #expect(manifest.packageID.rawValue == "org.selfdrivingwiki.mermaid-readonly")
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
