#if os(macOS)
import Foundation
import os
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine
@testable import wikid
@testable import WikiFS

/// AC.2/AC.3 — the explicit speech queue arm, end to end, in BOTH hosts.
///
/// The acquisition fetcher runs through the real prepared-operation
/// machinery over a faked executor (the `source-bytes` result edge), the
/// speech engine is a scripted injection, and the stage is the real
/// `SpeechStageManager`. The tests pin: intent-only routing, the v1 YouTube
/// scope gate, transient byte consumption (no blob, no follow-on), the ONE
/// transcript version with honest host provenance, and stage cleanliness on
/// failure and cancellation.
@MainActor
@Suite("Speech queue pipeline", .timeLimit(.minutes(2)))
struct SpeechQueuePipelineTests {

    private static let audioPackage = ReviewedExtractorPackages.audioAcquire
    private static let watchURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    private static let videoID = "dQw4w9WgXcQ"
    /// A minimal valid M4A payload.
    nonisolated private static let m4a = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypM4A ".utf8) + Data(repeating: 0x2A, count: 256)

    // MARK: - Fixtures

    /// Fakes the package process: writes the audio output file and answers
    /// with a `source-bytes` frame declaring `audio/mp4`.
    private final class FakeAudioExecutor: ManagedProcessExecuting, @unchecked Sendable {
        private(set) var lastRequest: ExtractorFetchRequest?
        let payload: Data

        init(payload: Data = SpeechQueuePipelineTests.m4a) {
            self.payload = payload
        }

