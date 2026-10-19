#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

/// End-to-end delivery of a locally queued chat message after Stop (#1443).
///
/// Every seam on the delivery path is production code: the real
/// `ChatDetailView` (mounted in an `NSWindow`), its real composer actions
/// (captured through `onComposerPanePropsBuilt`), the real
/// `ChatDaemonCoordinator` and `RemoteChatSession`, and a real
/// `DaemonChatController` over the same SQLite file the view reads. Only the
/// XPC hop and the agent process are replaced: a bridge forwards commands to
/// the controller, and `StubControllerRuntime` stands in for the agent.
///
/// No test helper drains the queue. The assertion is that the view's own
/// readiness observation submits the queued message after the cancellation
/// settles.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatQueuedMessageAfterCancelHostedTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    @Test("a message queued during a run auto-submits after Stop settles")
    func queuedMessageAutoSubmitsAfterStop() async throws {
        let lease = try await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let fixture = try await Fixture.make()
        defer { fixture.tearDown() }
        let (_, window) = fixture.mount()
        defer { window.orderOut(nil) }

        try await fixture.submitFirstTurnAndWaitUntilAnswering()

        // Queue a follow-up through the real composer action.
        let props = try #require(fixture.capture.latest)
        fixture.store.draftChatMessage = Fixture.queuedText
        props.onQueue()
        #expect(await fixture.waitUntil { fixture.capture.latest?.queuedMessages.count == 1 },
                "the follow-up must sit in the local queue while the run answers")
        #expect(await fixture.runtimeSubmittedTexts() == [Fixture.firstText],
                "a queued message must not reach the daemon before Stop")

        // Stop through the real composer action. The daemon settles the
        // cancellation and closes the runtime.
        try #require(fixture.capture.latest).onStop()

        let delivered = await fixture.waitUntilAsync {
            await fixture.runtimeSubmittedTexts().contains(Fixture.queuedText)
        }
        #expect(delivered, "the queued message must auto-submit after the cancellation settles")
        #expect(fixture.capture.latest?.queuedMessages.isEmpty == true,
                "the delivered message must leave the local queue")
        #expect(await fixture.runtimeSubmittedTexts() == [Fixture.firstText, Fixture.queuedText])

        let turns = try fixture.daemonStore.listPersistedChatTurns(chatID: fixture.chatID)
        #expect(turns.first?.state == .cancelled, "the first turn settles as cancelled")
        #expect(turns.map(\.submission.userText) == [Fixture.firstText, Fixture.queuedText])
    }

    @Test("Send Now hands a queued message to the daemon while the run answers")
    func sendNowDeliversQueuedMessageDuringRun() async throws {
        let lease = try await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let fixture = try await Fixture.make()
        defer { fixture.tearDown() }
        let (_, window) = fixture.mount()
        defer { window.orderOut(nil) }

        try await fixture.submitFirstTurnAndWaitUntilAnswering()

        fixture.store.draftChatMessage = Fixture.queuedText
        try #require(fixture.capture.latest).onQueue()
        #expect(await fixture.waitUntil { fixture.capture.latest?.queuedMessages.count == 1 })
        let props = try #require(fixture.capture.latest)
        #expect(props.canSendQueuedMessageNow)

        // The manual path does not wait for readiness. The daemon keeps the
        // message as a durable follower behind the active turn.
        props.onSendQueuedMessageNow(0)
        #expect(await fixture.waitUntil { fixture.capture.latest?.queuedMessages.isEmpty == true },
                "Send Now removes the message from the local queue")
        let durable = await fixture.waitUntilAsync {
            fixture.persistedTurnTexts().contains(Fixture.queuedText)
        }
        #expect(durable, "Send Now must reach the daemon's durable queue")
        // The active turn is not interrupted: the follower waits for it.
        #expect(await fixture.runtimeSubmittedTexts() == [Fixture.firstText])
    }

    // MARK: - Fixture

    @MainActor
    final class PropsCapture {
        private(set) var latest: ChatComposerPaneProps?

        func record(_ props: ChatComposerPaneProps) {
            latest = props
        }
    }

    private struct RouteView: View {
        @Bindable var store: WikiStoreModel
        let session: ProfileWikiSession
        let coordinator: ChatDaemonCoordinator
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
                    fileProvider: FileProviderFacade(),
                    onComposerPanePropsBuilt: onProps
                )
                .id(id)
                .environment(WindowRightInspectorController())
            default:
                ContentUnavailableView("Page Surface", systemImage: "doc.text")
            }
        }
    }

    @MainActor
    private final class Fixture {
        static let firstText = "first question"
        static let queuedText = "queued follow-up"

        let session: ProfileWikiSession
        let store: WikiStoreModel
        let chatID: ChatID
        let daemonStore: GRDBWikiStore
        let runtime: StubControllerRuntime
        let controller: DaemonChatController
        let coordinator: ChatDaemonCoordinator
        let capture = PropsCapture()
        private let envelopeContinuation: AsyncStream<QueueEventEnvelope>.Continuation
        private let router: Task<Void, Never>

        private init(
            session: ProfileWikiSession,
            chatID: ChatID,
            daemonStore: GRDBWikiStore,
            runtime: StubControllerRuntime,
            controller: DaemonChatController,
            coordinator: ChatDaemonCoordinator,
            envelopeContinuation: AsyncStream<QueueEventEnvelope>.Continuation,
            router: Task<Void, Never>
        ) {
            self.session = session
            self.store = session.store
            self.chatID = chatID
            self.daemonStore = daemonStore
            self.runtime = runtime
            self.controller = controller
            self.coordinator = coordinator
            self.envelopeContinuation = envelopeContinuation
            self.router = router
        }

        static func make() async throws -> Fixture {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("queued-after-cancel-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let descriptor = WikiDescriptor.make(displayName: "Queued After Cancel")
            let session = try ProfileWikiSession(
                testFixtureWikiID: descriptor.id,
                descriptor: descriptor,
                containerDirectory: dir,
                extractionCoordinator: ExtractionCoordinator(
                    containerDirectory: dir,
                    localExtractorFactory: { QueuedAfterCancelStubExtractor() }),
                queueEngine: try makeQueuedAfterCancelQueueEngine(),
                extractionProvider: QueuedAfterCancelStubExtractionProvider())

            // A configured provider, so the view's chat-operation gate is open.
            let providersDirectory = dir.appendingPathComponent("providers", isDirectory: true)
            try FileManager.default.createDirectory(at: providersDirectory, withIntermediateDirectories: true)
            let providerID = ProviderID(rawValue: "queued-after-cancel-provider")
            try AgentProvidersConfig(
                providers: [AgentProvider(id: providerID, label: "Stub", enabled: true, isDefault: true)],
                selectedModelIds: [providerID.rawValue: ModelID(rawValue: "queued-after-cancel-model")]
            ).save(to: providersDirectory)

            // The durable chat the view opens; the daemon reads the same file.
            session.store.beginNewChat()
            guard case .chat(let chatID) = session.store.selection else {
                throw FixtureError.noChatRoute
            }
            let dbURL = try #require(
                try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    .first { $0.pathExtension == "sqlite" })
            let daemonStore = try GRDBWikiStore(databaseURL: dbURL)

            let runtime = StubControllerRuntime()
            let (envelopes, continuation) = AsyncStream.makeStream(of: QueueEventEnvelope.self)
            let controller = try DaemonChatController(
                chatID: chatID,
                wikiID: session.wikiID,
                store: daemonStore,
                runtime: runtime,
                pushEvent: { continuation.yield($0) })
            let coordinator = ChatDaemonCoordinator(
                client: ControllerBridgeChatCommands(controller: controller),
                eventSink: DaemonQueueEventSink(),
                providersConfigurationDirectory: providersDirectory)
            // Serialized envelope delivery, as the XPC event sink provides.
            let router = Task { @MainActor in
                for await envelope in envelopes {
                    coordinator.ingestForTesting(envelope)
                }
            }
            return Fixture(
                session: session,
                chatID: chatID,
                daemonStore: daemonStore,
                runtime: runtime,
                controller: controller,
                coordinator: coordinator,
                envelopeContinuation: continuation,
                router: router)
        }

        func tearDown() {
            envelopeContinuation.finish()
            router.cancel()
        }

        func mount() -> (NSHostingController<RouteView>, NSWindow) {
            _ = ChatQueuedMessageAfterCancelHostedTests.app
            let capture = capture
            let hosting = NSHostingController(rootView: RouteView(
                store: store,
                session: session,
                coordinator: coordinator,
                onProps: { capture.record($0) }))
            let window = NSWindow(contentViewController: hosting)
            window.setContentSize(NSSize(width: 1000, height: 700))
            window.orderFront(nil)
            return (hosting, window)
        }

        var remoteSession: RemoteChatSession {
            coordinator.session(wikiID: session.wikiID, for: chatID)
        }

        /// Sends the first turn through the real composer and waits until the
        /// daemon reports it as answering.
        func submitFirstTurnAndWaitUntilAnswering() async throws {
            let mounted = await waitUntil { self.capture.latest != nil }
            try #require(mounted, "the composer must render")
            // Hydration installs the real daemon projection first.
            let hydrated = await waitUntil { self.remoteSession.syncState?.projection != nil }
            try #require(hydrated, "the view must hydrate from the daemon")

            store.draftChatMessage = Self.firstText
            try #require(capture.latest).onSubmit()
            let submitted = await waitUntilAsync {
                await self.runtimeSubmittedTexts() == [Self.firstText]
            }
            try #require(submitted, "the first turn must reach the runtime")
            let answering = await waitUntil { self.remoteSession.runState == .answering }
            try #require(answering, "the session must report the first turn as answering")
        }

        func persistedTurnTexts() -> [String] {
            do {
                return try daemonStore.listPersistedChatTurns(chatID: chatID).map(\.submission.userText)
            } catch {
                Issue.record("reading durable turns failed: \(error)")
                return []
            }
        }

        func runtimeSubmittedTexts() async -> [String] {
            await runtime.snapshot().submitCalls.map(\.userText)
        }

        /// Bounded condition wait (never blocks the cooperative pool).
        func waitUntil(
            timeout: Duration = .seconds(10),
            _ condition: @MainActor () -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while condition() == false {
                guard ContinuousClock.now < deadline else { return false }
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    // Cancelled by the suite time limit: report the condition.
                    return condition()
                }
            }
            return true
        }

        func waitUntilAsync(
            timeout: Duration = .seconds(10),
            _ condition: @MainActor () async -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while await condition() == false {
                guard ContinuousClock.now < deadline else { return false }
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return await condition()
                }
            }
            return true
        }

        enum FixtureError: Error {
            case noChatRoute
        }
    }
}

