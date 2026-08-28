#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
import WikiFSTypes

/// AC.5: the registry's route presentation snapshot exposes each active
/// registration's manifest metadata and identity without any package payload
/// or path ever reaching the presentation layer.
@Suite("Extractor package settings snapshot")
struct ExtractorPackageSettingsSnapshotTests {

    private func digest(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    @Test func registrationRoutesPreserveManifestMetadata() async throws {
        let registry = ExtractionBackendRegistry()
        let reference = ExtractorReference(
            revision: ExtractorPackageRevisionID(
                packageID: try ExtractorPackageID(validating: "org.example.news"),
                version: try ExtractorPackageVersion(validating: "1.2.3"),
                digest: try ExtractorPackageDigest(hex: digest(9))),
            registrationID: try ExtractorRegistrationID(validating: "articles"))
        let presentation = ExtractorRegistrationPresentation(
            displayName: "Article Extractor",
            packageName: "News Package",
            kinds: [.html],
            mimeTypes: [
                try ExtractorMIMEType(validating: "text/html"),
                try ExtractorMIMEType(validating: "application/xhtml+xml"),
            ],
            filenameExtensions: Set([
                ExtractorFileExtension(rawValue: "html"),
                ExtractorFileExtension(rawValue: "xhtml"),
            ].compactMap { $0 }))
        _ = try await registry.registerBatch([
            ExtractionBatchEntry(
                key: .installed(kind: .html, reference: reference),
                backend: RegisteredExtractionBackend(key: ExtractionBackendKey(kind: .html, backendID: "stub")) {
                    .html(StubHTMLExtractor())
                },
                presentation: presentation),
        ])

        let snapshots = await registry.installedRegistrationSnapshots()
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)
        // Declared manifest data survives the projection intact.
        #expect(snapshot.displayName == "Article Extractor")
        #expect(snapshot.packageName == "News Package")
        #expect(snapshot.kinds == [.html])
        #expect(snapshot.mimeTypes.count == 2)
        #expect(snapshot.filenameExtensions.count == 2)
        // Logical and exact identity are present for selection and lifecycle.
        #expect(snapshot.reference == reference)
        #expect(snapshot.reference.revision.packageID.rawValue == "org.example.news")
        #expect(snapshot.reference.registrationID.rawValue == "articles")
        #expect(snapshot.reference.revision.version.rawValue == "1.2.3")
    }

    @Test func snapshotContainsNoPackagePayloadOrPaths() async throws {
        let registry = ExtractionBackendRegistry()
        let reference = ExtractorReference(
            revision: ExtractorPackageRevisionID(
                packageID: try ExtractorPackageID(validating: "org.example.paths"),
                version: try ExtractorPackageVersion(validating: "1.0.0"),
                digest: try ExtractorPackageDigest(hex: digest(1))),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let presentation = ExtractorRegistrationPresentation(
            displayName: "Main",
            packageName: "Paths Package",
            kinds: [.pdf],
            mimeTypes: [try ExtractorMIMEType(validating: "application/pdf")],
            filenameExtensions: [])
        _ = try await registry.registerBatch([
            ExtractionBatchEntry(
                key: .installed(kind: .pdf, reference: reference),
                backend: RegisteredExtractionBackend(key: ExtractionBackendKey(kind: .pdf, backendID: "stub")) {
                    .pdf(ExtractionPreparation(
                        extractor: StubMarkdownExtractor(),
                        backend: .localPdf2md,
                        modelVersion: nil))
                },
                presentation: presentation),
        ])

        // Only value metadata is projected: no URLs, absolute paths, or
        // package payload references of any kind.
        let snapshots = await registry.installedRegistrationSnapshots()
        let rendered = snapshots.map(String.init(describing:))
        for description in rendered {
            #expect(description.contains("file://") == false)
            #expect(description.contains("/Users/") == false)
            #expect(description.contains(".sqlite") == false)
        }
        // The snapshot type itself carries no path-shaped fields.
        let mirror = Mirror(reflecting: try #require(snapshots.first))
        for child in mirror.children {
            #expect(child.value is URL == false)
            #expect(child.value is Data == false)
        }
    }
}
#endif
