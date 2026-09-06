import Foundation
import Testing
@testable import WikiFSCore

/// AC.8/AC.9: the reviewed manifests and the documentation agree on package
/// identities, versions, and source-type declarations. When a reviewed
/// package changes identity or source type, update both docs in the same
/// change.
@Suite("Reviewed source types match documentation", .serialized, .timeLimit(.minutes(1)))
struct ReviewedSourceTypeDocumentationTests {
    private struct ReviewedPackage {
        let folder: String
        let packageID: String
        let version: String
        let canonicalMIME: String
        let extensions: [String]
    }

    private static let reviewed: [ReviewedPackage] = [
        ReviewedPackage(
            folder: "Mermaid", packageID: "org.selfdrivingwiki.mermaid-readonly",
            version: "1.1.0", canonicalMIME: "text/vnd.mermaid",
            extensions: ["mmd", "mermaid"]),
        ReviewedPackage(
            folder: "SVG", packageID: "org.selfdrivingwiki.svg-readonly",
            version: "1.1.0", canonicalMIME: "image/svg+xml",
            extensions: ["svg"]),
        ReviewedPackage(
            folder: "Excalidraw", packageID: "org.selfdrivingwiki.excalidraw-readonly",
            version: "1.1.0", canonicalMIME: "application/json",
            extensions: ["excalidraw"]),
        ReviewedPackage(
            folder: "JSONCanvas", packageID: "org.selfdrivingwiki.json-canvas-readonly",
            version: "1.2.0", canonicalMIME: "application/json",
            extensions: ["canvas"]),
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("reviewed source type declarations match documentation")
    func reviewedSourceTypeDeclarationsMatchDocumentation() throws {
        let userGuide = try String(
            contentsOf: Self.repositoryRoot.appending(path: "docs/user-guide/renderer-packages.md"),
            encoding: .utf8)
        let maintainerGuide = try String(
            contentsOf: Self.repositoryRoot
                .appending(path: "docs/skills/renderer-package-maintainer/references/current-package-guide.md"),
            encoding: .utf8)

        // The maintainer guide documents the revision-6 sourceType surface.
        #expect(maintainerGuide.contains("Source types (manifest revision 6)"))
        #expect(maintainerGuide.contains("canonicalMIMEType"))
        #expect(maintainerGuide.contains("normalizedMIME"))
        #expect(maintainerGuide.contains("extensionFallback"))

        // The user guide explains the dry-run-first repair workflow.
        #expect(userGuide.contains("wikictl admin repair-mime"))
        #expect(userGuide.contains("--apply"))
        #expect(userGuide.contains("Source types and stored MIME"))

        for package in Self.reviewed {
            let manifestURL = Self.repositoryRoot
                .appending(path: "RendererPackages/\(package.folder)")
                .appending(path: "manifest.json")
            let manifest = try JSONDecoder().decode(
                RendererManifest.self,
                from: Data(contentsOf: manifestURL))
            let descriptor = try #require(manifest.descriptors.first)
            let sourceType = try #require(descriptor.sourceType)

            // The manifest agrees with the reviewed table above.
            #expect(manifest.revision == RendererManifestRevision.sourceTypes)
            #expect(manifest.packageID.rawValue == package.packageID)
            #expect(manifest.version.rawValue == package.version)
            #expect(sourceType.canonicalMIMEType.rawValue == package.canonicalMIME)
            #expect(sourceType.filenameExtensions.map(\.rawValue).sorted() == package.extensions.sorted())

            // Both docs carry the identity, version, and canonical MIME.
            for doc in [userGuide, maintainerGuide] {
                #expect(doc.contains(package.packageID), "\(package.packageID) missing from documentation")
                #expect(doc.contains("`\(package.version)`"), "\(package.folder) version missing from documentation")
                #expect(doc.contains(package.canonicalMIME), "\(package.canonicalMIME) missing from documentation")
            }
        }
    }
}
