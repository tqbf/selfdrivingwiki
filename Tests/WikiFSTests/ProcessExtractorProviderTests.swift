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

        // Package provenance is part of the DOCX extractor contract.
        #expect(extractor.packageProvenance.revision == environment.revision)
        #expect(extractor.packageProvenance.registrationID.rawValue == "document")
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

    // MARK: - Retained runtime resolution (AC.2, AC.9)

    /// Preparation resolves the runtime exactly once; readiness and repeated
    /// executions never resolve again.
    @Test func runtimeResolutionOccursOncePerPreparedOperation() async throws {
        let environment = try await InstalledFixtureEnvironment.install(
            launch: .runtime(
                command: ExtractorRuntimeName(validating: "fixture-runtime"),
                arguments: []))
        defer { environment.cleanup() }

        let preparation = try await environment.provider.preparePDF(
            revision: environment.revision,
            manifest: environment.manifest)
        let extractor = preparation.extractor

        #expect(await extractor.readiness() == .ready)
        #expect(await extractor.readiness() == .ready)
        let markdown = try await extractor.convert(
            pdfData: Data("success".utf8),
            filename: "sample.pdf",
            onProgress: nil)
        #expect(markdown == "# Fixture\n")
        #expect(await extractor.readiness() == .ready)
        #expect(environment.locator.callCount == 1)
    }

    /// Readiness and execution consume the same retained result: a retained
    /// failure reports setup guidance and throws the matching typed
    /// managed-process error, without a second resolution.
    @Test func readinessAndExecutionShareRetainedResolution() async throws {
        let spy = SpyRuntimeLocator()
        spy.queueOutcomes = [.failed(.commandAbsent)]
        let environment = try await InstalledFixtureEnvironment.install(
            launch: .runtime(
                command: ExtractorRuntimeName(validating: "fixture-runtime"),
                arguments: []),
            locator: spy)
        defer { environment.cleanup() }

        let preparation = try await environment.provider.preparePDF(
            revision: environment.revision,
            manifest: environment.manifest)

        #expect(await preparation.extractor.readiness() == .needsSetup(
            "Runtime fixture-runtime is not installed. Install it and make sure it runs in your login shell."))
        do {
            _ = try await preparation.extractor.convert(
                pdfData: Data("success".utf8),
                filename: "sample.pdf",
                onProgress: nil)
            Issue.record("expected the retained failure to block execution")
        } catch let error as ProcessPackageError {
            #expect(error.message.contains("fixture-runtime is not available"))
        }
        // The same failure is retained — no second resolution even though a
        // success is now available.
        #expect(spy.callCount == 1)
    }

    /// AC.9: a newly prepared operation resolves again, so a runtime
    /// installed after an earlier failure works without an app restart.
    @Test func newPreparationRetriesRuntimeResolutionAfterEarlierFailure() async throws {
        let spy = SpyRuntimeLocator()
        spy.queueOutcomes = [.failed(.commandAbsent)]
        let environment = try await InstalledFixtureEnvironment.install(
            launch: .runtime(
                command: ExtractorRuntimeName(validating: "fixture-runtime"),
                arguments: []),
            locator: spy)
        defer { environment.cleanup() }

        let first = try await environment.provider.preparePDF(
            revision: environment.revision,
            manifest: environment.manifest)
        #expect(await first.extractor.readiness() == .needsSetup(
            "Runtime fixture-runtime is not installed. Install it and make sure it runs in your login shell."))

        // The "installation": from the next call the spy resolves the real
        // fixture runtime in the environment's private bin.
        let second = try await environment.provider.preparePDF(
            revision: environment.revision,
            manifest: environment.manifest)
        #expect(await second.extractor.readiness() == .ready)
        let markdown = try await second.extractor.convert(
            pdfData: Data("success".utf8),
            filename: "sample.pdf",
            onProgress: nil)
        #expect(markdown == "# Fixture\n")
        #expect(spy.callCount == 2)
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
        files: [ExtractorPackageFile],
        launch: ExtractorLaunch = .direct
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
            launch: launch,
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

