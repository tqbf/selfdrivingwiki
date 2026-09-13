#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

/// AC.2 of the durable new-chat identity: a chat created through
/// `beginNewChat()` survives page navigation. The detail-routing surface is
/// mounted in a real NSWindow (HostedAppKitTestGate pattern); we navigate
/// away to a page and back and assert the chat route re-renders the composer
/// — never the "Chat Deleted" presentation, because the row still exists in
/// SQLite.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct DurableNewChatHostedTests {

    /// An `NSHostingController` in a `swift test` CLI has no host app, so give
    /// AppKit one (same pattern as `PageDetailViewHostedTests`).
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    /// The routing slice of `WikiDetailView.detailContent`: `.chat(id)` renders
    /// `ChatDetailView` (with the same `.id(chatID)` view identity), everything
    /// else renders a plain placeholder page surface.
    private struct ChatDetailRouteView: View {
        @Bindable var store: WikiStoreModel
        let session: ProfileWikiSession
        let coordinator: ChatDaemonCoordinator
        let fileProvider: FileProviderFacade

        var body: some View {
            switch store.selection {
            case .chat(let id):
                ChatDetailView(
                    chatID: id,
                    store: store,
                    remoteSession: coordinator.session(wikiID: session.wikiID, for: id),
                    coordinator: coordinator,
                    session: session,
                    fileProvider: fileProvider
                )
                .id(id)
                .environment(WindowRightInspectorController())
            default:
                ContentUnavailableView("Page Surface", systemImage: "doc.text")
            }
        }
    }

    // MARK: - Fixture

    private func makeFixture() throws -> (ProfileWikiSession, ChatDaemonCoordinator) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-new-chat-hosted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let descriptor = WikiDescriptor.make(displayName: "Durable Chat Test")
        let extractionCoordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { DurableChatStubExtractor() })
        let session = try ProfileWikiSession(
            testFixtureWikiID: descriptor.id,
            descriptor: descriptor,
            containerDirectory: dir,
            extractionCoordinator: extractionCoordinator,
            queueEngine: try makeDurableChatTestQueueEngine(),
            extractionProvider: DurableChatStubExtractionProvider())
        let coordinator = ChatDaemonCoordinator(
            client: StubChatDaemonCommands(),
            eventSink: DaemonQueueEventSink())
        return (session, coordinator)
    }

    private func mount<V: View>(_ view: V) -> (NSHostingController<V>, NSWindow) {
        _ = Self.app
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

    /// Walk the subtree: the deleted presentation has no composer text view.
    private func hasComposer(in view: NSView) -> Bool {
        firstSubview(of: view, ofType: NSTextView.self) != nil
    }

    private func firstSubview<ViewType: NSView>(of view: NSView, ofType type: ViewType.Type) -> ViewType? {
        if let match = view as? ViewType { return match }
        for sub in view.subviews {
            if let match = firstSubview(of: sub, ofType: type) { return match }
        }
        return nil
    }

    // MARK: - AC.2

    @Test func durableNewChatSurvivesPageNavigationWithoutDeletedState() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let (session, coordinator) = try makeFixture()
        let store = session.store
        // The fixture seeds a "Home" page at init; navigate to it.
        let page = try #require(session.descriptor.homePageID)
        store.reloadFromStore()

        // Durable creation: the row is persisted before the tab opens.
        store.beginNewChat()
        guard case .chat(let chatID) = store.selection else {
            Issue.record("beginNewChat must open a .chat route")
            return
        }
        #expect(store.resolveChat(id: chatID) != .notFound)

        let (_, window) = mount(ChatDetailRouteView(
            store: store, session: session,
            coordinator: coordinator, fileProvider: FileProviderFacade()))
        defer { window.orderOut(nil) }
        let hostingView = window.contentView!

        // First frame: the chat surface renders (composer present).
        let mounted = await waitUntil { self.hasComposer(in: hostingView) }
        #expect(mounted, "the durable empty chat must render its composer on first mount")

        // Navigate away to the page route.
        store.openTab(.page(page))
        let navigatedAway = await waitUntil { !self.hasComposer(in: hostingView) }
        #expect(navigatedAway, "the placeholder page route replaces the chat surface")

        // Back to the SAME chat: it resolves from SQLite and renders again —
        // no remount onto a different identity, and the live row resolves as
        // available (the `.notFound → deletedChat` mapping is pinned at the
        // presentation level by `deletedChatPresentationIsDetectable`).
        store.openTab(.chat(chatID))
        let navigatedBack = await waitUntil { self.hasComposer(in: hostingView) }
        #expect(navigatedBack, "returning to the empty chat must re-render its surface")
        #expect(store.selection == .chat(chatID))
        #expect(store.resolveChat(id: chatID) != .notFound)
    }

    /// Probe validation at the presentation level (SwiftUI static text is not
    /// AX-visible in a CLI host): a `.notFound` resolution IS the "Chat
    /// Deleted" presentation and a `.available` one is the chat surface — so
    /// the hosted test's composer-presence probes distinguish exactly these
    /// two states.
    @Test func deletedChatPresentationIsDetectable() throws {
        let missingID = ChatID(rawValue: "01J" + String(repeating: "X", count: 22))
        let remoteState = ChatDetailPresentation.RemoteState(
            runState: .idle,
            sessionChatID: missingID,
            runningKind: nil,
            preflightError: nil,
            pendingPermissions: [],
            projectionInput: .empty)

        let deleted = ChatDetailPresentation.make(
            chatID: missingID,
            chatResolution: .notFound,
            showsInternals: false,
            remoteSession: remoteState,
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: false)
        #expect(deleted.contentState == .deletedChat)
        #expect(deleted.composer.isEnabled == false,
                "the deleted presentation has no live composer")

        let available = ChatDetailPresentation.make(
            chatID: missingID,
            chatResolution: .available(ChatSummary(
                id: missingID, kind: .edit, title: "",
                createdAt: Date(), updatedAt: Date(), messageCount: 0)),
            showsInternals: false,
            remoteSession: remoteState,
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: false)
        #expect(available.contentState == .chatSurface)
    }
}

// MARK: - Minimal stubs (mirroring PageDetailViewHostedTests' private helpers)

@MainActor
private final class DurableChatStubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(pdfData: Data, filename: String, onProgress: (@Sendable (String) -> Void)?) async throws -> String { "" }
}

private struct DurableChatStubExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(wikiID: WikiID, sourceID: SourceID, backendOverride: ExtractionBackend?) async throws -> ExtractionResolution? { nil }
    func persistBytesExtraction(wikiID: WikiID, sourceID: SourceID, resolution: BytesExtractionResolution, markdown: String) async throws -> QueueExtractionOutputReference? { nil }
    func persistTranscriptExtraction(wikiID: WikiID, sourceID: SourceID, resolution: TranscriptExtractionResolution, outcome: TranscriptFetchOutcome) async throws -> QueueExtractionOutputReference? { nil }
}

private func makeDurableChatTestQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let provider = DurableChatStubExtractionProvider()
    let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}
#endif