/// The XPC hop, replaced by direct calls into a real `DaemonChatController`.
private final class ControllerBridgeChatCommands: ChatDaemonCommands, @unchecked Sendable {
    enum BridgeError: Error {
        case unsupported(String)
    }

    private let controller: DaemonChatController

    init(controller: DaemonChatController) {
        self.controller = controller
    }

    func submitChatTurn(_ request: ChatSubmitRequest) async throws -> ChatID {
        try await controller.submit(request)
    }

    func stopChat(wikiID: WikiID, chatID: ChatID) async throws {
        await controller.cancel(turnID: nil)
    }

    func chatSessionState(wikiID: WikiID, chatID: ChatID) async throws -> ChatSyncSnapshot {
        try await controller.chatSyncSnapshot()
    }

    func chatDiagnosticSnapshot(_ request: ChatDiagnosticSnapshotRequest) async throws -> ChatDiagnosticSnapshotEnvelope {
        throw BridgeError.unsupported("chatDiagnosticSnapshot")
    }

    func resetChatDiagnostics(_ request: ChatDiagnosticResetRequest) async throws {
        throw BridgeError.unsupported("resetChatDiagnostics")
    }

    func resolveChatPermission(_ request: ChatPermissionResolveRequest) async throws {
        throw BridgeError.unsupported("resolveChatPermission")
    }

    func setChatConfigOption(_ request: ChatConfigOptionRequest) async throws {
        throw BridgeError.unsupported("setChatConfigOption")
    }
}

// MARK: - Minimal session stubs

@MainActor
private final class QueuedAfterCancelStubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(pdfData: Data, filename: String, onProgress: (@Sendable (String) -> Void)?) async throws -> String { "" }
}

private struct QueuedAfterCancelStubExtractionProvider: QueueExtractionProvider {
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

private func makeQueuedAfterCancelQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let provider = QueuedAfterCancelStubExtractionProvider()
    let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}
#endif
