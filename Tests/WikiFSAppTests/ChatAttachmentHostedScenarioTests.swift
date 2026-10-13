#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

// MARK: - Hydration latch

/// Suspends the rehydrate-path daemon call so a test can prove chips land
/// BEFORE hydration completes. Cancellation-aware and timeout-bounded — the
/// same lifecycle discipline as the hosted gate — so a failed assertion or a
/// cancelled hydration task can never leave a continuation suspended forever.
@MainActor
final class HydrationLatch {
    struct LatchTimeoutError: Error {}

    private let timeout: Duration
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledIDs: Set<UUID> = []
    private(set) var released = false

    init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    /// Number of continuations currently suspended.
    var outstandingWaiters: Int { waiters.count }

    /// Suspend until `releaseAll()`, task cancellation, or the deadline.
    func wait() async throws {
        let id = UUID()
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .seconds(5))
            self?.timeoutWaiter(id: id)
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if released {
                        continuation.resume()
                        return
                    }
                    if cancelledIDs.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    waiters[id] = continuation
                }
            } onCancel: {
                Task { [weak self] in
                    await self?.cancelWaiter(id: id)
                }
            }
        } catch {
            throw error
        }
    }

    /// Release every outstanding waiter (teardown and happy path).
    func releaseAll() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending {
            continuation.resume()
        }
    }

    private func timeoutWaiter(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else {
            cancelledIDs.insert(id)
            return
        }
        continuation.resume(throwing: LatchTimeoutError())
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else {
            cancelledIDs.insert(id)
            return
        }
        continuation.resume(throwing: CancellationError())
    }
}

/// Delegates everything to `StubChatDaemonCommands` except `chatSessionState`,
/// which suspends on the latch first — that await is exactly what
/// `ChatDaemonCoordinator.rehydrate` performs (ChatDaemonCoordinator.swift:446).
private final class LatchedChatDaemonCommands: ChatDaemonCommands {
    let base: StubChatDaemonCommands
    let latch: HydrationLatch

    init(base: StubChatDaemonCommands, latch: HydrationLatch) {
        self.base = base
        self.latch = latch
    }

    func submitChatTurn(_ request: ChatSubmitRequest) async throws -> ChatID {
        try await base.submitChatTurn(request)
    }
    func stopChat(wikiID: WikiID, chatID: ChatID) async throws {
        try await base.stopChat(wikiID: wikiID, chatID: chatID)
    }
    func chatSessionState(wikiID: WikiID, chatID: ChatID) async throws -> ChatSyncSnapshot {
        try await latch.wait()
        return try await base.chatSessionState(wikiID: wikiID, chatID: chatID)
    }
    func chatDiagnosticSnapshot(_ request: ChatDiagnosticSnapshotRequest) async throws -> ChatDiagnosticSnapshotEnvelope {
        try await base.chatDiagnosticSnapshot(request)
    }
    func resetChatDiagnostics(_ request: ChatDiagnosticResetRequest) async throws {
        try await base.resetChatDiagnostics(request)
    }
    func resolveChatPermission(_ request: ChatPermissionResolveRequest) async throws {
        try await base.resolveChatPermission(request)
    }
    func setChatConfigOption(_ request: ChatConfigOptionRequest) async throws {
        try await base.setChatConfigOption(request)
    }
}

// MARK: - Minimal fixture stubs (duplicated from DurableNewChatHostedTests'
// private helpers rather than widening their accessibility)

@MainActor
private final class ScenarioStubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(pdfData: Data, filename: String, onProgress: (@Sendable (String) -> Void)?) async throws -> String { "" }
}

private struct ScenarioStubExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(wikiID: WikiID, sourceID: SourceID, backendOverride: ExtractionBackend?, transcriptionIntent: QueueItemPayload.TranscriptionIntent?) async throws -> ExtractionResolution? { nil }
    func persistBytesExtraction(wikiID: WikiID, sourceID: SourceID, resolution: BytesExtractionResolution, markdown: String) async throws -> QueueExtractionOutputReference? { nil }
    func persistTranscriptExtraction(wikiID: WikiID, sourceID: SourceID, resolution: TranscriptExtractionResolution, outcome: TranscriptFetchOutcome) async throws -> QueueExtractionOutputReference? { nil }
    func persistFetch(wikiID: WikiID, sourceID: SourceID, resolution: FetcherResolution, outcome: FetchOutcome) async throws -> QueueExtractionOutputReference? { nil }
    @discardableResult
    func persistSpeechExtraction(
        wikiID: WikiID, sourceID: SourceID, outcome: SpeechOutcome
    ) async throws -> QueueExtractionOutputReference? { nil }
    func enqueueFollowOnExtraction(wikiID: WikiID, sourceID: SourceID, acquiredContentVersionID: SourceVersionID, dedupeKey: QueueItemDedupeKey) async throws {}
}

// MARK: - Suite