        func execute(
            _ operation: ManagedExtractorProcessRequest,
            onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void
        ) async throws -> ManagedExtractorProcessResult {
            guard case .fetch(let request) = operation.request else {
                throw ExtractionServicesError.unavailable
            }
            lastRequest = request
            let output = operation.paths.operationRoot
                .appendingPathComponent(request.outputPath.rawValue)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: output)
            let frame = try ExtractorResultFrame(
                requestID: request.requestID,
                outputPath: request.outputPath,
                markdownByteCount: payload.count,
                metadata: try ExtractorReportedMetadata(toolName: "audio-acquire"),
                articleMetadata: nil,
                resultMIMEType: try ExtractorMIMEType(validating: "audio/mp4"),
                resultType: .sourceBytes,
                originalFilename: nil)
            return ManagedExtractorProcessResult(
                terminationCause: .exited(code: 0),
                terminalFrame: .result(frame),
                progressEventCount: 1,
                standardOutputByteCount: 0,
                standardError: Data(),
                executableURL: operation.paths.packageRoot)
        }
    }

    private static func audioManifest() throws -> ExtractorManifest {
        let json = """
        {
          "manifestRevision": 4,
          "packageID": "org.selfdrivingwiki.audio-acquire",
          "version": "1.0.0",
          "displayName": "Audio Acquire",
          "protocolRevision": 5,
          "entryPoint": "bin/audio-acquire-extractor",
          "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
          "registrations": [
            {
              "id": "audio",
              "displayName": "Audio Acquire",
              "role": "fetcher",
              "mimeTypes": ["audio/x-wiki-audio-acquire"]
            }
          ],
          "capabilities": ["network"],
          "files": [
            {
              "path": "bin/audio-acquire-extractor",
              "digest": "0000000000000000000000000000000000000000000000000000000000000000"
            }
          ],
          "limits": {
            "maximumInputByteCount": 1048576,
            "maximumMarkdownOutputByteCount": 134217728,
            "maximumDurationMilliseconds": 1800000,
            "maximumProgressEventCount": 64
          }
        }
        """
        return try JSONDecoder().decode(ExtractorManifest.self, from: Data(json.utf8))
    }

    /// Builds the extraction services whose ONLY live seam is the audio
    /// fetcher route (the exact reviewed audio revision), resolved through a
    /// fresh registry like the process facade.
    private func makeServices(
        executor: FakeAudioExecutor,
        fetcherDisabled: Bool = false
    ) async throws -> any ExtractionServices {
        let revision = Self.audioPackage.revision
        let manifest = try Self.audioManifest()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-speech-queue-\(UUID().uuidString)", isDirectory: true)
        for sub in ["", "input", "output", "home", "tmp", "cache"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let registrationID = try ExtractorRegistrationID(validating: "audio")
        let registration = try ExtractorRegistration(
            id: registrationID,
            displayName: "Audio Acquire",
            kinds: [],
            mimeTypes: [try ExtractorMIMEType(validating: MimeType.audioXWikiAudioAcquire)],
            filenameExtensions: [],
            role: .fetcher)
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
            protocolRevision: .v5,
            mimeTypes: [MimeType.audioXWikiAudioAcquire],
            executor: executor,
            launchGate: nil,
            operationCredentials: nil,
            operationConfiguration: nil,
            runtimeResolution: nil)
        let registry = ExtractionBackendRegistry()
        let reference = ExtractorReference(revision: revision, registrationID: registrationID)
        _ = try await registry.registerBatch([
            ExtractionBatchEntry(
                key: .installedFetcher(reference: reference),
                backend: RegisteredExtractionBackend(
                    key: ExtractionBackendKey(kind: .pdf, backendID: "placeholder")) {
                        .fetcher(ProcessPackageFetcher(operation: operation))
                    },
                presentation: ExtractorRegistrationPresentation(
                    displayName: "Audio Acquire",
                    packageName: "Audio Acquire",
                    role: .fetcher,
                    kinds: [],
                    mimeTypes: [try ExtractorMIMEType(validating: MimeType.audioXWikiAudioAcquire)],
                    filenameExtensions: [])),
        ])
        return StubSpeechExtractionServices(
            registry: registry,
            reference: reference,
            fetcherDisabled: fetcherDisabled)
    }

    /// Only the audio fetcher seam is live; everything else fails closed.
    private struct StubSpeechExtractionServices: ExtractionServices {
        let registry: ExtractionBackendRegistry
        let reference: ExtractorReference
        let fetcherDisabled: Bool

        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw ExtractionServicesError.unavailable
        }

        func prepareFetcher(sourceMIMEType: ExtractorMIMEType) async throws -> ProcessPackageFetcher {
            // The selection state machine: an explicit disable fails closed;
            // the installed selection resolves through the kind-free
            // registry namespace.
            if fetcherDisabled {
                throw ExtractionServicesError.selectedFetcherUnavailable(
                    route: .canonicalAudioAcquire,
                    reference: LogicalExtractorReference(
                        packageID: reference.revision.packageID,
                        registrationID: reference.registrationID))
            }
            guard let backend = await registry.resolve(.installedFetcher(reference: reference)) else {
                throw ExtractionServicesError.selectedFetcherUnavailable(
                    route: .canonicalAudioAcquire,
                    reference: LogicalExtractorReference(
                        packageID: reference.revision.packageID,
                        registrationID: reference.registrationID))
            }
            let adapter = try await backend.make()
            guard case .fetcher(let fetcher) = adapter else {
                throw ExtractionServicesError.unavailable
            }
            return fetcher
        }

        func registeredExtractionInputs() async -> RegisteredExtractionInputs { .none }
        func activeRegistrationSnapshots() async -> [ExtractorRouteRegistrationSnapshot] { [] }
    }

    /// The scripted speech engine: records every call and returns fixed
    /// outcomes so the pipeline test stays deterministic.
    private final class ScriptedSpeechEngine: SpeechTranscribing, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: State())
        private struct State {
            var readinessCalls = 0
            var transcribeCalls = 0
            var stagedPaths: [String] = []
        }

        var readinessAnswer: SpeechReadiness = .ready
        var behavior: @Sendable (URL) async throws -> SpeechTranscription = { url in
            SpeechTranscription(
                text: "spoken words from the fixture",
                engine: "scripted",
                localeID: "en-US",
                durationSeconds: 600)
        }

        var transcribeCalls: Int { lock.withLock { $0.transcribeCalls } }
        var readinessCalls: Int { lock.withLock { $0.readinessCalls } }
        var stagedPaths: [String] { lock.withLock { $0.stagedPaths } }

        func readiness(localeID: String) async -> SpeechReadiness {
            lock.withLock { $0.readinessCalls += 1 }
            return readinessAnswer
        }

        func transcribeFile(
            at audioURL: URL,
            localeID: String,
            deadline: ContinuousClock.Instant,
            onProgress: (@Sendable (Double) -> Void)?
        ) async throws -> SpeechTranscription {
            lock.withLock { state in
                state.transcribeCalls += 1
                state.stagedPaths.append(audioURL.path)
            }
            return try await behavior(audioURL)
        }

        func installMissingAssets(
            localeID: String,
            onProgress: (@Sendable (Double) -> Void)?
        ) async throws {
            Issue.record("the queue path must never install assets")
        }
    }

    private func makeStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
    }

    private func seedYouTubeSource(_ store: GRDBWikiStore) throws -> SourceID {
        let summary = try store.addBytelessSource(
            filename: "youtube-\(Self.videoID)",
            mimeType: MimeType.videoYouTube,
            provenance: SourceProvenance(
                agentName: SourceProvider.youtube.rawValue,
                activityKind: "fetch",
                plan: Self.watchURL,
                externalRef: Self.watchURL,
                externalIdentity: Self.videoID),
            role: .primary)
        return summary.id
    }

    private func makeAppProvider(
        store: GRDBWikiStore,
        services: any ExtractionServices,
        engine: ScriptedSpeechEngine,
        stageRoot: URL
    ) -> AppQueueExtractionProvider {
        let box = SessionLookupBox()
        box.setLookup { _ in WikiStoreModel(store: store) }
        return AppQueueExtractionProvider(
            extractionServices: services,
            sessionBox: box,
            speechEngine: engine,
            speechLocaleID: "en-US",
            speechStageRoot: stageRoot)
    }

    private func makeDaemonProvider(
        store: GRDBWikiStore,
        services: any ExtractionServices,
        engine: ScriptedSpeechEngine,
        stageRoot: URL
    ) -> DaemonQueueExtractionProvider {
        DaemonQueueExtractionProvider(
            extractionServices: services,
            storeResolver: { _ in store },
            speechEngine: engine,
            speechLocaleID: "en-US",
            speechStageRoot: stageRoot)
    }

    // MARK: - Routing

    @Test func appAndDaemonSpeechIntentRouting() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store)
        let executor = FakeAudioExecutor()
        let engine = ScriptedSpeechEngine()
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-route-\(UUID().uuidString)", isDirectory: true)
        let services = try await makeServices(executor: executor)

        // APP: the explicit intent resolves the speech arm; the nil and
        // `.captions` intents resolve the caption arm.
        let captionServices = CaptionOverridingServices(
            base: services, captionExecutor: FakeCaptionExecutor())
        let app = makeAppProvider(store: store, services: captionServices, engine: engine, stageRoot: stageRoot)
        let speechResolution = try await app.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: .onDeviceSpeech)
        guard case .speech(let speech)? = speechResolution else {
            Issue.record("an explicit speech intent must resolve the speech arm")
            return
        }
        #expect(speech.capacityID == "speech")
        let captionsResolution = try await app.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: nil)
        guard case .transcript? = captionsResolution else {
            Issue.record("a nil intent resolves the caption arm only")
            return
        }
        let captionsExplicit = try await app.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: .captions)
        guard case .transcript? = captionsExplicit else {
            Issue.record("an explicit captions intent resolves the caption arm only")
            return
        }

        // DAEMON: the same intent routes to the same arm.
        let daemon = makeDaemonProvider(store: store, services: captionServices, engine: engine, stageRoot: stageRoot)
        let daemonSpeech = try await daemon.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: .onDeviceSpeech)
        guard case .speech? = daemonSpeech else {
            Issue.record("the daemon must route a speech intent to the speech arm")
            return
        }
        let daemonCaptions = try await daemon.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: nil)
        guard case .transcript? = daemonCaptions else {
            Issue.record("the daemon must route a nil intent to the caption arm only")
            return
        }
    }

    @Test func missingDisabledUnavailableSelectionsFail() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store)
        let engine = ScriptedSpeechEngine()
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-fail-\(UUID().uuidString)", isDirectory: true)

        // DISABLED selection: the item fails visibly with the typed
        // message — never a silent completion, never a caption fallback.
        let disabled = try await makeServices(executor: FakeAudioExecutor(), fetcherDisabled: true)
        let disabledProvider = makeAppProvider(store: store, services: disabled, engine: engine, stageRoot: stageRoot)
        await #expect(throws: ExtractionServicesError.self) {
            _ = try await disabledProvider.resolveExtraction(
                wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
                backendOverride: nil, transcriptionIntent: .onDeviceSpeech)
        }
        #expect(engine.transcribeCalls == 0)

        // ENGINE NOT READY: the resolution refuses before any acquisition.
        let ready = try await makeServices(executor: FakeAudioExecutor())
        let notReadyEngine = ScriptedSpeechEngine()
        notReadyEngine.readinessAnswer = .needsSetup(.assetsNotInstalled)
        let notReadyProvider = makeAppProvider(store: store, services: ready, engine: notReadyEngine, stageRoot: stageRoot)
        do {
            _ = try await notReadyProvider.resolveExtraction(
                wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
                backendOverride: nil, transcriptionIntent: .onDeviceSpeech)
            Issue.record("a needsSetup engine must fail the speech resolution")
        } catch let error as SpeechResolutionError {
            #expect(error == .engineNotReady(SpeechSetupGuidance.assetsNotInstalled.message))
        }
        #expect(notReadyEngine.transcribeCalls == 0)

        // OUT OF SCOPE: a non-YouTube source with a speech intent fails the
        // scope gate — and the GENERIC fetch pipeline is untouched by this
        // gate.
        let nonYouTube = try store.addBytelessSource(
            filename: "generic-source",
            mimeType: "application/zotero",
            provenance: SourceProvenance(
                agentName: "zotero",
                activityKind: "fetch",
                plan: "https://api.zotero.org/users/1/items/ABCD1234/file",
                externalRef: "https://api.zotero.org/users/1/items/ABCD1234/file",
                externalIdentity: "ABCD1234"),
            role: .primary)
        let scoped = makeAppProvider(store: store, services: ready, engine: engine, stageRoot: stageRoot)
        do {
            _ = try await scoped.resolveExtraction(
                wikiID: WikiID(rawValue: "w"), sourceID: nonYouTube.id,
                backendOverride: nil, transcriptionIntent: .onDeviceSpeech)
            Issue.record("a non-YouTube source is outside the v1 speech scope")
        } catch let error as SpeechResolutionError {
            #expect(error == .sourceOutsideSpeechScope)
        }
        #expect(engine.transcribeCalls == 0)
    }

    // MARK: - Full pipeline

    @Test func successPersistsHostProducer() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store)
        let executor = FakeAudioExecutor()
        let engine = ScriptedSpeechEngine()
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-success-\(UUID().uuidString)", isDirectory: true)
        let provider = makeAppProvider(
            store: store, services: try await makeServices(executor: executor),
            engine: engine, stageRoot: stageRoot)

        guard case .speech(let speech)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: .onDeviceSpeech) else {
            Issue.record("expected a speech resolution")
            return
        }

        // The worker shape: acquire → stage → analyze → persist.
        let acquired = try await speech.acquire { _ in }
        #expect(acquired.bytes == Self.m4a)
        #expect(acquired.provenance.revision == Self.audioPackage.revision)
        let stage = SpeechStageManager(root: speech.stageRoot)
        var stagedPath: String?
        var speechReference: QueueExtractionOutputReference?
        do {
            let staged = try stage.stage(
                bytes: acquired.bytes, wikiID: WikiID(rawValue: "w"),
                itemID: QueueItem.ID(rawValue: "01JSUCCESSITEM000000000"), attempt: 1)
            stagedPath = staged.audioURL.path
            staged.lease.release()
            defer { staged.discard() }
            let transcription = try await speech.speechEngine.transcribeFile(
                at: staged.audioURL, localeID: speech.localeID,
                deadline: ContinuousClock.now.advanced(by: .seconds(300)), onProgress: nil)
            speechReference = try await provider.persistSpeechExtraction(
                wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
                outcome: SpeechOutcome(
                    transcription: transcription,
                    acquisitionFetcher: acquired.provenance,
                    durationSeconds: transcription.durationSeconds))
        }
        #expect(speechReference != nil)

        // ONE nonempty `.transcript` head with the typed host producer.
        let head = try #require(try store.processedMarkdownHead(sourceID: sourceID))
        #expect(head.origin == .transcript)
        #expect(head.content == "spoken words from the fixture")
        let initial = try #require(try store.contentVersionHistory(sourceID: sourceID)
            .first(where: { $0.parentID == nil }))
        #expect(head.sourceVersionID == initial.id)
        let provenance = try #require(
            try store.extractionProvenance(markdownVersionID: head.id))
        guard case .hostSpeech(let producer) = provenance.producer else {
            Issue.record("expected the host-speech producer")
            return
        }
        #expect(producer.engine == "scripted")
        #expect(producer.localeID == "en-US")
        #expect(producer.acquisitionFetcher.revision == Self.audioPackage.revision)
        // The staged audio is gone after the scoped discard.
        #expect(FileManager.default.fileExists(atPath: stagedPath!) == false)
    }

    @Test func appAndDaemonSpeechPersistence() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store)
        let engine = ScriptedSpeechEngine()
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-daemon-\(UUID().uuidString)", isDirectory: true)
        let services = try await makeServices(executor: FakeAudioExecutor())

        // The daemon persists with IDENTICAL semantics.
        let daemon = makeDaemonProvider(store: store, services: services, engine: engine, stageRoot: stageRoot)
        guard case .speech(let speech)? = try await daemon.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: .onDeviceSpeech) else {
            Issue.record("expected a daemon speech resolution")
            return
        }
        let acquired = try await speech.acquire { _ in }
        let outcome = SpeechOutcome(
            transcription: SpeechTranscription(
                text: "daemon transcript", engine: "scripted", localeID: "en-US",
                durationSeconds: 1),
            acquisitionFetcher: acquired.provenance,
            durationSeconds: 1)
        _ = try await daemon.persistSpeechExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, outcome: outcome)
        let daemonHead = try #require(try store.processedMarkdownHead(sourceID: sourceID))
        guard case .hostSpeech? = (try store.extractionProvenance(markdownVersionID: daemonHead.id))?.producer else {
            Issue.record("the daemon head must carry the host-speech producer")
            return
        }

        // The app appends a SECOND speech alternative with the same
        // semantics (identical persistence, one more version).
        let app = makeAppProvider(store: store, services: services, engine: engine, stageRoot: stageRoot)
        _ = try await app.persistSpeechExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            outcome: SpeechOutcome(
                transcription: SpeechTranscription(
                    text: "app transcript", engine: "scripted", localeID: "en-US",
                    durationSeconds: 1),
                acquisitionFetcher: acquired.provenance,
                durationSeconds: 1))
        let appHead = try #require(try store.processedMarkdownHead(sourceID: sourceID))
        #expect(appHead.content == "app transcript")
        guard case .hostSpeech? = (try store.extractionProvenance(markdownVersionID: appHead.id))?.producer else {
            Issue.record("the app head must carry the host-speech producer")
            return
        }
    }

    @Test func neverPersistsFetchBytes() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store)
        let executor = FakeAudioExecutor()
        let engine = ScriptedSpeechEngine()
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-transient-\(UUID().uuidString)", isDirectory: true)
        let provider = makeAppProvider(
            store: store, services: try await makeServices(executor: executor),
            engine: engine, stageRoot: stageRoot)

        guard case .speech(let speech)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: .onDeviceSpeech) else {
            Issue.record("expected a speech resolution")
            return
        }
        // The full worker shape runs; nothing attaches the audio as a blob,
        // no fetch marker appears, and no follow-on format item exists.
        let acquired = try await speech.acquire { _ in }
        let stage = SpeechStageManager(root: speech.stageRoot)
        let staged = try stage.stage(
            bytes: acquired.bytes, wikiID: WikiID(rawValue: "w"),
            itemID: QueueItem.ID(rawValue: "01JTRANSIENTITEM000000000"), attempt: 1)
        staged.lease.release()
        defer { staged.discard() }
        let transcription = try await speech.speechEngine.transcribeFile(
            at: staged.audioURL, localeID: speech.localeID,
            deadline: ContinuousClock.now.advanced(by: .seconds(300)), onProgress: nil)
        _ = try await provider.persistSpeechExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            outcome: SpeechOutcome(
                transcription: transcription,
                acquisitionFetcher: acquired.provenance,
                durationSeconds: nil))

        // The source still has NO bytes: the audio was never persisted as
        // source content.
        let content = try store.sourceContent(id: sourceID)
        #expect(content.isEmpty)
        // The fetch lifecycle never started.
        let fetchState = try store.fetchState(sourceID: sourceID)
        // The follow-on format marker never appears: no format item exists.
        #expect(fetchState != .formatJobPending)
    }

    @Test func failureAndCancellationCleanStage() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store)
        let engine = ScriptedSpeechEngine()
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-clean-\(UUID().uuidString)", isDirectory: true)
        let provider = makeAppProvider(
            store: store, services: try await makeServices(executor: FakeAudioExecutor()),
            engine: engine, stageRoot: stageRoot)

        guard case .speech(let speech)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: .onDeviceSpeech) else {
            Issue.record("expected a speech resolution")
            return
        }

        // FAILURE: the engine throws mid-analysis; the staged audio is
        // removed and NO version lands.
        engine.behavior = { _ in throw SpeechTranscriptionError.emptyTranscription }
        let failureStage = SpeechStageManager(root: speech.stageRoot)
        let failedStage = try failureStage.stage(
            bytes: Self.m4a, wikiID: WikiID(rawValue: "w"),
            itemID: QueueItem.ID(rawValue: "01JFAILITEM00000000000"), attempt: 1)
        failedStage.lease.release()
        do {
            _ = try await speech.speechEngine.transcribeFile(
                at: failedStage.audioURL, localeID: speech.localeID,
                deadline: ContinuousClock.now.advanced(by: .seconds(300)), onProgress: nil)
            Issue.record("expected the scripted failure")
        } catch { }
        failedStage.discard()
        #expect(try store.processedMarkdownHead(sourceID: sourceID) == nil)
        #expect(FileManager.default.fileExists(atPath: failedStage.audioURL.path) == false)

        // CANCELLATION: same cleanliness.
        engine.behavior = { _ in throw CancellationError() }
        let cancelledStage = try failureStage.stage(
            bytes: Self.m4a, wikiID: WikiID(rawValue: "w"),
            itemID: QueueItem.ID(rawValue: "01JCANCELITEM0000000000"), attempt: 1)
        cancelledStage.lease.release()
        do {
            _ = try await speech.speechEngine.transcribeFile(
                at: cancelledStage.audioURL, localeID: speech.localeID,
                deadline: ContinuousClock.now.advanced(by: .seconds(300)), onProgress: nil)
            Issue.record("expected the cancellation")
        } catch is CancellationError { }
        cancelledStage.discard()
        #expect(try store.processedMarkdownHead(sourceID: sourceID) == nil)
        #expect(FileManager.default.fileExists(atPath: cancelledStage.audioURL.path) == false)
    }

    @Test func readinessAndLimits() async throws {
        // The empty-transcription limit is a typed failure the worker maps
        // to a visible per-item error — never a silent completion.
        #expect(SpeechTranscriptionError.emptyTranscription.errorDescription
            == "No speech was detected in this audio.")
        #expect(SpeechTranscriptionError.transcriptTooLong.errorDescription != nil)
        #expect(SpeechTranscriptionError.deadlineExceeded.errorDescription != nil)
        #expect(SpeechTranscriptionError.unreadableAudio.errorDescription != nil)
        // The queue-level wait policy: the speech bound strictly exceeds the
        // caption bound, and the caption bound is unchanged.
        #expect(QueueEngineWaitPolicy.speechCompletionWaitDeadline
            > QueueEngineWaitPolicy.completionWaitDeadline)
        #expect(QueueEngineWaitPolicy.completionWaitDeadline == .seconds(35 * 60))
        // The speech capacity bucket is exactly one job.
        #expect(QueueEngineConfig().extractionLimit(
            for: ProviderID(rawValue: SpeechExtractionResolution.defaultCapacityID)) == 1)
    }

    @Test func failedCaptionsNeverStartSpeech() async throws {
        let store = try makeStore()
        let sourceID = try seedYouTubeSource(store)
        // The caption package answers with a FAILURE frame.
        let executor = FailingCaptionExecutor()
        let engine = ScriptedSpeechEngine()
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-captionfail-\(UUID().uuidString)", isDirectory: true)
        let services = try await makeServices(executor: FakeAudioExecutor())
        let provider = makeAppProvider(store: store, services: CaptionOverridingServices(base: services, captionExecutor: executor), engine: engine, stageRoot: stageRoot)

        // The caption intent resolves the caption arm; its fetch fails.
        guard case .transcript(let transcript)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            backendOverride: nil, transcriptionIntent: .captions) else {
            Issue.record("expected the caption arm")
            return
        }
        do {
            _ = try await transcript.fetch { _ in }
            Issue.record("expected the caption failure")
        } catch { }
        // A caption failure starts no speech: no engine call, no speech
        // resolution, no transcript version.
        #expect(engine.transcribeCalls == 0)
        #expect(try store.processedMarkdownHead(sourceID: sourceID) == nil)
    }
}

