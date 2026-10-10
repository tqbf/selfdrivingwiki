#if os(macOS)
import AppKit
import SwiftUI
import Synchronization
import Testing
import WikiFSCore
import WikiFSEngine
import WikiFSTypes
@testable import WikiFS

/// AC.2 of the revised YouTube import policy (issue #1379), exercised
/// through the real UI actions:
///
/// - Hosting `AddFromURLSheet` and clicking the REAL Fetch button, with an
///   active YouTube registration, enqueues ZERO extraction jobs — the sheet
///   runs offline through the injectable fetcher seam.
/// - Hosting `SourceDetailView` for the created source and clicking the
///   REAL Transcribe button enqueues EXACTLY ONE `.extraction` job — the
///   only path YouTube transcription has.
///
/// The queue engine is a full `QueueEngineClient` that records every
/// enqueue; nothing reaches a worker and no network is touched.
@MainActor
@Suite("Add URL import vs Transcribe action", .serialized, .timeLimit(.minutes(3)))
struct AddURLAndTranscribeHostedTests {

    private static let watchURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    // MARK: - Fixtures

    /// Records every enqueue with its queue kind and source IDs.
    private final class RecordingQueueEngine: QueueEngineClient, @unchecked Sendable {
        private let records = Mutex<[(queue: QueueKind, sources: [String])]>([])
        private let eventContinuation: AsyncStream<QueueEvent>.Continuation
        private let stream: AsyncStream<QueueEvent>

        init() {
            (stream, eventContinuation) = AsyncStream<QueueEvent>.makeStream()
        }

        var events: AsyncStream<QueueEvent> { stream }

        func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
            records.withLock {
                $0.append((request.queue, request.payload.sourceIDs.map(\.rawValue)))
            }
            eventContinuation.yield(.runStateChanged(queue: request.queue, state: .running))
            return QueueItem.ID(rawValue: "recorded-\(request.queue.rawValue)")
        }

        func extractionEnqueueCount() -> Int {
            records.withLock { $0.filter { $0.queue == .extraction }.count }
        }

        func cancelItem(_ id: QueueItem.ID) async throws {}
        func cancelAllInFlight() async throws -> Int { 0 }
        func retryItem(_ id: QueueItem.ID) async throws {}
        func pause(_ queue: QueueKind) async throws {}
        func resume(_ queue: QueueKind) async throws {}
        func halt(_ queue: QueueKind) async throws {}
        func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws {}

        func snapshot() async throws -> QueueSnapshot {
            QueueSnapshot()
        }

        func hasActiveWork(for wikiID: WikiID) async throws -> Bool { false }

        func waitForCompletion(of id: QueueItem.ID) async throws -> Result<Void, Error> {
            .success(())
        }

