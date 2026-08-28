import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

@Suite("Extractor manifest validator", .serialized)
struct ExtractorManifestValidatorTests {
    @Test func validatesDeclaredBytesAndComputesExactRevision() throws {
        let fixture = try makeFixture(launch: .direct, mode: 0o500)
        let validated = try ExtractorManifestValidator.validateStagedDirectory(fixture.root)
        #expect(validated.manifest == fixture.manifest)
        #expect(validated.revisionID.packageID == fixture.manifest.packageID)
        #expect(validated.revisionID.version == fixture.manifest.version)
        let expectedDigest = try fixture.manifest.packageDigest()
        #expect(validated.revisionID.digest == expectedDigest)
    }

    @Test func directEntryRequiresOwnerExecuteButRuntimeNeedsOnlyRead() throws {
        let direct = try makeFixture(launch: .direct, mode: 0o400)
        #expect(throws: ExtractorManifestValidationError.directEntryPointIsNotOwnerExecutable) {
            _ = try ExtractorManifestValidator.validateStagedDirectory(direct.root)
        }
        let runtime = try makeFixture(
            launch: .runtime(command: ExtractorRuntimeName(validating: "bun"), arguments: []),
            mode: 0o400)
        _ = try ExtractorManifestValidator.validateStagedDirectory(runtime.root)
    }

    @Test func rejectsUndeclaredMissingAndChangedFiles() throws {
        let undeclared = try makeFixture(launch: .direct, mode: 0o500)
        try Data("extra".utf8).write(to: undeclared.root.appendingPathComponent("extra.txt"))
        #expect(throws: ExtractorManifestValidationError.undeclaredFile("extra.txt")) {
            _ = try ExtractorManifestValidator.validateStagedDirectory(undeclared.root)
        }

        let hidden = try makeFixture(launch: .direct, mode: 0o500)
        try Data("hidden".utf8).write(to: hidden.root.appendingPathComponent(".hidden"))
        #expect(throws: ExtractorManifestValidationError.undeclaredFile(".hidden")) {
            _ = try ExtractorManifestValidator.validateStagedDirectory(hidden.root)
        }

        let missing = try makeFixture(launch: .direct, mode: 0o500)
        try FileManager.default.removeItem(at: missing.root.appendingPathComponent("bin/extractor"))
        #expect(throws: ExtractorManifestValidationError.missingDeclaredFile("bin/extractor")) {
            _ = try ExtractorManifestValidator.validateStagedDirectory(missing.root)
        }

        let changed = try makeFixture(launch: .direct, mode: 0o500)
        let changedEntry = changed.root.appendingPathComponent("bin/extractor")
        #if canImport(Darwin)
        guard chmod(changedEntry.path, 0o700) == 0 else { throw POSIXError(.EIO) }
        #endif
        try Data("changed".utf8).write(to: changedEntry)
        #expect(throws: ExtractorManifestValidationError.fileDigestMismatch("bin/extractor")) {
            _ = try ExtractorManifestValidator.validateStagedDirectory(changed.root)
        }
    }

    @Test func rejectsManifestSymlinkBeforeReadingIt() throws {
        let fixture = try makeFixture(launch: .direct, mode: 0o500)
        let manifestURL = fixture.root.appendingPathComponent("manifest.json")
        let targetURL = fixture.root.appendingPathComponent("manifest-target.json")
        try FileManager.default.moveItem(at: manifestURL, to: targetURL)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: targetURL)
        #expect(throws: ExtractorManifestValidationError.forbiddenFileType("manifest.json")) {
            _ = try ExtractorManifestValidator.validateStagedDirectory(fixture.root)
        }
    }

    private func makeFixture(launch: ExtractorLaunch, mode: mode_t) throws -> (root: URL, manifest: ExtractorManifest) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-manifest-validator-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let entryURL = bin.appendingPathComponent("extractor", isDirectory: false)
        let bytes = Data("fixture".utf8)
        try bytes.write(to: entryURL)
        #if canImport(Darwin)
        guard chmod(entryURL.path, mode) == 0 else { throw POSIXError(.EIO) }
        #endif
        let manifest = try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.fixture"),
            version: ExtractorPackageVersion(validating: "1.0.0"),
            displayName: "Fixture",
            protocolRevision: .v1,
            entryPoint: ExtractorRelativePath(validating: "bin/extractor"),
            launch: launch,
            registrations: [ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "main"),
                displayName: "Main",
                kinds: [.pdf],
                mimeTypes: [ExtractorMIMEType(validating: "application/pdf")])],
            capabilities: [],
            files: [ExtractorPackageFile(
                path: ExtractorRelativePath(validating: "bin/extractor"),
                digest: ExtractorSHA256.digest(bytes))],
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 2_048,
                maximumDurationMilliseconds: 30_000,
                maximumProgressEventCount: 10))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        return (root, manifest)
    }
}