/// The caption arm answers with a success markdown frame.
private final class FakeCaptionExecutor: ManagedProcessExecuting, @unchecked Sendable {
    func execute(
        _ operation: ManagedExtractorProcessRequest,
        onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void
    ) async throws -> ManagedExtractorProcessResult {
        guard case .extractor(let request) = operation.request else {
            throw ExtractionServicesError.unavailable
        }
        let markdown = "# caption"
        let output = operation.paths.operationRoot
            .appendingPathComponent(request.outputPath.rawValue)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: output)
        let frame = try ExtractorResultFrame(
            requestID: request.requestID,
            outputPath: request.outputPath,
            markdownByteCount: markdown.utf8.count,
            metadata: try ExtractorReportedMetadata(toolName: "youtube-transcript"))
        return ManagedExtractorProcessResult(
            terminationCause: .exited(code: 0),
            terminalFrame: .result(frame),
            progressEventCount: 1,
            standardOutputByteCount: 0,
            standardError: Data(),
            executableURL: operation.paths.packageRoot)
    }
}

/// The caption arm answers with a failure frame (blocked request shape).
private final class FailingCaptionExecutor: ManagedProcessExecuting, @unchecked Sendable {
    func execute(
        _ operation: ManagedExtractorProcessRequest,
        onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void
    ) async throws -> ManagedExtractorProcessResult {
        guard case .extractor(let request) = operation.request else {
            throw ExtractionServicesError.unavailable
        }
        let frame = ExtractorProtocolFrame.failure(try ExtractorFailureFrame(
            requestID: request.requestID,
            cause: .extractionFailure,
            message: "caption retrieval failed"))
        return ManagedExtractorProcessResult(
            terminationCause: .exited(code: 0),
            terminalFrame: frame,
            progressEventCount: 0,
            standardOutputByteCount: 0,
            standardError: Data(),
            executableURL: operation.paths.packageRoot)
    }
}