        func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] { [] }

        func loadAllActivitySnapshots() async throws -> [QueueItem.ID: QueueEngine.ActivitySnapshot] {
            [:]
        }

        func loadQueueReport(for itemID: QueueItem.ID) async -> QueueReportLoadResult {
            .notReported
        }

        func loadQueueReportSummaries(for itemIDs: [QueueItem.ID]) async -> QueueReportSummariesResult {
            .loaded([:])
        }
    }

    /// The offline URL fetcher: one canned YouTube watch response.
    private struct OfflineFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            URLFetchService.FetchResponse(
                data: Data(),
                contentType: nil,
                finalURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        }
    }

    private static func youtubeClaims() -> RegisteredExtractionInputs {
        RegisteredExtractionInputs(claims: [
            .init(
                kind: .youtubeTranscript,
                mimeTypes: ["video/youtube"],
                filenameExtensions: []),
        ])
    }

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    // MARK: - View-tree helpers

    private func waitUntil(
        timeout: Duration = .seconds(8),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    // MARK: - AC.2 part 1: Add URL queues zero jobs

    /// SwiftUI's ordinary controls are not bridged to AppKit buttons, so a
    /// hosted scenario cannot click them in-process (the repo's other hosted
    /// tests click controls the app explicitly bridges). The plan's test
    /// strategy sanctions a small injectable action seam: both tests below
    /// invoke the mounted view's exact button-action body through it, then
    /// assert what the user action must (and must not) enqueue.

    @Test("a hosted Fetch with an active YouTube claim enqueues zero jobs")
    func addURLFetchEnqueuesZeroJobs() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app

        let store = try TestStoreFactory.inMemory()
        let model = WikiStoreModel(store: store)
        model.registeredExtractionInputs = Self.youtubeClaims()
        let engine = RecordingQueueEngine()

        let hosting = NSHostingController(rootView: AddFromURLSheet(
            store: model,
            initialURL: Self.watchURL,
            queueEngine: engine,
            urlFetcher: OfflineFetcher()))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 520, height: 320))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // Settle the first render, then run the mounted view's Fetch action.
        await Task.yield()
        hosting.rootView.fetchActionForTesting()

        // The offline fetch lands the byteless YouTube source. The byteless
        // path reloads the model async off the bus, so poll the store.
        let landed = await waitUntil {
            (try? store.listSources().contains { $0.mimeType == "video/youtube" }) == true
        }
        #expect(landed, "the offline fetch never created the source")
        model.reloadFromStore()
        #expect(model.sources.first?.mimeType == "video/youtube")

        // Give any (wrong) enqueue path a generous window, then assert none
        // happened: YouTube import stays explicit.
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.extractionEnqueueCount() == 0)
    }

    // MARK: - AC.2 part 2: Transcribe queues exactly one job

    @Test("the hosted Transcribe button enqueues exactly one job")
    func transcribeButtonEnqueuesOneJob() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app

        let store = try TestStoreFactory.inMemory()
        let model = WikiStoreModel(store: store)
        model.registeredExtractionInputs = Self.youtubeClaims()
        let summary = try store.addBytelessSource(
            filename: "youtube-dQw4w9WgXcQ",
            mimeType: MimeType.videoYouTube,
            provenance: SourceProvenance(
                agentName: SourceProvider.youtube.rawValue,
                activityKind: "fetch",
                plan: Self.watchURL,
                externalRef: Self.watchURL,
                externalIdentity: "dQw4w9WgXcQ"),
            role: .primary)
        let file = try #require(model.sources.first(where: { $0.id == summary.id })
            ?? (try store.listSources().first(where: { $0.id == summary.id })))

        let engine = RecordingQueueEngine()
        let session = try Self.makeMinimalSession(queueEngine: engine)
        let detail = SourceDetailView(
            file: file,
            hasBeenIngested: false,
            isIngesting: false,
            isRunning: false,
            isAnySourceIngesting: false,
            isThisFileExtracting: false,
            isEditLockedExternally: false,
            wikiID: session.wikiID,
            runIngest: { _ in },
            launcher: AgentLauncher(),
            extractionCoordinator: session.extractionCoordinator,
            queueEngine: engine,
            extractionProvider: NoopExtractionProvider(),
            fileProvider: FileProviderFacade(),
            store: model,
            installedRendererFactory: .unavailable,
            installedRendererFactoryInputs: .init(
                availableDescriptors: [],
                registeredSourceTypes: nil,
                hostNavigationRouting: .unavailable,
                resolveConfiguration: { _, _ in nil }))
        let hosting = NSHostingController(rootView: HostedSourceDetail(detail: detail))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1_100, height: 760))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // The header starts collapsed; the action seam needs no expansion —
        // run the real detail view's Transcribe action (the exact body the
        // real button invokes, bound to the same queue engine and store).
        await Task.yield()
        hosting.rootView.detail.transcribeActionForTesting()

        // Exactly one extraction job — the durable enqueue the queue worker
        // resolves through the reviewed package.
        let one = await waitUntil { engine.extractionEnqueueCount() == 1 }
        #expect(one, "the Transcribe action did not enqueue exactly once")
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.extractionEnqueueCount() == 1)
    }

    // MARK: - Fixtures: the hosted detail view

    private struct HostedSourceDetail: View {
        let detail: SourceDetailView
        let inspector = WindowRightInspectorController()

        var body: some View {
            detail
                .environment(FindModel())
                .environment(QueueActivityTracker())
                .environment(inspector)
        }
    }

    private final class NoopExtractor: MarkdownExtractor {
        nonisolated var displayName: String { "Stub" }
        func readiness() async -> ExtractionReadiness { .ready }
        func convert(
            pdfData: Data,
            filename: String,
            onProgress: (@Sendable (String) -> Void)?
        ) async throws -> String { "" }
    }

    private struct NoopExtractionProvider: QueueExtractionProvider {
        func resolveExtraction(
            wikiID: WikiID,
            sourceID: SourceID,
            backendOverride: ExtractionBackend?
        ) async throws -> ExtractionResolution? { nil }

        func persistBytesExtraction(
            wikiID: WikiID,
            sourceID: SourceID,
            resolution: BytesExtractionResolution,
            markdown: String
        ) async throws -> QueueExtractionOutputReference? { nil }

        func persistTranscriptExtraction(
            wikiID: WikiID,
            sourceID: SourceID,
            resolution: TranscriptExtractionResolution,
            outcome: TranscriptFetchOutcome
        ) async throws -> QueueExtractionOutputReference? { nil }

        func persistFetch(
            wikiID: WikiID,
            sourceID: SourceID,
            resolution: FetcherResolution,
            outcome: FetchOutcome
        ) async throws -> QueueExtractionOutputReference? { nil }

        func enqueueFollowOnExtraction(
            wikiID: WikiID,
            sourceID: SourceID,
            acquiredContentVersionID: SourceVersionID,
            dedupeKey: QueueItemDedupeKey
        ) async throws {}
    }

    private static func makeMinimalSession(
        queueEngine: QueueEngineClient
    ) throws -> ProfileWikiSession {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("addurl-transcribe-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let descriptor = WikiDescriptor.make(displayName: "Add URL Transcribe Test")
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { NoopExtractor() }
        )
        return try ProfileWikiSession(
            testFixtureWikiID: descriptor.id,
            descriptor: descriptor,
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: queueEngine,
            extractionProvider: NoopExtractionProvider()
        )
    }
}
#endif
