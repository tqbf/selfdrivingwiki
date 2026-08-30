import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSExtractorStore
@testable import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

@Suite("Process extractor provider", .serialized, .timeLimit(.minutes(3)))
struct ProcessExtractorProviderTests {
    @Test func pdfPreparationConvertsWithStreamedProgress() async throws {
        let environment = try await InstalledFixtureEnvironment.install()
        defer { environment.cleanup() }
        let progress = ProgressRecorder()

        let preparation = try await environment.provider.preparePDF(
            revision: environment.revision,
            manifest: environment.manifest)
        let extractor = preparation.extractor

        #expect(extractor.displayName == "Managed Fixture")
        #expect(await extractor.readiness() == .ready)
        let markdown = try await extractor.convert(
            pdfData: Data("success".utf8),
            filename: "sample.pdf",
            onProgress: { progress.record($0) })
        #expect(markdown == "# Fixture\n")
        #expect(progress.lines == ["complete\n"])
    }

    @Test func htmlExtractionCarriesMetadataAndSurfacesFailure() async throws {
        let environment = try await InstalledFixtureEnvironment.install()
        defer { environment.cleanup() }

        let extractor = try await environment.provider.prepareHTML(
            revision: environment.revision,
            manifest: environment.manifest)

        let success = await extractor.extract(html: "htmlsuccess")
        #expect(success?.markdown == "# Hello\n\nWorld.\n")
        #expect(success?.title == "Hello")
        #expect(success?.author == "Jane Doe")
        #expect(success?.wordCount == 2)

        let failure = await extractor.extract(html: "failure")
        #expect(failure == nil)
    }

    @Test func docxPreparationRunsTheManagedFixtureAndCarriesProvenance() async throws {
        let environment = try await InstalledFixtureEnvironment.install()
        defer { environment.cleanup() }

        let extractor = try await environment.provider.prepareDOCX(
            revision: environment.revision,
            manifest: environment.manifest)

        let success = await extractor.extract(docx: Data("success".utf8))
        #expect(success?.markdown == "# Fixture\n")

        let failure = await extractor.extract(docx: Data("failure".utf8))
        #expect(failure == nil)

        // Package provenance rides on the process adapter so the store path
        // records the `.installedPackage` producer.
        let provenancing = extractor as? any ProcessPackageProvenanceProviding
        #expect(provenancing?.packageProvenance.revision == environment.revision)
        #expect(provenancing?.packageProvenance.registrationID.rawValue == "document")
    }

    @Test func preparedSnapshotSurvivesRemovalAndFuturePreparationFails() async throws {
        let environment = try await InstalledFixtureEnvironment.install()
        defer { environment.cleanup() }

        let preparation = try await environment.provider.preparePDF(
            revision: environment.revision,
            manifest: environment.manifest)
        let pinnedProvenance = try #require(preparation.packageProvenance)

        let writer = try ExtractorPackageCatalogWriter.testing(layout: environment.layout)
        _ = try await writer.replaceCatalog(expectedGeneration: 1, records: [])

        let markdown = try await preparation.extractor.convert(
            pdfData: Data("success".utf8),
            filename: "prepared-before-removal.pdf",
            onProgress: nil)
        #expect(markdown == "# Fixture\n")
        #expect(preparation.packageProvenance == pinnedProvenance)

        await #expect(throws: ProcessPackagePreparationError.unknownRevision) {
            _ = try await environment.provider.preparePDF(
                revision: environment.revision,
                manifest: environment.manifest)
        }
    }

    @Test func pdfConversionPreservesCancellationIdentity() async throws {
        let environment = try await InstalledFixtureEnvironment.install(
            executor: CancellingManagedProcessExecutor())
        defer { environment.cleanup() }

        let preparation = try await environment.provider.preparePDF(
            revision: environment.revision,
            manifest: environment.manifest)

        await #expect(throws: CancellationError.self) {
            _ = try await preparation.extractor.convert(
                pdfData: Data("success".utf8),
                filename: "cancelled.pdf",
                onProgress: nil)
        }
    }

    @Test func preparationRejectionsAreTyped() async throws {
        let environment = try await InstalledFixtureEnvironment.install()
        defer { environment.cleanup() }

        let deniedProvider = ProcessExtractorProvider(
            layout: environment.layout,
            catalogReader: ExtractorPackageCatalogReader(layout: environment.layout),
            executor: ManagedExtractorProcessExecutor(),
            admitted: { _ in false })
        await #expect(throws: ProcessPackagePreparationError.notAdmitted) {
            _ = try await deniedProvider.preparePDF(
                revision: environment.revision,
                manifest: environment.manifest)
        }

        let wrongDigestRevision = ExtractorPackageRevisionID(
            packageID: environment.revision.packageID,
            version: environment.revision.version,
            digest: try ExtractorPackageDigest(hex: String(repeating: "a", count: 64)))
        await #expect(throws: ProcessPackagePreparationError.identityMismatch) {
            _ = try await environment.provider.preparePDF(
                revision: wrongDigestRevision,
                manifest: environment.manifest)
        }

        let foreignManifest = try Self.makeUninstalledManifest(packageID: "org.example.foreign")
        let foreignRevision = ExtractorPackageRevisionID(
            packageID: foreignManifest.packageID,
            version: foreignManifest.version,
            digest: try foreignManifest.packageDigest())
        await #expect(throws: ProcessPackagePreparationError.unknownRevision) {
            _ = try await environment.provider.preparePDF(
                revision: foreignRevision,
                manifest: foreignManifest)
        }
    }

    // MARK: - Shared manifest builders

    /// A self-consistent manifest for revisions that are intentionally absent
    /// from the machine catalog.
    static func makeUninstalledManifest(packageID: String) throws -> ExtractorManifest {
        try Self.buildManifest(
            packageID: packageID,
            entryPath: try ExtractorRelativePath(validating: "bin/fixture"),
            files: [ExtractorPackageFile(
                path: try ExtractorRelativePath(validating: "bin/fixture"),
                digest: ExtractorSHA256.digest(Data()))])
    }

    static func buildManifest(
        packageID: String,
        entryPath: ExtractorRelativePath,
        files: [ExtractorPackageFile]
    ) throws -> ExtractorManifest {
        var registrations: [ExtractorRegistration] = [
            try ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "pdf"),
                displayName: "PDF",
                kinds: [.pdf],
                mimeTypes: [ExtractorMIMEType(validating: "application/pdf")]),
            try ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "html"),
                displayName: "HTML",
                kinds: [.html],
                mimeTypes: [ExtractorMIMEType(validating: "text/html")]),
            try ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "document"),
                displayName: "DOCX",
                kinds: [.docx],
                mimeTypes: [ExtractorMIMEType(validating: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")]),
        ]
        registrations.sort()
        return try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: packageID),
            version: ExtractorPackageVersion(validating: "1.0.0"),
            displayName: "Managed Fixture",
            protocolRevision: .v1,
            entryPoint: entryPath,
            launch: .direct,
            registrations: registrations,
            capabilities: [],
            files: files,
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 65_536,
                maximumMarkdownOutputByteCount: 65_536,
                maximumDurationMilliseconds: 10_000,
                maximumProgressEventCount: 8))
    }
}

