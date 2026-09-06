#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine
@testable import wikid
@testable import WikiFS

/// AC.9: both process hosts route `.applePodcast` through the same package
/// adapter and persist exact installed-package provenance with `.transcript`
/// origin and the immutable initial source-version link. The managed executor
/// is faked, so this exercises the REAL provider arms (URL validation,
/// prepared-operation execution, provenance, persistence) without `uv`, the
/// helper, or Apple's network.
@MainActor
@Suite("Apple queue extraction providers", .timeLimit(.minutes(2)))
struct AppleQueueExtractionProviderTests {

    private static let applePackage = ReviewedExtractorPackages.applePodcastTranscript
    private static let episodeURL =
        "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453"

    // MARK: - Fixtures

    /// Returns the transcript the fake "package process" wrote, and records
    /// the protocol request so tests can assert the validated source URL.
    private final class FakeAppleExecutor: ManagedProcessExecuting, @unchecked Sendable {
        let markdown = "SPEAKER_1: Hello from the episode."
        private(set) var lastRequest: ExtractorProtocolRequest?

        func execute(
            _ operation: ManagedExtractorProcessRequest,
            onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void
        ) async throws -> ManagedExtractorProcessResult {
            lastRequest = operation.protocolRequest
            let output = operation.paths.operationRoot
                .appendingPathComponent(operation.protocolRequest.outputPath.rawValue)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(markdown.utf8).write(to: output)
            let frame = ExtractorProtocolFrame.result(try ExtractorResultFrame(
                requestID: operation.protocolRequest.requestID,
                outputPath: operation.protocolRequest.outputPath,
                markdownByteCount: markdown.utf8.count,
                metadata: try ExtractorReportedMetadata(toolName: "apple-podcast-transcript")))
            return ManagedExtractorProcessResult(
                terminationCause: .exited(code: 0),
                terminalFrame: frame,
                progressEventCount: 1,
                standardOutputByteCount: 0,
                standardError: Data(),
                executableURL: operation.paths.packageRoot)
        }
    }

    /// The minimal manifest shape the prepared operation consumes.
    private static func manifest() throws -> ExtractorManifest {
        let json = """
        {
          "manifestRevision": 1,
          "packageID": "\(applePackage.packageID.rawValue)",
          "version": "1.0.0",
          "displayName": "Apple Podcast Transcript",
          "protocolRevision": 3,
          "entryPoint": "bin/apple-podcast-transcript-extractor",
          "launch": {"mode": "direct"},
          "registrations": [
            {
              "id": "apple-episode",
              "displayName": "Apple Podcasts Transcript",
              "kinds": ["apple-podcast-transcript"],
              "mimeTypes": ["audio/apple-podcast"]
            }
          ],
          "capabilities": ["network"],
          "files": [
            {
              "path": "bin/apple-podcast-transcript-extractor",
              "digest": "0000000000000000000000000000000000000000000000000000000000000000"
            }
          ],
          "limits": {
            "maximumInputByteCount": 1048576,
            "maximumMarkdownOutputByteCount": 33554432,
            "maximumDurationMilliseconds": 300000,
            "maximumProgressEventCount": 64
          }
        }
        """
        return try JSONDecoder().decode(ExtractorManifest.self, from: Data(json.utf8))
    }

    /// Builds one prepared Apple operation over a real (empty) operation
    /// directory tree and registers it in a fresh extraction registry.
    private func makeServices(executor: FakeAppleExecutor) async throws -> any ExtractionServices {
        let revision = Self.applePackage.revision
        let manifest = try Self.manifest()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-apple-queue-\(UUID().uuidString)", isDirectory: true)
        for sub in ["", "input", "output", "home", "tmp", "cache"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let registrationID = try ExtractorRegistrationID(validating: "apple-episode")
        let registration = try ExtractorRegistration(
            id: registrationID,
            displayName: "Apple Podcasts Transcript",
            kinds: [.applePodcastTranscript],
            mimeTypes: [try ExtractorMIMEType(validating: MimeType.audioApplePodcast)],
            filenameExtensions: [])
        let operation = PreparedProcessOperation(
            directoryRoot: root,
            packageRoot: root.appendingPathComponent("package", isDirectory: true),
            homeRoot: root.appendingPathComponent("home", isDirectory: true),
            temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true),
            cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
            sharedRuntimeCacheRoot: nil,
            sharedModelCacheRoot: nil,
            revision: revision,
            manifest: manifest,
            registration: registration,
            registrationID: registrationID,
            protocolRevision: .v3,
            mimeTypes: [MimeType.audioApplePodcast],
            executor: executor,
            launchGate: nil,
            operationCredentials: nil,
            operationConfiguration: nil,
            runtimeResolution: nil)

        let registry = ExtractionBackendRegistry()
        let reference = ExtractorReference(revision: revision, registrationID: registrationID)
        let adapterKey = ExtractionAdapterKey.installed(
            kind: .applePodcastTranscript, reference: reference)
        _ = try await registry.register(
            RegisteredExtractionBackend(
                key: ExtractionBackendKey(kind: .applePodcastTranscript, backendID: "placeholder")
            ) {
                .applePodcastTranscript(
                    ProcessPackageApplePodcastTranscript(operation: operation))
            },
            key: adapterKey)
        return StubAppleExtractionServices(registry: registry, adapterKey: adapterKey)
    }

    /// Only the Apple prepare seam is overridden; everything else inherits
    /// the protocol defaults (unavailable), which the Apple arm never calls.
    private struct StubAppleExtractionServices: ExtractionServices {
        let registry: ExtractionBackendRegistry
        let adapterKey: ExtractionAdapterKey

        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw ExtractionServicesError.unavailable
        }

