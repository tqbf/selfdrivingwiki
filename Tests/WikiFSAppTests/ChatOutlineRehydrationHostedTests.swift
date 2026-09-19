#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

/// Hosts the real chat detail and right-inspector outline through AppKit. This
/// pins the live rehydration frame that used to replace a populated durable
/// outline with an empty session projection.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatOutlineRehydrationHostedTests {
    private static let outlineWidth: CGFloat = 280
    private static let minimumBrightOutlinePixels = 100
    private static let brightChannelThreshold = 180
    private static let renderSettleYields = 4

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private struct HostedChatWithInspector: View {
        @Bindable var store: WikiStoreModel
        let chatID: ChatID
        let session: ProfileWikiSession
        let coordinator: ChatDaemonCoordinator
        let inspector: WindowRightInspectorController

        var body: some View {
            HStack(spacing: 0) {
                ChatDetailView(
                    chatID: chatID,
                    store: store,
                    remoteSession: coordinator.session(wikiID: session.wikiID, for: chatID),
                    coordinator: coordinator,
                    session: session,
                    fileProvider: FileProviderFacade()
                )
                if let registration = inspector.registration {
                    InspectorOutlineView(payload: registration.outline, onSelect: { _ in })
                        .frame(width: ChatOutlineRehydrationHostedTests.outlineWidth)
                }
            }
            .environment(inspector)
        }
    }

    @Test func outlineRemainsRenderedWhenLiveRehydrationProjectionIsEmpty() async throws {
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
        let chat = try store.internalStore.createChat(
            kind: .edit,
            title: "Outline Rehydration"
        )
        let turnID = ChatTurnID(rawValue: "outline-turn")
        let persisted = try store.internalStore.appendChatTranscriptItems(
            chatID: chat.id,
            items: [
                .message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: "outline-question"),
                    turnID: turnID,
                    role: .user,
                    text: "Why did the outline disappear?",
                    createdAt: .distantPast
                )),
                .message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: "outline-answer"),
                    turnID: turnID,
                    role: .assistant,
                    text: "The live history mirror was temporarily empty.",
                    createdAt: .distantPast
                )),
            ]
        )
        #expect(persisted.count == 2)
        let transcriptPage = store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 10)
        #expect(transcriptPage.items.count == 2)
        store.reloadChats()
        store.openTab(.chat(chat.id))

        var acceptedChatRegistrations: [RightSidebarRegistration] = []
        let inspector = WindowRightInspectorController { registration in
            guard registration.subject == .chat(chat.id) else { return }
            acceptedChatRegistrations.append(registration)
        }
        let hosting = NSHostingController(rootView: HostedChatWithInspector(
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

        let durableOutlineRegistered = await waitUntil {
            inspector.registration?.subject == .chat(chat.id)
        }
        #expect(durableOutlineRegistered, "the durable chat outline must register before rehydration")
        let firstChatRegistration = try #require(acceptedChatRegistrations.first)
        // Value oracle: the FIRST accepted chat registration must already
        // carry the durable transcript as a non-empty chatTurns payload.
        if case .chatTurns(let firstTurns) = firstChatRegistration.outline.content {
            #expect(
                !firstTurns.isEmpty,
                "the first accepted chat payload must contain the durable turns")
        } else {
            Issue.record("chat outline payload must carry chatTurns content")
        }
        let firstOutlineHosting = NSHostingController(rootView: InspectorOutlineView(
            payload: firstChatRegistration.outline,
            onSelect: { _ in }))
        let firstOutlineWindow = NSWindow(contentViewController: firstOutlineHosting)
        firstOutlineWindow.setContentSize(NSSize(width: Self.outlineWidth, height: 760))
        firstOutlineWindow.orderFront(nil)
        defer { firstOutlineWindow.orderOut(nil) }
        await settleRendering()
        let firstRegistrationBrightPixels = try brightOutlinePixelCount(
            in: firstOutlineWindow.contentView,
            outlineWidth: Self.outlineWidth
        )
        #expect(
            firstRegistrationBrightPixels >= Self.minimumBrightOutlinePixels,
            "the first accepted chat registration must already contain the durable outline"
        )

        await settleRendering()
        let brightPixelsBefore = try brightOutlinePixelCount(in: window.contentView)
        #expect(
            brightPixelsBefore >= Self.minimumBrightOutlinePixels,
            "the pre-rehydration snapshot must visibly contain outline text"
        )

        daemon.sessionState = emptyLiveSnapshot(chatID: chat.id)
        await coordinator.rehydrate(wikiID: session.wikiID, chatID: chat.id)

        let settledAfterRehydration = await waitUntil {
            coordinator.session(wikiID: session.wikiID, for: chat.id).runState.isLive
                && inspector.registration?.subject == .chat(chat.id)
        }
        #expect(settledAfterRehydration, "the chat outline registration must survive empty live rehydration")
        await settleRendering()
        let brightPixelsAfter = try brightOutlinePixelCount(in: window.contentView)
        #expect(
            brightPixelsAfter >= brightPixelsBefore / 2,
            "the visible outline text must survive the empty live rehydration frame"
        )

        daemon.sessionState = incompleteLiveSnapshot(chatID: chat.id)
        await coordinator.rehydrate(wikiID: session.wikiID, chatID: chat.id)

        let settledAfterIncompleteProjection = await waitUntil {
            coordinator.session(wikiID: session.wikiID, for: chat.id).displayProjectionInput.items.count == 1
                && inspector.registration?.subject == .chat(chat.id)
        }
        #expect(
            settledAfterIncompleteProjection,
            "the chat outline registration must refresh for an incomplete live projection"
        )
        await settleRendering()
        let brightPixelsAfterIncompleteProjection = try brightOutlinePixelCount(in: window.contentView)
        #expect(
            brightPixelsAfterIncompleteProjection >= brightPixelsBefore / 2,
            "the durable outline must remain visible until live history contains a prompt-bearing turn"
        )
    }

    private func makeFixture() throws -> (
        ProfileWikiSession,
        ChatDaemonCoordinator,
        StubChatDaemonCommands,
        URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-outline-hosted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var fixtureCreated = false
        defer {
            if !fixtureCreated {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    Issue.record("Failed to clean incomplete hosted chat fixture: \(error)")
                }
            }
        }
        let descriptor = WikiDescriptor.make(displayName: "Chat Outline Hosted Test")
        let extractionCoordinator = ExtractionCoordinator(
            containerDirectory: directory,
            localExtractorFactory: { ChatOutlineStubExtractor() }
        )
        let session = try ProfileWikiSession(
            testFixtureWikiID: descriptor.id,
            descriptor: descriptor,
            containerDirectory: directory,
            extractionCoordinator: extractionCoordinator,
            queueEngine: try makeChatOutlineTestQueueEngine(),
            extractionProvider: ChatOutlineStubExtractionProvider()
        )
        let daemon = StubChatDaemonCommands()
        let coordinator = ChatDaemonCoordinator(
            client: daemon,
            eventSink: DaemonQueueEventSink()
        )
        fixtureCreated = true
        return (session, coordinator, daemon, directory)
    }

    private func emptyLiveSnapshot(chatID: ChatID) -> ChatSyncSnapshot {
        ChatSyncSnapshot(projection: ChatSyncProjection(
            chatID: chatID,
            generation: ChatSessionGenerationID(rawValue: "empty-live-rehydration"),
            lifecycle: .ready,
            activeTurn: nil,
            queuedTurns: [],
            attention: .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            transcriptOverlay: [],
            committedCursor: .zero,
            lastIncludedSequence: .initial,
            pendingPermission: nil,
            runMetadata: .empty
        ))
    }

    private func incompleteLiveSnapshot(chatID: ChatID) -> ChatSyncSnapshot {
        let turnID = ChatTurnID(rawValue: "incomplete-live-turn")
        return ChatSyncSnapshot(projection: ChatSyncProjection(
            chatID: chatID,
            generation: ChatSessionGenerationID(rawValue: "incomplete-live-rehydration"),
            lifecycle: .ready,
            activeTurn: nil,
            queuedTurns: [],
            attention: .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            transcriptOverlay: [
                .message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: "incomplete-live-answer"),
                    turnID: turnID,
                    role: .assistant,
                    text: "The live transcript is present before its prompt-bearing history.",
                    createdAt: .distantPast
                )),
            ],
            committedCursor: .zero,
            lastIncludedSequence: ChatUpdateSequence(rawValue: 1),
            pendingPermission: nil,
            runMetadata: .empty
        ))
    }

    private func settleRendering() async {
        for _ in 0..<Self.renderSettleYields {
            await Task.yield()
        }
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

    private func brightOutlinePixelCount(
        in view: NSView?,
        outlineWidth: CGFloat = Self.outlineWidth
    ) throws -> Int {
        let view = try #require(view)
        view.layoutSubtreeIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 1
        let outlineBounds = NSRect(
            x: view.bounds.maxX - outlineWidth,
            y: view.bounds.minY,
            width: outlineWidth,
            height: view.bounds.height
        )
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: outlineBounds))
        view.cacheDisplay(in: outlineBounds, to: bitmap)
        guard let data = bitmap.bitmapData else {
            Issue.record("The hosted outline bitmap has no pixel buffer.")
            return 0
        }
        guard bitmap.bitsPerSample == 8, bitmap.bitsPerPixel >= 24 else {
            Issue.record("The hosted outline bitmap must expose 8-bit RGB channels.")
            return 0
        }
        let bytesPerPixel = (bitmap.bitsPerPixel + 7) / 8
        let width = Int(outlineWidth * scale)
        var brightPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            let row = data.advanced(by: y * bitmap.bytesPerRow)
            for x in 0..<min(width, bitmap.pixelsWide) {
                let pixel = row.advanced(by: x * bytesPerPixel)
                let red = Int(pixel[0])
                let green = Int(pixel[1])
                let blue = Int(pixel[2])
                if red >= Self.brightChannelThreshold,
                   green >= Self.brightChannelThreshold,
                   blue >= Self.brightChannelThreshold {
                    brightPixels += 1
                }
            }
        }
        return brightPixels
    }
}

@MainActor
private final class ChatOutlineStubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "" }
}

private struct ChatOutlineStubExtractionProvider: QueueExtractionProvider {
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
    func persistAttachmentExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: AttachmentExtractionResolution,
        outcome: AttachmentFetchOutcome
    ) async throws -> QueueExtractionOutputReference? { nil }
    func enqueueFollowOnExtraction(wikiID: WikiID, sourceID: SourceID) async throws {}
}

private func makeChatOutlineTestQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let provider = ChatOutlineStubExtractionProvider()
    let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}
#endif