private struct CancellingManagedProcessExecutor: ManagedProcessExecuting {
    func execute(
        _ operation: ManagedExtractorProcessRequest,
        onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void
    ) async throws -> ManagedExtractorProcessResult {
        throw ManagedExtractorProcessError.cancellation
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    var lines: [String] { lock.withLock { storage } }
}

/// Installs the managed protocol fixture as a real catalog revision inside an
/// isolated `.test` layout, and exposes a provider wired to it.
private final class InstalledFixtureEnvironment: @unchecked Sendable {
    let root: URL
    let layout: ExtractorPackageStoreLayout
    let provider: ProcessExtractorProvider
    let revision: ExtractorPackageRevisionID
    let manifest: ExtractorManifest

    enum EnvironmentError: Error {
        case installationFailed
        case missingFixtureExecutable
    }

    static func install(
        executor: any ManagedProcessExecuting = ManagedExtractorProcessExecutor()
    ) async throws -> InstalledFixtureEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("process-provider-\(UUID().uuidString)", isDirectory: true)
        let layout = try ExtractorPackageStoreLayout(
            appGroupContainerRoot: root,
            processRole: .test)

        let executableURL = try findFixtureExecutable()
        let sourceBytes = try Data(contentsOf: executableURL)
        let entryPath = try ExtractorRelativePath(validating: "bin/fixture")

        let packageRoot = root.appendingPathComponent("source-package", isDirectory: true)
        let entryURL = packageRoot.appendingPathComponent(entryPath.rawValue)
        try FileManager.default.createDirectory(
            at: entryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try sourceBytes.write(to: entryURL)
        guard chmod(entryURL.path, 0o500) == 0 else { throw POSIXError(.EIO) }

        let manifest = try ProcessExtractorProviderTests.buildManifest(
            packageID: "org.example.process-provider",
            entryPath: entryPath,
            files: [ExtractorPackageFile(
                path: entryPath,
                digest: ExtractorSHA256.digest(sourceBytes))])
        try JSONEncoder().encode(manifest).write(
            to: packageRoot.appendingPathComponent("manifest.json"))

        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        let installed = try await writer.importDirectory(
            packageRoot,
            installedAt: RFC3339Timestamp(date: Date()))
        guard let record = installed.records.first(where: {
            $0.revision.packageID.rawValue == "org.example.process-provider"
        }) else {
            throw EnvironmentError.installationFailed
        }

        return InstalledFixtureEnvironment(
            root: root,
            layout: layout,
            provider: ProcessExtractorProvider(
                layout: layout,
                catalogReader: ExtractorPackageCatalogReader(layout: layout),
                executor: executor,
                admitted: { _ in true }),
            revision: record.revision,
            manifest: manifest)
    }

    private init(
        root: URL,
        layout: ExtractorPackageStoreLayout,
        provider: ProcessExtractorProvider,
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest
    ) {
        self.root = root
        self.layout = layout
        self.provider = provider
        self.revision = revision
        self.manifest = manifest
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Process provider fixture cleanup failed: \(error)") }
    }

    private static func findFixtureExecutable() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let candidate = enumerator?.nextObject() as? URL {
            if candidate.lastPathComponent == "ManagedExtractorFixture",
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw EnvironmentError.missingFixtureExecutable
    }
}