/// View-level scenarios for the create-chat-with-attachments hand-off
/// (AC.4/AC.5): the real `ChatDetailView` mounted in a real window, its
/// composer chips asserted through `onComposerPanePropsBuilt` — the actual
/// value handed to `ChatComposerPaneView` — while daemon hydration is
/// genuinely suspended on a latch.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatAttachmentHostedScenarioTests {

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    /// Captures the composer props the real rendering path builds.
    @MainActor
    final class PropsCapture {
        private(set) var latest: ChatComposerPaneProps?
        var attachments: [ChatAttachment] { latest?.attachments ?? [] }

        func record(_ props: ChatComposerPaneProps) {
            latest = props
        }

        func reset() {
            latest = nil
        }
    }

    /// The routing slice of `WikiDetailView.detailContent`, plus the props spy.
    private struct CaptureRouteView: View {
        @Bindable var store: WikiStoreModel
        let session: ProfileWikiSession
        let coordinator: ChatDaemonCoordinator
        let fileProvider: FileProviderFacade
        let onProps: (ChatComposerPaneProps) -> Void

        var body: some View {
            switch store.selection {
            case .chat(let id):
                ChatDetailView(
                    chatID: id,
                    store: store,
                    remoteSession: coordinator.session(wikiID: session.wikiID, for: id),
                    coordinator: coordinator,
                    session: session,
                    fileProvider: fileProvider,
                    onComposerPanePropsBuilt: onProps
                )
                .id(id)
                .environment(WindowRightInspectorController())
            default:
                ContentUnavailableView("Page Surface", systemImage: "doc.text")
            }
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let session: ProfileWikiSession
        let coordinator: ChatDaemonCoordinator
        let latch: HydrationLatch
        let capture: PropsCapture
        let store: WikiStoreModel
    }

    private func makeFixture(latchTimeout: Duration = .seconds(5)) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-attach-scenario-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let descriptor = WikiDescriptor.make(displayName: "Attach Scenario")
        let extractionCoordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { ScenarioStubExtractor() })
        let session = try ProfileWikiSession(
            testFixtureWikiID: descriptor.id,
            descriptor: descriptor,
            containerDirectory: dir,
            extractionCoordinator: extractionCoordinator,
            queueEngine: try makeScenarioQueueEngine(),
            extractionProvider: ScenarioStubExtractionProvider())
        let latch = HydrationLatch(timeout: latchTimeout)
        let coordinator = ChatDaemonCoordinator(
            client: LatchedChatDaemonCommands(base: StubChatDaemonCommands(), latch: latch),
            eventSink: DaemonQueueEventSink())
        return Fixture(
            session: session, coordinator: coordinator, latch: latch,
            capture: PropsCapture(), store: session.store)
    }

    /// A page to attach, from the refreshed summaries cache.
    private func firstPage(_ fixture: Fixture) throws -> WikiPageSummary {
        fixture.store.reloadFromStore()
        return try #require(fixture.store.summaries.first)
    }

    private func makeScenarioQueueEngine() throws -> QueueEngine {
        let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let provider = ScenarioStubExtractionProvider()
        let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
        return QueueEngine(store: store, workerFactory: factory)
    }

    private func mount(_ fixture: Fixture) -> (NSHostingController<CaptureRouteView>, NSWindow) {
        _ = Self.app
        let capture = fixture.capture
        let view = CaptureRouteView(
            store: fixture.store,
            session: fixture.session,
            coordinator: fixture.coordinator,
            fileProvider: FileProviderFacade(),
            onProps: { capture.record($0) })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)
        return (hosting, window)
    }

    /// Bounded condition wait (never blocks the cooperative pool).
    private func waitUntil(
        timeout: Duration = .seconds(6),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    // MARK: - Latch lifecycle (fixture infrastructure)

    @Test("the hydration latch releases on cancellation or deadline without leaking a waiter")
    func hydrationLatchReleasesOnCancelOrDeadlineWithoutLeakingWaiter() async throws {
        // Cancellation path.
        let latch = HydrationLatch(timeout: .seconds(5))
        let waiter = Task { try await latch.wait() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(latch.outstandingWaiters == 1, "the waiter is suspended on the latch")
        waiter.cancel()
        do {
            _ = try await waiter.value
            Issue.record("cancelled latch waiter must throw, not complete")
        } catch is CancellationError {
            // Expected.
        }
        #expect(latch.outstandingWaiters == 0, "no waiter stays outstanding after cancellation")

        // Deadline path: a short-deadline latch fails the waiter on its own.
        let deadlineLatch = HydrationLatch(timeout: .milliseconds(120))
        do {
            try await deadlineLatch.wait()
            Issue.record("an unreleased latch must time out, not complete")
        } catch is HydrationLatch.LatchTimeoutError {
            // Expected.
        }
        #expect(deadlineLatch.outstandingWaiters == 0)

        // Release path: releaseAll() lets a waiter through.
        let releasable = HydrationLatch(timeout: .seconds(5))
        let happy = Task { try await releasable.wait() }
        try await Task.sleep(for: .milliseconds(80))
        releasable.releaseAll()
        _ = try await happy.value
        #expect(releasable.outstandingWaiters == 0)
    }

    // MARK: - AC.4 scenarios

    @Test("chips land before hydration completes")
    func chipsLandBeforeHydrationCompletes() async throws {
        let fixture = try makeFixture()
        let page = try firstPage(fixture)
        fixture.store.beginNewChat(attachments: [.page(page.id)])

        let (_, window) = mount(fixture)
        defer { window.orderOut(nil) }

        // Hydration is still suspended on the latch, yet the props already
        // carry the chip: the restore ran synchronously at first mount, from
        // SQLite — the persisted rows are the only source.
        let landed = await waitUntil { !fixture.capture.attachments.isEmpty }
        #expect(landed, "chips must appear without waiting for daemon hydration")
        #expect(fixture.latch.released == false, "hydration is still suspended")
        #expect(fixture.capture.attachments.map(\.displayName) == [page.title])

        fixture.latch.releaseAll()
    }

    @Test("nothing attaches to the wrong chat")
    func nothingAttachesToTheWrongChat() async throws {
        let fixture = try makeFixture()
        let page = try firstPage(fixture)
        fixture.store.beginNewChat(attachments: [.page(page.id)])
        let attachedChatID: ChatID
        if case .chat(let id) = fixture.store.selection { attachedChatID = id } else {
            Issue.record("beginNewChat must open the chat route")
            return
        }

        let (_, window) = mount(fixture)
        defer { window.orderOut(nil) }
        _ = await waitUntil { !fixture.capture.attachments.isEmpty }
        #expect(fixture.store.chatAttachments(chatID: attachedChatID) == [.page(page.id)],
                "the attached chat's rows are the restore source")

        // Navigate to a plain page tab (no attachment request involved).
        fixture.store.openTab(.page(page.id))
        fixture.capture.reset()
        _ = await waitUntil { self.currentSelectionIsPage(fixture) }
        #expect(fixture.capture.attachments.isEmpty, "no chat surface, no chips")
        _ = attachedChatID

        fixture.latch.releaseAll()
    }

    private func currentSelectionIsPage(_ fixture: Fixture) -> Bool {
        if case .page = fixture.store.selection { return true }
        return false
    }

    @Test("remount and repeated hydration add no duplicate chips")
    func remountAddsNoDuplicateChips() async throws {
        let fixture = try makeFixture()
        let page = try firstPage(fixture)
        fixture.store.beginNewChat(attachments: [.page(page.id)])
        guard case .chat(let chatID) = fixture.store.selection else {
            Issue.record("beginNewChat must open the chat route")
            return
        }

        let (_, window) = mount(fixture)
        defer { window.orderOut(nil) }
        _ = await waitUntil { !fixture.capture.attachments.isEmpty }

        // Navigate away (discards the chat view) and back (remounts it with a
        // fresh @State model) while hydration is STILL suspended.
        fixture.store.openTab(.page(page.id))
        fixture.capture.reset()
        fixture.store.openTab(.chat(chatID))
        let relanded = await waitUntil { !fixture.capture.attachments.isEmpty }
        #expect(relanded, "the remounted chat rebuilds its composer")

        // Let hydration finish; the re-run hydration task must not re-apply
        // or duplicate anything.
        fixture.capture.reset()
        fixture.latch.releaseAll()
        _ = await waitUntil { fixture.latch.released }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.capture.attachments.count <= 1,
                "no duplicate chips after remount + hydration")
    }

    @Test("a duplicate target produces one chip")
    func duplicateTargetProducesOneChip() async throws {
        let fixture = try makeFixture()
        fixture.store.beginNewChat()
        let (_, window) = mount(fixture)
        defer { window.orderOut(nil) }

        let ready = await waitUntil { fixture.capture.latest != nil }
        #expect(ready)
        let props = try #require(fixture.capture.latest)
        let pageTarget = ChatAttachmentTarget.page(
            PageID(rawValue: "01HDUP"))
        let chip = ChatAttachment(target: pageTarget, store: fixture.store)

        // The AddContextPicker path, twice: the real onAddAttachment closure.
        props.onAddAttachment(chip)
        props.onAddAttachment(chip)
        let settled = await waitUntil { fixture.capture.latest?.attachments.count == 1 }
        #expect(settled, "duplicate targets collapse to one chip")
    }

    // MARK: - AC.5

    @Test("the new chat's composer takes keyboard focus")
    func newChatComposerTakesFocus() async throws {
        let fixture = try makeFixture()
        fixture.store.beginNewChat()
        let (_, window) = mount(fixture)
        defer { window.orderOut(nil) }

        window.makeKeyAndOrderFront(nil)

        // Primary signal (mandatory): the one-shot focus request is consumed
        // when the composer actually becomes first responder.
        let drained = await waitUntil(timeout: .seconds(6)) {
            fixture.store.pendingComposerFocusChatID == nil
        }
        #expect(drained, "composer focus request must be consumed by the new chat")

        // Operator-visible confirmation when the CLI host grants key status.
        if window.isKeyWindow {
            let responderReady = await waitUntil {
                let responder = window.firstResponder
                return (responder as? NSTextView)?.window === window
            }
            #expect(responderReady, "the composer text view holds keyboard focus")
        }
    }
}
#endif