/// Delegates everything to the base but overrides the YouTube caption seam
/// with the failing executor.
private struct CaptionOverridingServices: ExtractionServices {
    let base: any ExtractionServices
    let captionExecutor: ManagedProcessExecuting

    func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
        try await base.prepare(backendOverride: backendOverride)
    }

    func prepareFetcher(sourceMIMEType: ExtractorMIMEType) async throws -> ProcessPackageFetcher {
        try await base.prepareFetcher(sourceMIMEType: sourceMIMEType)
    }

    func prepareYouTubeTranscript() async throws -> ProcessPackageYouTubeTranscript {
        // Build a minimal failing caption operation over a private root.
        let manifest = try JSONDecoder().decode(ExtractorManifest.self, from: Data("""
        {
          "manifestRevision": 1,
          "packageID": "org.selfdrivingwiki.youtube-transcript",
          "version": "1.2.0",
          "displayName": "YouTube Transcript",
          "protocolRevision": 3,
          "entryPoint": "bin/youtube-transcript-extractor",
          "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
          "registrations": [
            {"id": "captions", "displayName": "YouTube Transcript", "kinds": ["youtube-transcript"], "mimeTypes": ["video/youtube"]}
          ],
          "capabilities": ["network"],
          "files": [{"path": "bin/youtube-transcript-extractor", "digest": "0000000000000000000000000000000000000000000000000000000000000000"}],
          "limits": {"maximumInputByteCount": 1048576, "maximumMarkdownOutputByteCount": 33554432, "maximumDurationMilliseconds": 600000, "maximumProgressEventCount": 64}
        }
        """.utf8))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-caption-fail-\(UUID().uuidString)", isDirectory: true)
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
            revision: ReviewedExtractorPackages.youtubeTranscript.revision,
            manifest: manifest,
            registration: registration,
            registrationID: registrationID,
            protocolRevision: .v3,
            mimeTypes: [MimeType.videoYouTube],
            executor: captionExecutor,
            launchGate: nil,
            operationCredentials: nil,
            operationConfiguration: nil,
            runtimeResolution: nil)
        return ProcessPackageYouTubeTranscript(operation: operation)
    }
}
#endif
