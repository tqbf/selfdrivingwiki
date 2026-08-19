#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

/// End-to-end regression for streamed assistant text (daemon → wire → client).
///
/// The daemon rewrites a streaming message's committed row IN PLACE (same
/// transcript cursor), so the committed cursor does not advance between the
/// first chunk and the final text. A client that loaded that row after the
/// first chunk therefore holds a prefix, and any projection that drops the live
/// overlay used to expose it — the response rendered cut off mid-sentence.
@MainActor
struct ChatStreamedTextCommitRefreshTests {
    private static let firstChunk = "Hello! What"
    private static let secondChunk = " would you like to do with the wiki today?"
    private static var fullText: String { firstChunk + secondChunk }

    @Test func streamedAssistantTextSurvivesReHydration() async throws {
        let harness = try StreamingHarness()
        defer { harness.tearDown() }

        try await harness.streamOneAssistantTurn(
            commandID: "command-stream",
            turnID: "turn-stream"
        )
        #expect(harness.assistantText == Self.fullText)

        // A re-hydrated snapshot (view re-appear, reconnect, gap recovery)
        // carries no overlay: the client must not fall back to the committed
        // copy it loaded mid-stream.
        harness.session.hydrate(from: try await harness.controller.chatSyncSnapshot())
        try await harness.drainClientEffects()

        #expect(harness.assistantText == Self.fullText)
    }

    @Test func earlierTurnKeepsFullStreamedTextWhenTheNextTurnIsSubmitted() async throws {
        let harness = try StreamingHarness()
        defer { harness.tearDown() }

        try await harness.streamOneAssistantTurn(
            commandID: "command-first",
            turnID: "turn-first"
        )
        #expect(harness.assistantText == Self.fullText)

        // The next submission commits a new user row, which advances the
        // committed cursor and replaces the overlay.
        _ = try await harness.controller.submit(
            harness.controllerHarness.makeSubmitRequest(
                submission: harness.controllerHarness.makeSubmission(
                    commandID: "command-second",
                    turnID: "turn-second",
                    text: "say a full sentence"
                )
            )
        )
        try await harness.drainClientEffects()

        #expect(harness.assistantText == Self.fullText)
    }

    /// Wires a real `DaemonChatController` to a real `RemoteChatSession` over
    /// the same serialized envelope delivery the XPC sink provides.
    @MainActor
    private final class StreamingHarness {
        let controllerHarness: ControllerHarness
        let controller: DaemonChatController
        let session: RemoteChatSession
        private let envelopeContinuation: AsyncStream<QueueEventEnvelope>.Continuation
        private let router: Task<Void, Never>

        init() throws {
            let controllerHarness = try ControllerHarness()
            let store = controllerHarness.store
            let chatID = controllerHarness.chat.id
            let session = RemoteChatSession(chatID: .chat(chatID))
            session.installHistoryLoader { after in
                try store.readChatTranscriptPage(chatID: chatID, after: after, limit: 200)
            }

            let (envelopes, continuation) = AsyncStream.makeStream(of: QueueEventEnvelope.self)
            let controller = try DaemonChatController(
                chatID: chatID,
                wikiID: WikiID(rawValue: "wiki-controller"),
                store: store,
                providersConfigurationDirectory: controllerHarness.rootDirectory,
                runtime: controllerHarness.runtime,
                pushEvent: { continuation.yield($0) }
            )
            session.onRequestAuthoritativeSnapshot = { try await controller.chatSyncSnapshot() }

            self.controllerHarness = controllerHarness
            self.controller = controller
            self.session = session
            self.envelopeContinuation = continuation
            self.router = Task { @MainActor in
                for await envelope in envelopes {
                    session.ingest(envelope)
                }
            }
        }

        func tearDown() {
            envelopeContinuation.finish()
            router.cancel()
        }

        var assistantText: String? {
            session.displayTranscript.rows.compactMap { row -> String? in
                guard case .assistantMessage(_, _, let text, _, _) = row else { return nil }
                return text
            }.last
        }

        /// Submits one turn, streams the canned two-chunk reply exactly as the
        /// provider does, and completes it.
        func streamOneAssistantTurn(commandID: String, turnID: String) async throws {
            session.hydrate(from: try await controller.chatSyncSnapshot())
            let submission = controllerHarness.makeSubmission(commandID: commandID, turnID: turnID)
            _ = try await controller.submit(controllerHarness.makeSubmitRequest(submission: submission))

            var translator = AgentEventTranscriptTranslator()
            await controllerHarness.runtime.emit(.transcript(
                translator.translate([.assistantTextDelta(firstChunk)], turnID: submission.turnID)
            ))
            try await waitForAssistantText(firstChunk)

            await controllerHarness.runtime.emit(.transcript(
                translator.translate([.assistantTextDelta(secondChunk)], turnID: submission.turnID)
            ))
            try await waitForAssistantText(firstChunk + secondChunk)

            await controllerHarness.runtime.emit(.turnCompleted(submission.turnID))
            try await waitForClearedOverlay()
            try await drainClientEffects()
        }

        private var firstChunk: String { ChatStreamedTextCommitRefreshTests.firstChunk }
        private var secondChunk: String { ChatStreamedTextCommitRefreshTests.secondChunk }

        private func waitForAssistantText(_ expected: String) async throws {
            for _ in 0..<100 {
                if assistantText == expected { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("timed out waiting for streamed text; last=\(String(describing: assistantText))")
        }

        private func waitForClearedOverlay() async throws {
            for _ in 0..<100 {
                if await controller.typedSnapshot().transientTranscriptOverlay.isEmpty { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("timed out waiting for the daemon overlay to clear")
        }

        /// Lets every queued client effect (committed-history paging) finish.
        func drainClientEffects() async throws {
            for _ in 0..<20 {
                await Task.yield()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}
#endif
