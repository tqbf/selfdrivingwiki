#if os(macOS)
import AppKit
import Darwin
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

/// Quiet-CPU contract guard for the 2026-10-03 live regression: opening a
/// persisted chat whose last turn died mid-run (two tool calls stranded in
/// `running` status when the app + daemon restarted) pegged the live app's
/// main thread at 100% CPU inside `ChatDetailView` body evaluation — the
/// "click a chat, see nothing but a spinning wheel" beachball.
///
/// HONEST SCOPE: this harness does NOT reproduce the live frame-rate loop
/// (it stayed quiet even with both hardening fixes reverted). The live-only
/// trigger was never isolated offline. What this suite pins is the contract
/// that the real `ChatDetailView`, hosted in a real `NSWindow` with the real
/// fixture shape (140 transcript items, 106 tool calls, stranded `running`
/// calls, a `WikiDetailView.chatSurface`-style parent that resolves the
/// session through the coordinator each body pass), settles to near-idle CPU.
/// The unit-level invalidation contracts live in
/// `ChatDaemonCoordinatorTests.repeatedSessionLookupEmitsNoObservationInvalidation`
/// and `ComposerTextViewTests` (pending height write lifecycle).
///
/// The oracle is process CPU time versus wall time while the main run loop is
/// pumped: a settled view burns almost no CPU; a self-invalidating render
/// loop saturates one core (ratio → 1.0). No daemon, no network, no paid
/// calls — the store is seeded from the real transcript's shape.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ChatStuckRunningBeachballReproTests {
    private static let pumpDuration: TimeInterval = 3.0
    /// A settled hosted view must stay far below half a core. The live bug
    /// measured ~1.0 (a full core) for 15+ minutes.
    private static let maximumQuietCPURatio = 0.5

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    // MARK: - Fixture shape (mirrors chat 01M41RK6…: 140 items, one turn)

    /// One turn: user prompt, 32 reasoning blocks interleaved with 106 tool
    /// calls (103 completed, 1 failed, `strandedRunning` stuck in `running`),
    /// one final assistant message — the durable transcript the live chat
    /// left behind when its run was cut off by the app restart.
    private static func makeStrandedItems(strandedRunning: Int, textScale: Int = 1) -> [ChatTranscriptItem] {
        let turnID = ChatTurnID(rawValue: "repro-turn")
        var items: [ChatTranscriptItem] = []
        var messageOrdinal = 0
        var toolOrdinal = 0

        func reasoning(_ text: String) {
            items.append(.message(ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: "repro-message-\(messageOrdinal)"),
                turnID: turnID,
                role: .reasoning,
                text: String(repeating: text, count: textScale),
                createdAt: .distantPast
            )))
            messageOrdinal += 1
        }

        func toolCall(_ name: String, status: ChatToolCallStatus, detail: String, output: String) {
            items.append(.toolCall(ChatTranscriptToolCallItem(
                toolCallID: ToolCallID(rawValue: "repro-tool-\(toolOrdinal)"),
                turnID: turnID,
                toolName: name,
                status: status,
                detail: String(repeating: detail, count: textScale),
                output: String(repeating: output, count: textScale),
                permissionRequestID: nil,
                updatedAt: .distantPast
            )))
            toolOrdinal += 1
        }

        items.append(.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "repro-prompt"),
            turnID: turnID,
            role: .user,
            text: "can you run extraction for chapters 2 through 5?",
            createdAt: .distantPast
        )))

        let toolNames = ["Bash", "Read", "Grep", "Edit", "Bash", "WebSearch"]
        let details = [
            "/bin/zsh -lc \"sed -n '1,240p' WIKI_STATE.md\"",
            "plans/page-source-id-separation.md",
            "ChatToolCallGroupSummary",
            "Sources/WikiFS/Chats/ChatDetailView.swift",
        ]
        let outputs = [
            "Status: Approved\nAction: exec /bin/zsh -lc \"sed -n '1,240p' WIKI_STATE.md\"\nRisk: low",
            "# Page and source IDs are separate namespaces",
            "Sources/WikiFS/Chats/ChatToolCallGroupSummary.swift:60:33",
            "1 file changed",
        ]
        var strandedRemaining = strandedRunning
        for index in 0..<106 {
            let status: ChatToolCallStatus
            if strandedRemaining > 0 && index % 50 == 25 {
                status = .running
                strandedRemaining -= 1
            } else if index == 105 {
                status = .failed
            } else {
                status = .completed
            }
            toolCall(
                toolNames[index % toolNames.count],
                status: status,
                detail: details[index % details.count],
                output: outputs[index % outputs.count])
            if index % 3 == 2 {
                reasoning("Planning extraction of chapters 2-5: step \(index) of the sweep.")
            }
        }
        reasoning("Final pass before reporting results.")

        items.append(.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "repro-answer"),
            turnID: turnID,
            role: .assistant,
            text: "Extraction queued for chapters 2 through 5.",
            createdAt: .distantPast
        )))
        return items
    }

    // MARK: - CPU oracle

    private static func processCPUTime() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    /// Pump the main run loop so SwiftUI updates actually run, and return
    /// (wall, cpu) seconds for the window.
    private func pumpMainThread(for duration: TimeInterval) -> (wall: TimeInterval, cpu: TimeInterval) {
        let cpuStart = Self.processCPUTime()
        let wallStart = Date()
        let deadline = wallStart.addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let cpu = Self.processCPUTime() - cpuStart
        let wall = Date().timeIntervalSince(wallStart)
        return (wall, cpu)
    }

    // MARK: - Host harness

    /// Mirrors `WikiDetailView.chatSurface`: the PARENT body resolves the
    /// remote session through the coordinator on every evaluation, exactly
    /// like the live app, so the harness exercises the same per-body-pair
    /// observable reads and writes the live window performs. (The live
    /// frame-rate loop did not reproduce even through this wrapper; this
    /// keeps the harness structurally faithful to the live tree.)
    private struct HostedChatSurfaceParent: View {
        @Bindable var store: WikiStoreModel
        let chatID: ChatID
        let session: ProfileWikiSession
        let coordinator: ChatDaemonCoordinator
        let inspector: WindowRightInspectorController

        var body: some View {
            ChatDetailView(
                chatID: chatID,
                store: store,
                remoteSession: coordinator.session(wikiID: session.wikiID, for: chatID),
                coordinator: coordinator,
                session: session,
                fileProvider: FileProviderFacade()
            )
            .environment(inspector)
        }
    }

    private func makeFixture() throws -> (ProfileWikiSession, ChatDaemonCoordinator, StubChatDaemonCommands, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-stuck-running-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = WikiDescriptor.make(displayName: "Chat Stuck Running Repro")
        let extractionCoordinator = ExtractionCoordinator(
            containerDirectory: directory,
            localExtractorFactory: { ChatStuckRunningStubExtractor() }
        )
        let session = try ProfileWikiSession(
            testFixtureWikiID: descriptor.id,
            descriptor: descriptor,
            containerDirectory: directory,
            extractionCoordinator: extractionCoordinator,
            queueEngine: try makeStubQueueEngine(),
            extractionProvider: ChatStuckRunningStubExtractionProvider()
        )
        let daemon = StubChatDaemonCommands()
        let coordinator = ChatDaemonCoordinator(
            client: daemon,
            eventSink: DaemonQueueEventSink()
        )
        return (session, coordinator, daemon, directory)
    }

    private func makeStubQueueEngine() throws -> QueueEngine {
        let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let provider = ChatStuckRunningStubExtractionProvider()
        let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
        return QueueEngine(store: store, workerFactory: factory)
    }

    /// Host the real chat surface over a seeded transcript, rehydrate with the
    /// snapshot shape the live daemon returned (no live controller, so the
    /// daemon synthesizes a persisted-only state), then measure main-thread
    /// CPU while the run loop pumps.
    private func measureHostedChatCPURatio(items: [ChatTranscriptItem]) async throws -> Double {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app

        let (session, coordinator, daemon, directory) = try makeFixture()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove hosted chat fixture: \(error)")
            }
        }
        let store = session.store
        let chat = try store.internalStore.createChat(kind: .edit, title: "Stuck Running Repro")
        _ = try store.internalStore.appendChatTranscriptItems(chatID: chat.id, items: items)
        store.reloadChats()
        store.openTab(.chat(chat.id))

        let inspector = WindowRightInspectorController()
        let hosting = NSHostingController(rootView: HostedChatSurfaceParent(
            store: store,
            chatID: chat.id,
            session: session,
            coordinator: coordinator,
            inspector: inspector
        ))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1_200, height: 760))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // Let the first render + persisted transcript load settle.
        let settled = await waitUntil {
            inspector.registration?.subject == .chat(chat.id)
        }
        #expect(settled, "the chat outline must register before measuring")
        for _ in 0..<8 {
            await Task.yield()
        }

        // The live daemon held no controller for this chat, so its
        // chatSessionState reply was a persisted-only snapshot: an empty
        // overlay that successfully hydrated the mirror.
        daemon.sessionState = ChatSyncSnapshot(projection: ChatSyncProjection(
            chatID: chat.id,
            generation: ChatSessionGenerationID(rawValue: "persisted-only"),
            lifecycle: .ready,
            activeTurn: nil,
            queuedTurns: [],
            attention: .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            transcriptOverlay: [],
            committedCursor: ChatTranscriptCursor(rawValue: Int64(items.count)),
            lastIncludedSequence: .initial,
            pendingPermission: nil,
            runMetadata: .empty
        ))
        await coordinator.rehydrate(wikiID: session.wikiID, chatID: chat.id)
        for _ in 0..<8 {
            await Task.yield()
        }

        let (wall, cpu) = pumpMainThread(for: Self.pumpDuration)
        return cpu / max(wall, 0.001)
    }

    @Test func settledChatWithoutStrandedRunningCallsStaysQuiet() async throws {
        let ratio = try await measureHostedChatCPURatio(items: Self.makeStrandedItems(strandedRunning: 0))
        #expect(
            ratio < Self.maximumQuietCPURatio,
            "a settled chat must not saturate the main thread (cpu ratio \(ratio))")
    }

    @Test func strandedRunningToolCallsMustNotSaturateMainThread() async throws {
        let ratio = try await measureHostedChatCPURatio(items: Self.makeStrandedItems(strandedRunning: 2))
        #expect(
            ratio < Self.maximumQuietCPURatio,
            "stranded running tool calls must not peg the main thread (cpu ratio \(ratio)) — this is the 2026-10-03 live beachball")
    }

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
}

@MainActor
private final class ChatStuckRunningStubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "" }
}

private struct ChatStuckRunningStubExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?,
        transcriptionIntent: QueueItemPayload.TranscriptionIntent?    ) async throws -> ExtractionResolution? { nil }
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
    @discardableResult
    func persistSpeechExtraction(
        wikiID: WikiID, sourceID: SourceID, outcome: SpeechOutcome
    ) async throws -> QueueExtractionOutputReference? { nil }
    func enqueueFollowOnExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        acquiredContentVersionID: SourceVersionID,
        dedupeKey: QueueItemDedupeKey
    ) async throws {}
}
#endif
