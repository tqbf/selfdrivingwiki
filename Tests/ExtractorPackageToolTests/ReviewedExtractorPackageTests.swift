import Foundation
import Testing
import WikiFSTypes
@testable import ExtractorPackageToolCore

/// The reviewed packages under `ExtractorPackages/` are build inputs: the app
/// and the wikid XPC service both receive this tree, and the machine catalog
/// records the exact digest of every declared file.
///
/// These tests run the real validator over the committed bytes, so a hand
/// edit, a stale regeneration, or a manifest that could never be admitted
/// fails here rather than at install time on a user's Mac.
@Suite("Reviewed extractor packages", .serialized, .timeLimit(.minutes(3)))
struct ReviewedExtractorPackageTests {
    @Test func defuddlePackageValidatesAndKeepsItsReviewedIdentity() throws {
        let output = try validate("Defuddle")

        #expect(output.packageID == "org.selfdrivingwiki.defuddle")
        #expect(output.protocolRevision == 1)
        #expect(output.registrationIDs == ["article"])
    }

    @Test func pdf2mdPackageValidatesAndKeepsItsReviewedIdentity() throws {
        let output = try validate("Pdf2md")

        #expect(output.packageID == "org.selfdrivingwiki.pdf2md")
        #expect(output.protocolRevision == 1)
        #expect(output.registrationIDs == ["document"])
    }

    /// The reviewed Docling Serve package (#1159): manifest revision 2,
    /// protocol revision 2, one PDF registration declaring the optional
    /// `api-token` requirement. No secret value and no credential reference
    /// may appear in the committed bytes.
    @Test func doclingServePackageValidatesRevisionTwoContract() throws {
        let output = try validate("DoclingServe")

        #expect(output.packageID == "org.selfdrivingwiki.docling-serve")
        #expect(output.protocolRevision == 2)
        #expect(output.registrationIDs == ["document"])

        let manifest = try manifest("DoclingServe")
        #expect(manifest.manifestRevision == .v2)
        let requirements = manifest.registrations.flatMap(\.credentialRequirements)
        #expect(requirements.map(\.id.rawValue) == ["api-token"])
        #expect(requirements.allSatisfy { $0.isOptional && $0.kind == .secret })

        // Secret-free bytes: the declared requirement is a review fact; a
        // value or a reference binding must never be committed.
        let manifestData = try Data(contentsOf: Self.packageURL("DoclingServe")
            .appendingPathComponent("manifest.json"))
        let payload = String(decoding: manifestData, as: UTF8.self)
        #expect(payload.contains("credentialReference") == false)
        #expect(payload.contains("credential_locations") == false)
    }

    @Test func reviewedDigestsAreStableAcrossRepeatedValidation() throws {
        for name in ["Defuddle", "Pdf2md", "DoclingServe"] {
            let first = try validate(name)
            let second = try validate(name)
            #expect(first.packageDigest == second.packageDigest)
            #expect(first.packageDigest.count == 64)
        }
        // The compiled reviewed identity matches the committed bytes (AC.17).
        // The golden constant lives in WikiFSEngine.ReviewedExtractorPackages;
        // pinned here byte-for-byte so this tool-target gate fails loudly on
        // drift even though it cannot import the engine module.
        #expect(try validate("DoclingServe").packageDigest
            == "8e3ad795a1f1dd2a1750a425e9f16df221078d065a07dbe71818b7603521d113")
    }

    /// Revision 1 supports PDF and HTML byte extraction only, and the two
    /// reviewed packages must not claim the same kind.
    @Test func reviewedPackagesCoverDistinctKinds() throws {
        let defuddle = try manifest("Defuddle")
        let pdf2md = try manifest("Pdf2md")

        #expect(defuddle.registrations.allSatisfy { $0.kinds == [.html] })
        #expect(pdf2md.registrations.allSatisfy { $0.kinds == [.pdf] })
    }

    /// A runtime package must name one command without a path. The host
    /// resolves it against its own immutable search list, so a manifest that
    /// carried a path would bypass that policy.
    @Test func reviewedPackagesLaunchThroughNamedRuntimes() throws {
        guard case .runtime(let defuddleCommand, let defuddleArguments) = try manifest("Defuddle").launch else {
            Issue.record("Defuddle must launch through a runtime")
            return
        }
        #expect(defuddleCommand.rawValue == "bun")
        #expect(defuddleArguments.isEmpty)

        guard case .runtime(let pdfCommand, let pdfArguments) = try manifest("Pdf2md").launch else {
            Issue.record("pdf2md must launch through a runtime")
            return
        }
        #expect(pdfCommand.rawValue == "uv")
        // The host appends the entry point after these arguments.
        #expect(pdfArguments == ["run", "--script"])
    }

    /// Capability declarations are review facts. Local HTML extraction reads
    /// only its operation input, so Defuddle must not claim network access.
    @Test func defuddleClaimsNoCapabilities() throws {
        #expect(try manifest("Defuddle").capabilities.isEmpty)
    }

    /// uv resolves dependencies and docling downloads its model on first use.
    @Test func pdf2mdDeclaresItsNetworkAndModelCapabilities() throws {
        let capabilities = try manifest("Pdf2md").capabilities

        #expect(capabilities.contains(.network))
        #expect(capabilities.contains(.modelDownload))
        #expect(capabilities.contains(.sharedRuntimeCache))
    }

    // MARK: - Helpers

    private func validate(_ name: String) throws -> ExtractorPackageValidationOutput {
        try ExtractorPackageToolExecutor().execute(
            arguments: ["validate", Self.packageURL(name).path])
    }

    private func manifest(_ name: String) throws -> ExtractorManifest {
        let data = try Data(contentsOf: Self.packageURL(name).appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(ExtractorManifest.self, from: data)
    }

    private static func packageURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExtractorPackages", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}
