#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine
@testable import wikid
@testable import WikiFS

/// Both process hosts route `.youtube` through the same package adapter and
/// persist exact installed-package provenance with `.transcript` origin and
/// the immutable initial source-version link. The managed executor is faked,
/// so this exercises the REAL provider arms (URL resolution including the
/// legacy video-ID fallback, prepared-operation execution, provenance,
/// persistence) without `uv` or YouTube's network.
@MainActor
@Suite("YouTube queue extraction providers", .timeLimit(.minutes(2)))
struct YouTubeQueueExtractionProviderTests {

    private static let youtubePackage = ReviewedExtractorPackages.youtubeTranscript
    private static let watchURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    private static let videoID = "dQw4w9WgXcQ"

    // MARK: - Fixtures

    /// Returns the transcript the fake "package process" wrote, and records
    /// the protocol request so tests can assert the validated source URL.
    private final class FakeYouTubeExecutor: ManagedProcessExecuting, @unchecked Sendable {
        let markdown = "Hello from the captions."
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
                metadata: try ExtractorReportedMetadata(
                    toolName: "youtube-transcript",
                    language: "en",
                    transcriptGenerated: false)))
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
          "packageID": "org.selfdrivingwiki.youtube-transcript",
          "version": "1.0.0",
          "displayName": "YouTube Transcript",
          "protocolRevision": 3,
          "entryPoint": "bin/youtube-transcript-extractor",
          "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
          "registrations": [
            {
              "id": "captions",
              "displayName": "YouTube Transcript",
              "kinds": ["youtube-transcript"],
              "mimeTypes": ["video/youtube"]
            }
          ],
          "capabilities": ["network"],
          "files": [
            {
              "path": "bin/youtube-transcript-extractor",
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

    /// Builds one prepared YouTube operation over a real (empty) operation
    /// directory tree and registers it in a fresh extraction registry.
    private func makeServices(executor: FakeYouTubeExecutor) async throws -> any ExtractionServices {
        let revision = Self.youtubePackage.revision
        let manifest = try Self.manifest()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-youtube-queue-\(UUID().uuidString)", isDirectory: true)
        for sub in ["", "input", "output", "home", "tmp", "cache"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let registrationID = try ExtractorRegistrationID(validating: "captions")
        let registration = try ExtractorRegistration(
            id: registrationID,
            displayName: "YouTube Transcript",
            kinds: [.youtubeTranscript],
            mimeTypes: [try ExtractorMIMEType(validating: MimeType.videoYouTube)],
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
            mimeTypes: [MimeType.videoYouTube],
            executor: executor,
            launchGate: nil,
            operationCredentials: nil,
            operationConfiguration: nil,
            runtimeResolution: nil)

        let registry = ExtractionBackendRegistry()
        let reference = ExtractorReference(revision: revision, registrationID: registrationID)
        let adapterKey = ExtractionAdapterKey.installed(
            kind: .youtubeTranscript, reference: reference)
        _ = try await registry.register(
            RegisteredExtractionBackend(
                key: ExtractionBackendKey(kind: .youtubeTranscript, backendID: "placeholder")
            ) {
                .youtubeTranscript(
                    ProcessPackageYouTubeTranscript(operation: operation))
            },
            key: adapterKey)
        return StubYouTubeExtractionServices(registry: registry, adapterKey: adapterKey)
    }

    /// Only the YouTube prepare seam is overridden; everything else inherits
    /// the protocol defaults (unavailable), which the YouTube arm never calls.
    private struct StubYouTubeExtractionServices: ExtractionServices {
        let registry: ExtractionBackendRegistry
        let adapterKey: ExtractionAdapterKey

        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw ExtractionServicesError.unavailable
        }

        func prepareYouTubeTranscript() async throws -> ProcessPackageYouTubeTranscript {
            // Resolve through the registry exactly like the process facade.
            guard let backend = await registry.resolve(adapterKey) else {
                throw ExtractionServicesError.unavailable
            }
            let adapter = try await backend.make()
            guard case .youtubeTranscript(let prepared) = adapter else {
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

    /// Seeds one byteless YouTube source and returns its ID.
    private func seedYouTubeSource(
        _ store: GRDBWikiStore,
        plan: String? = Self.watchURL,
        externalIdentity: String? = Self.videoID
    ) throws -> SourceID {
        let summary = try store.addBytelessSource(
            filename: "youtube-\(externalIdentity ?? "row")",
            mimeType: MimeType.videoYouTube,
            provenance: SourceProvenance(
                agentName: SourceProvider.youtube.rawValue,
                activityKind: "fetch",
                plan: plan,
                externalRef: plan,
                externalIdentity: externalIdentity),
            role: .primary)
        return summary.id
    }

    // MARK: - App provider

    @Test func appProviderResolvesYouTubeThroughPackageAndPersistsProvenance() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store)
        let model = WikiStoreModel(store: store)
        let executor = FakeYouTubeExecutor()

        let box = SessionLookupBox()
        box.setLookup { _ in model }
        let provider = AppQueueExtractionProvider(
            extractionServices: try await makeServices(executor: executor),
            sessionBox: box)

        // Resolution runs the package arm with the stored watch URL.
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
        #expect(producer.revision == Self.youtubePackage.revision)
        #expect(producer.registrationID.rawValue == "captions")
        #expect(producer.protocolRevision == .v3)
        let outcome = try await transcript.fetch { _ in }
        #expect(executor.lastRequest?.remoteURL?.rawValue == Self.watchURL)
        #expect(executor.lastRequest?.kind == .youtubeTranscript)
        #expect(outcome.reportedMetadata.language == "en")
        #expect(outcome.reportedMetadata.transcriptGenerated == false)

        // Persistence: exact provenance, transcript origin, initial v1 link.
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
        #expect(persisted.revision == Self.youtubePackage.revision)
        #expect(persisted.reportedMetadata.toolName == "youtube-transcript")
        #expect(persisted.reportedMetadata.language == "en")
    }

    // MARK: - Daemon provider

    @Test func daemonProviderResolvesYouTubeThroughPackageAndPersistsProvenance() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store)
        let executor = FakeYouTubeExecutor()

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
        #expect(executor.lastRequest?.kind == .youtubeTranscript)
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

    // MARK: - Source URL contracts (AC.7)

    /// A Shorts plan URL passes through unchanged: watch, `youtu.be`, Shorts,
    /// and embed rows keep their original source contract.
    @Test func shortsPlanURLPassesThroughUnchanged() async throws {
        let store = try makeStore()
        let shortsURL = "https://www.youtube.com/shorts/dQw4w9WgXcQ"
        let sourceID = try seedYouTubeSource(store, plan: shortsURL, externalIdentity: Self.videoID)
        let executor = FakeYouTubeExecutor()

        let box = SessionLookupBox()
        box.setLookup { _ in WikiStoreModel(store: store) }
        let provider = AppQueueExtractionProvider(
            extractionServices: try await makeServices(executor: executor),
            sessionBox: box)

        guard case .transcript(let transcript)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil) else {
            Issue.record("expected a transcript resolution")
            return
        }
        _ = try await transcript.fetch { _ in }
        #expect(executor.lastRequest?.remoteURL?.rawValue == shortsURL)
    }

    /// A legacy row with a valid video ID but no usable plan URL resolves to
    /// the canonical watch URL at the external-format boundary.
    @Test func legacyRowWithOnlyIdentityResolvesToCanonicalWatchURL() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store, plan: "not a url", externalIdentity: Self.videoID)
        let executor = FakeYouTubeExecutor()

        let box = SessionLookupBox()
        box.setLookup { _ in WikiStoreModel(store: store) }
        let provider = AppQueueExtractionProvider(
            extractionServices: try await makeServices(executor: executor),
            sessionBox: box)

        guard case .transcript(let transcript)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil) else {
            Issue.record("expected a transcript resolution for the legacy row")
            return
        }
        _ = try await transcript.fetch { _ in }
        #expect(executor.lastRequest?.remoteURL?.rawValue == Self.watchURL)
    }

    /// Invalid or missing data yields NO resolution, and the executor is
    /// never invoked — invalid legacy data never launches a package.
    @Test func invalidLegacyDataNeverInvokesTheExecutor() async throws {
        let store = try makeStore()
        for (plan, identity) in [
            (nil, nil),
            (nil, "bad id"),
            ("not a url", "bad id"),
            ("https://example.com/watch?v=dQw4w9WgXcQ", nil),
        ] {
            let sourceID = try seedYouTubeSource(store, plan: plan, externalIdentity: identity)
            let executor = FakeYouTubeExecutor()

            let box = SessionLookupBox()
            box.setLookup { _ in WikiStoreModel(store: store) }
            let provider = AppQueueExtractionProvider(
                extractionServices: try await makeServices(executor: executor),
                sessionBox: box)

            let resolution = try await provider.resolveExtraction(
                wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil)
            #expect(resolution == nil, "plan=\(plan ?? "nil") identity=\(identity ?? "nil")")
            #expect(executor.lastRequest == nil)
        }
    }
}
#endif