        func prepareApplePodcastTranscript() async throws -> ProcessPackageApplePodcastTranscript {
            // Resolve through the registry exactly like the process facade.
            guard let backend = await registry.resolve(adapterKey) else {
                throw ExtractionServicesError.unavailable
            }
            let adapter = try await backend.make()
            guard case .applePodcastTranscript(let prepared) = adapter else {
                throw ExtractionServicesError.unavailable
            }
            return prepared
        }

        func registeredExtractionInputs() async -> RegisteredExtractionInputs {
            .none
        }
    }

    private func makeStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
    }

    /// Seeds one byteless Apple episode source and returns its ID.
    private func seedAppleSource(_ store: GRDBWikiStore) throws -> SourceID {
        let summary = try store.addBytelessSource(
            filename: "chinatalk-1000774368453",
            mimeType: "audio/apple-podcast",
            provenance: SourceProvenance(
                agentName: SourceProvider.applePodcast.rawValue,
                activityKind: "fetch",
                plan: Self.episodeURL,
                externalRef: Self.episodeURL,
                externalIdentity: "1000774368453"),
            role: .primary)
        return summary.id
    }

    // MARK: - App provider (AC.9)

    @Test func appProviderResolvesAppleThroughPackageAndPersistsProvenance() async throws {
        let store = try makeStore()
        let sourceID = try seedAppleSource(store)
        let model = WikiStoreModel(store: store)
        let executor = FakeAppleExecutor()

        let box = SessionLookupBox()
        box.setLookup { _ in model }
        let provider = AppQueueExtractionProvider(
            extractionServices: try await makeServices(executor: executor),
            sessionBox: box)

        // Resolution runs the package arm with the validated episode URL.
        let resolution = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil)
        guard case .transcript(let transcript)? = resolution else {
            Issue.record("expected a transcript resolution")
            return
        }
        guard case .installedPackage(let producer) = transcript.resultMode else {
            Issue.record("expected installedPackage result mode")
            return
        }
        #expect(producer.revision == Self.applePackage.revision)
        #expect(producer.registrationID.rawValue == "apple-episode")
        #expect(producer.protocolRevision == .v3)
        // The package workflow never ran here, but the request the executor
        // received carried the validated remote URL.
        _ = try await transcript.fetch { _ in }
        #expect(executor.lastRequest?.remoteURL?.rawValue == Self.episodeURL)
        #expect(executor.lastRequest?.kind == .applePodcastTranscript)

        // Persistence: exact provenance, transcript origin, initial v1 link.
        let outcome = TranscriptFetchOutcome(
            markdown: "SPEAKER_1: Hello from the episode.",
            reportedMetadata: try ExtractorReportedMetadata(toolName: "apple-podcast-transcript"))
        try await provider.persistTranscriptExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: transcript, outcome: outcome)

        let head = try #require(try store.processedMarkdownHead(sourceID: sourceID))
        #expect(head.origin == .transcript)
        #expect(head.content == outcome.markdown)
        let initialV1 = try #require(
            try store.contentVersionHistory(sourceID: sourceID)
                .first(where: { $0.parentID == nil }))
        #expect(head.sourceVersionID == initialV1.id)
        let provenance = try #require(
            try store.extractionProvenance(markdownVersionID: head.id))
        #expect(provenance.origin == .transcript)
        guard case .installedPackage(let persisted) = provenance.producer else {
            Issue.record("expected installed-package producer")
            return
        }
        #expect(persisted.revision == Self.applePackage.revision)
        #expect(persisted.reportedMetadata.toolName == "apple-podcast-transcript")
    }

    // MARK: - Daemon provider (AC.9)

    @Test func daemonProviderResolvesAppleThroughPackageAndPersistsProvenance() async throws {
        let store = try makeStore()
        let sourceID = try seedAppleSource(store)
        let executor = FakeAppleExecutor()

        let provider = DaemonQueueExtractionProvider(
            extractionServices: try await makeServices(executor: executor),
            storeResolver: { _ in store })

        let resolution = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil)
        guard case .transcript(let transcript)? = resolution,
              case .installedPackage = transcript.resultMode else {
            Issue.record("expected an installedPackage transcript resolution")
            return
        }
        let outcome = try await transcript.fetch { _ in }
        try await provider.persistTranscriptExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: transcript, outcome: outcome)

        let head = try #require(try store.processedMarkdownHead(sourceID: sourceID))
        #expect(head.origin == .transcript)
        let initialV1 = try #require(
            try store.contentVersionHistory(sourceID: sourceID)
                .first(where: { $0.parentID == nil }))
        #expect(head.sourceVersionID == initialV1.id)
    }

    // MARK: - Invalid URLs fail closed (AC.5's front door)

    @Test func nonApplePlanURLYieldsNoResolution() async throws {
        let store = try makeStore()
        // A `.applePodcast` origin whose plan is not a valid remote URL.
        let summary = try store.addBytelessSource(
            filename: "bad-episode",
            mimeType: "audio/apple-podcast",
            provenance: SourceProvenance(
                agentName: SourceProvider.applePodcast.rawValue,
                activityKind: "fetch",
                plan: "not a url",
                externalRef: "not a url",
                externalIdentity: "1"),
            role: .primary)
        let model = WikiStoreModel(store: store)
        let box = SessionLookupBox()
        box.setLookup { _ in model }
        let provider = AppQueueExtractionProvider(
            extractionServices: try await makeServices(executor: FakeAppleExecutor()),
            sessionBox: box)

        let resolution = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: summary.id, backendOverride: nil)
        #expect(resolution == nil)
    }
}
#endif