/// A locator spy for provider tests. Queued outcomes are consumed first, one
/// per call; once the queue is empty the sticky `followUp` answer (if set)
/// applies. Every call is counted.
final class SpyRuntimeLocator: ExtractorRuntimeLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [RuntimeCommandOutcome] = []
    private var followUp: (@Sendable () -> RuntimeCommandOutcome)?
    private var calls: [String] = []

    var queueOutcomes: [RuntimeCommandOutcome] {
        get { lock.withLock { queue } }
        set { lock.withLock { queue = newValue } }
    }

    func setFollowUp(_ followUp: (@Sendable () -> RuntimeCommandOutcome)?) {
        lock.withLock { self.followUp = followUp }
    }

    func locate(_ command: ExtractorRuntimeName) async -> RuntimeCommandOutcome {
        lock.withLock {
            calls.append(command.rawValue)
            if queue.isEmpty {
                return followUp?() ?? .failed(.commandAbsent)
            }
            return queue.removeFirst()
        }
    }

    var callCount: Int { lock.withLock { calls.count } }
}

/// Installs the managed protocol fixture as a real catalog revision inside an
/// isolated `.test` layout, and exposes a provider wired to it.
private final class InstalledFixtureEnvironment: @unchecked Sendable {
    let root: URL
    let layout: ExtractorPackageStoreLayout
    let provider: ProcessExtractorProvider
    let locator: SpyRuntimeLocator
    let revision: ExtractorPackageRevisionID
    let manifest: ExtractorManifest

    enum EnvironmentError: Error {
        case installationFailed
        case missingFixtureExecutable
    }

    static func install(
        executor: any ManagedProcessExecuting = ManagedExtractorProcessExecutor(),
        launch: ExtractorLaunch = .direct,
        locator: SpyRuntimeLocator? = nil
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
                digest: ExtractorSHA256.digest(sourceBytes))],
            launch: launch)
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

        // A runtime-launch environment resolves through a spy whose default
        // sticky answer is the fixture executable in the environment's
        // private bin; tests may override the follow-up after install.
        let resolvedLocator = locator ?? SpyRuntimeLocator()
        if case .runtime(let command, _) = launch {
            resolvedLocator.setFollowUp { [root] in
                do {
                    return .resolved(try runtimeResolution(
                        command: command.rawValue, root: root))
                } catch {
                    return .failed(.commandAbsent)
                }
            }
        }

        return InstalledFixtureEnvironment(
            root: root,
            layout: layout,
            provider: ProcessExtractorProvider(
                layout: layout,
                catalogReader: ExtractorPackageCatalogReader(layout: layout),
                executor: executor,
                admission: ClosureProcessPackageAdmission(check: { _ in true }),
                runtimeLocator: resolvedLocator),
            locator: resolvedLocator,
            revision: record.revision,
            manifest: manifest)
    }

    /// A resolution for the fixture executable copied into `root`'s private
    /// bin directory — one absolute URL with a probed identity.
    static func runtimeResolution(command: String, root: URL) throws -> RuntimeCommandResolution {
        let bin = root.appendingPathComponent("runtime-bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent(command)
        let bytes = try Data(contentsOf: findFixtureExecutable())
        try bytes.write(to: executable)
        guard chmod(executable.path, 0o500) == 0 else { throw POSIXError(.EIO) }
        let url = executable.standardizedFileURL
        guard case .identity(let identity) = RuntimeFileProbe.probe(url) else {
            throw EnvironmentError.missingFixtureExecutable
        }
        return RuntimeCommandResolution(
            command: try ExtractorRuntimeName(validating: command),
            source: .loginShell,
            executableURL: url,
            identity: identity,
            description: RuntimePathDescription(
                redactedPath: url.lastPathComponent,
                basename: url.lastPathComponent,
                fingerprint: "fixture"))
    }

    private init(
        root: URL,
        layout: ExtractorPackageStoreLayout,
        provider: ProcessExtractorProvider,
        locator: SpyRuntimeLocator,
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest
    ) {
        self.root = root
        self.layout = layout
        self.provider = provider
        self.locator = locator
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
