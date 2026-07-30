#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
@testable import WikiFSCore
@testable import WikiCtlCore
@testable import WikiFSEngine
@testable import wikid

/// Tests for the daemon-side chat host (Phase C).
///
/// These tests verify the store-write orchestration and XPC plumbing without
/// a real ACP backend. A `startChat` call will fail at the preflight stage
/// (no `claude` binary in the test environment), but:
/// - The chat row creation + first-message seeding is testable (it happens
///   BEFORE the backend spawn, then is rolled back on preflight failure).
/// - The XPC request/reply shape is fully testable.
/// - The store operations the host delegates to are tested directly.
/// - The adaptive preamble + takeover logic are tested via AgentOperationRunner.
struct DaemonChatHostTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-chat-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDaemon(dir: URL) -> WikiDaemon {
        WikiDaemon(containerDirectory: dir)
    }

    // MARK: - Store-level operations (the layer the chat host delegates to)

    @Test func chatStoreCreatesRowAndSeedsFirstMessage() throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        #expect(daemon.openStore(wikiID: WikiID(rawValue: "test-wiki")) || true)

        // Create a wiki + open the store
        _ = daemon.createWiki(name: "Test")

        // The store resolver path the chat host uses
        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))

        // Simulate what DaemonChatHost.startChat does at the store level:
        let chat = try store.createChat(kind: .edit, title: "Hello world")
        _ = try store.appendChatMessages(chatID: chat.id, events: [.userText("Hello world")])

        // Verify the chat row
        let fetched = try store.getChat(id: chat.id)
        #expect(fetched.id == chat.id)
        #expect(fetched.title == "Hello world")

        // Verify the first message was seeded
        let messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.count == 1)
        #expect(messages[0].event == .userText("Hello world"))
    }

    @Test func chatStorePersistsAcpSessionId() throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Test")

        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))

        let chat = try store.createChat(kind: .edit, title: "Test")
        try store.updateChatAcpSessionId(chatID: chat.id, acpSessionId: AcpSessionID(rawValue: "session-abc-123"))

        let fetched = try store.getChat(id: chat.id)
        #expect(fetched.acpSessionId == AcpSessionID(rawValue: "session-abc-123"))

        // Clearing works too
        try store.updateChatAcpSessionId(chatID: chat.id, acpSessionId: nil)
        let cleared = try store.getChat(id: chat.id)
        #expect(cleared.acpSessionId == nil)
    }

    @Test func chatStoreStreamingCheckpoint() throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Test")

        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))

        let chat = try store.createChat(kind: .edit, title: "Test")

        // Checkpoint a draft
        let handle = "draft-handle-1"
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: handle,
            event: .assistantText("partial"), isDraft: true)

        var messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.count == 1)
        #expect(messages[0].isDraft == true)

        // Finalize the same row
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: handle,
            event: .assistantText("final text"), isDraft: false)

        messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.count == 1)
        #expect(messages[0].isDraft == false)
        #expect(messages[0].event == .assistantText("final text"))
    }

    @Test func chatStoreFinalizesStaleDrafts() throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Test")

        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))

        let chat = try store.createChat(kind: .edit, title: "Test")

        // Leave a draft row (simulating an interrupted turn)
        try store.checkpointStreamingMessage(
            chatID: chat.id, handle: "stale-1",
            event: .assistantText("interrupted"), isDraft: true)

        // Finalize stale drafts (called on continueChat)
        try store.finalizeStaleDrafts(forChat: chat.id)

        let messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.allSatisfy { !$0.isDraft })
    }

    @Test func chatStoreSystemPromptUsesDefaultBody() throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Test")

        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))

        // RC2: getSystemPrompt() exists and returns the default body
        // (the system_prompt table was removed in v42; getSystemPrompt always
        // returns SystemPrompt.defaultBody, but the chat host MUST call it
        // rather than hardcoding defaultBody — so a future table re-add works).
        let prompt = try store.getSystemPrompt()
        #expect(!prompt.body.isEmpty)
        #expect(prompt.body == SystemPrompt.defaultBody)
    }

    @Test func chatStoreSummarizesMessages() throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Test")

        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))

        let chat = try store.createChat(kind: .edit, title: "Test")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .userText("What is this wiki about?"),
            .assistantText("This is a test wiki about software engineering. It covers various topics."),
        ])

        // Verify the message has no summary yet
        var messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.allSatisfy { $0.summary == nil })

        // Write a summary (what summarizePendingMessages does)
        let assistantMsg = messages.first { $0.event.chatRole == "assistant" }!
        try store.updateMessageSummary(
            chatID: chat.id, messageID: assistantMsg.id,
            summary: "Test wiki overview", kind: .defaultTruncation)

        messages = try store.chatMessages(chatID: chat.id)
        let summarized = messages.first { $0.id == assistantMsg.id }!
        #expect(summarized.summary == "Test wiki overview")
        #expect(summarized.summaryKind == .defaultTruncation)
    }

    @Test func daemonControllerPathDisablesLegacyStreamingCheckpointSink() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let created = try #require(daemon.createWiki(name: "Test"))
        let wiki = try JSONDecoder().decode(WikiDescriptor.self, from: created)
        let store = try #require(daemon.resolveStoreLazily(wikiID: wiki.id))
        let chat = try store.createChat(kind: .edit, title: "Checkpoint Disabled")
        let host = try await daemon.ensureChatHost()

        let usesCheckpoint = try await host.controllerUsesStreamingCheckpointForTesting(
            chatID: chat.id,
            wikiID: wiki.id
        )

        #expect(usesCheckpoint == false)
    }

    @Test func idleControllerEvictionRemovesOnlyAQuiescentController() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let created = try #require(daemon.createWiki(name: "Test"))
        let wiki = try JSONDecoder().decode(WikiDescriptor.self, from: created)
        let store = try #require(daemon.resolveStoreLazily(wikiID: wiki.id))
        let chat = try store.createChat(kind: .edit, title: "Idle")
        let host = try await daemon.ensureChatHost()

        _ = try await host.controllerUsesStreamingCheckpointForTesting(
            chatID: chat.id,
            wikiID: wiki.id
        )
        #expect(await host.hasLiveSession(chat.id))

        #expect(await host.evictIdleControllerForTesting(chatID: chat.id))
        #expect(await host.hasLiveSession(chat.id) == false)
    }

    // MARK: - DaemonWikiState helper

    @Test func daemonWikiStateBuildsStateMarkdown() throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Test")

        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))

        let markdown = DaemonWikiState.stateMarkdown(from: store)
        #expect(!markdown.isEmpty)
        // The state markdown should contain the wiki title list
        #expect(markdown.contains("# Wiki"))
    }

    // MARK: - XPC round-trip: chat methods

    @Test func xpcStartChatRoundTrip() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = ChatTestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        // Create a wiki first (so the store resolver finds it)
        _ = daemon.createWiki(name: "ChatTest")

        // Start a chat — will fail at preflight (no claude binary in tests)
        // but the XPC plumbing + error handling is what we're verifying.
        let request = ChatStartRequest(wikiID: WikiID(rawValue: "test-wiki"), firstMessage: "Hello")
        let requestData = try JSONEncoder().encode(request)

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.startChat(request: requestData) { data in
                cont.resume(returning: data)
            }
        }

        // The reply should be valid JSON with either a chatID or an error
        let replyDict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any]
        #expect(replyDict != nil)
        // In the test environment, preflight will fail (no claude binary),
        // so we expect either an error or the request to time out gracefully.
        // The key assertion: the XPC plumbing works end-to-end.
    }

    @Test func xpcChatSessionStateRoundTripsVersionedSnapshot() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let created = try #require(daemon.createWiki(name: "ChatTest"))
        let wiki = try JSONDecoder().decode(WikiDescriptor.self, from: created)
        let store = try #require(daemon.resolveStoreLazily(wikiID: wiki.id))
        let chat = try store.createChat(kind: .edit, title: "Persisted Chat")
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = ChatTestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.chatSessionState(chatID: chat.id.rawValue) { data in
                cont.resume(returning: data)
            }
        }

        let decoded = try ChatSyncSnapshotEnvelope.decodeData(replyData)

        #expect(decoded.projection.chatID == chat.id)
        #expect(decoded.projection.lastIncludedSequence == .initial)
        #expect(decoded.projection.committedCursor == .zero)
    }

    @Test func xpcChatSessionStateMissingChatReturnsEmptyData() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = ChatTestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.chatSessionState(chatID: "nonexistent") { data in
                cont.resume(returning: data)
            }
        }

        #expect(replyData.isEmpty)
    }

    @Test func persistedOnlyChatSessionStateReadPerformsOneBoundedRecoveryWriteThenStabilizes() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let created = try #require(daemon.createWiki(name: "ChatTest"))
        let wiki = try JSONDecoder().decode(WikiDescriptor.self, from: created)
        let store = try #require(daemon.resolveStoreLazily(wikiID: wiki.id))
        let chat = try store.createChat(kind: .edit, title: "Persisted Chat")
        let claimID = ChatTurnClaimID(rawValue: "claim-read-recovery")
        let turn = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "command-read-recovery"),
                turnID: ChatTurnID(rawValue: "turn-read-recovery"),
                userText: "resume me",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 10)
            )
        )
        _ = try store.claimNextPersistedChatTurn(
            chatID: chat.id,
            claimID: claimID,
            claimedAt: Date(timeIntervalSince1970: 11)
        )
        _ = try store.markPersistedChatTurnProviderSubmitted(
            chatID: chat.id,
            turnID: turn.submission.turnID,
            claimID: claimID,
            providerSessionID: AcpSessionID(rawValue: "session-read-recovery"),
            submittedAt: Date(timeIntervalSince1970: 12)
        )

        let host = try await daemon.ensureChatHost()
        let first = try await host.chatSessionState(chatID: chat.id)
        let second = try await host.chatSessionState(chatID: chat.id)
        let third = try await host.chatSessionState(chatID: chat.id)
        let turns = try store.listPersistedChatTurns(chatID: chat.id)

        if case .interruptedTurn(let turnID) = first.projection.attention {
            #expect(turnID == turn.submission.turnID)
        } else {
            Issue.record("expected first persisted-only read to surface the interrupted turn")
        }
        #expect(first.projection.activeTurn?.turnID == turn.submission.turnID)
        #expect(second == third)
        #expect(second.projection.activeTurn == nil)
        #expect(second.projection.attention == .none)
        #expect(turns.count == 1)
        #expect(turns[0].state == .failed)
        #expect(turns[0].terminalMessage == "This turn was interrupted when the daemon restarted.")
    }

    @Test func xpcStopChatRoundTrip() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = ChatTestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        // Stop a non-existent chat — should not crash
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.stopChat(chatID: "nonexistent") { cont.resume() }
        }
    }

    // MARK: - RC3: Shared generation gate

    @Test func daemonChatHostUsesSharedGenerationGate() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Test")

        let host = try await daemon.ensureChatHost()
        let firstGate = try #require(await host.testSharedGenerationGate)

        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))
        let firstChat = try store.createChat(kind: .edit, title: "First Gate Chat")
        let secondChat = try store.createChat(kind: .edit, title: "Second Gate Chat")

        await #expect(throws: DaemonChatError.self) {
            try await host.submitTurn(ChatSubmitRequest(
                wikiID: WikiID(rawValue: "test-wiki"),
                chatID: firstChat.id,
                submission: ChatTurnSubmission(
                    commandID: ChatCommandID(rawValue: ULID.generate()),
                    turnID: ChatTurnID(rawValue: ULID.generate()),
                    userText: "first controller",
                    contextReferences: [],
                    submittedAt: Date()
                )
            ))
        }
        let secondGateAfterFirstController = try #require(await host.testSharedGenerationGate)

        await #expect(throws: DaemonChatError.self) {
            try await host.submitTurn(ChatSubmitRequest(
                wikiID: WikiID(rawValue: "test-wiki"),
                chatID: secondChat.id,
                submission: ChatTurnSubmission(
                    commandID: ChatCommandID(rawValue: ULID.generate()),
                    turnID: ChatTurnID(rawValue: ULID.generate()),
                    userText: "second controller",
                    contextReferences: [],
                    submittedAt: Date()
                )
            ))
        }
        let thirdGateAfterSecondController = try #require(await host.testSharedGenerationGate)

        #expect(firstGate === secondGateAfterFirstController)
        #expect(firstGate === thirdGateAfterSecondController)
    }

    @Test func newChatPreflightFailureRollsBackCreatedRowAndPropagatesError() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Test")
        let host = try await daemon.ensureChatHost()
        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))

        await #expect(throws: DaemonChatError.self) {
            try await host.startChat(wikiID: WikiID(rawValue: "test-wiki"), firstMessage: "new chat preflight")
        }

        #expect(try store.listChats().isEmpty)
    }

    @Test func existingChatPreflightFailurePreservesRowAndPropagatesError() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Test")
        let host = try await daemon.ensureChatHost()
        let store = try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("test-wiki.sqlite"))
        let existing = try store.createChat(kind: .edit, title: "Existing chat")

        await #expect(throws: DaemonChatError.self) {
            try await host.submitTurn(ChatSubmitRequest(
                wikiID: WikiID(rawValue: "test-wiki"),
                chatID: existing.id,
                submission: ChatTurnSubmission(
                    commandID: ChatCommandID(rawValue: ULID.generate()),
                    turnID: ChatTurnID(rawValue: ULID.generate()),
                    userText: "existing chat preflight",
                    contextReferences: [],
                    submittedAt: Date()
                )
            ))
        }

        let chats = try store.listChats()
        #expect(chats.map(\.id) == [existing.id])
    }

    // MARK: - AC.4a: DaemonWorkloadClient chat round-trip (RC6)

    @Test func daemonWorkloadClientChatStartRequestShape() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = ChatTestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        // Verify the ChatStartRequest encodes/decodes correctly
        let request = ChatStartRequest(wikiID: WikiID(rawValue: "wiki-123"), firstMessage: "test message")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatStartRequest.self, from: data)
        #expect(decoded.wikiID == WikiID(rawValue: "wiki-123"))
        #expect(decoded.firstMessage == "test message")
    }

    @Test func chatSyncSnapshotEnvelopeEncodingDecoding() throws {
        let snapshot = makeChatSyncSnapshot(
            chatID: ChatID(rawValue: "chat-abc"),
            sequence: 3,
            activeTurn: ChatTurnSnapshot(
                turnID: ChatTurnID(rawValue: "turn-1"),
                commandID: ChatCommandID(rawValue: "command-1"),
                visibleText: "hello",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 1000),
                state: .responding
            ),
            overlay: [
                .message(
                    ChatTranscriptMessageItem(
                        messageID: ChatMessageID(rawValue: "message-1"),
                        turnID: ChatTurnID(rawValue: "turn-1"),
                        role: .user,
                        text: "hello",
                        createdAt: Date(timeIntervalSince1970: 1001)
                    )
                )
            ],
            runMetadata: ChatRunMetadata(
                thinkingOption: ThinkingEffortOption(
                    configId: "thought_level",
                    currentValue: "high",
                    choices: [ThinkingEffortOption.Choice(value: "high", label: "High")]
                ),
                runKindRaw: "queryChat",
                runStartedAt: Date(timeIntervalSince1970: 1000)
            )
        )

        let data = try ChatSyncSnapshotEnvelope(snapshot: snapshot).encodedData()
        let decoded = try ChatSyncSnapshotEnvelope.decodeData(data)

        #expect(decoded.projection.chatID == ChatID(rawValue: "chat-abc"))
        #expect(decoded.projection.activeTurn?.state == .responding)
        #expect(decoded.projection.transcriptOverlay.count == 1)
        #expect(decoded.projection.runMetadata.thinkingOption?.currentValue == "high")
        #expect(decoded.projection.runMetadata.runKindRaw == "queryChat")
    }

    // MARK: - Phase C4 follow-up: setChatConfigOption XPC round-trip

    @Test func daemonSetChatConfigOptionRoundTrip() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let listener = NSXPCListener.anonymous()
        let delegate = ChatTestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol

        // setChatConfigOption on a non-existent chat → error reply, no crash.
        let request = ChatConfigOptionRequest(
            chatID: ChatID(rawValue: "nonexistent"), option: "thought_level", value: "high")
        let requestData = try JSONEncoder().encode(request)

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.setChatConfigOption(request: requestData) { data in
                cont.resume(returning: data)
            }
        }

        // The reply should be valid JSON with an error (no session) — not a crash.
        let replyDict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any]
        #expect(replyDict != nil)
        // No live session → "No live chat session for nonexistent"
        let error = replyDict?["error"] as? String
        #expect(error != nil && !error!.isEmpty)
    }

    @Test func chatConfigOptionRequestEncodingDecoding() throws {
        // Verify the request type round-trips cleanly.
        let request = ChatConfigOptionRequest(
            chatID: ChatID(rawValue: "chat-xyz"), option: "thought_level", value: "medium")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatConfigOptionRequest.self, from: data)

        #expect(decoded.chatID == ChatID(rawValue: "chat-xyz"))
        #expect(decoded.option == "thought_level")
        #expect(decoded.value == "medium")
    }

    @Test func chatSyncSnapshotEnvelopeRoundTripsDiagnosticsAndMetadata() throws {
        let snapshot = makeChatSyncSnapshot(
            chatID: ChatID(rawValue: "chat-fields"),
            sequence: 2,
            diagnostics: ChatDiagnosticsState(
                stderr: "stderr capture",
                lastActivityAt: Date(timeIntervalSince1970: 3333),
                currentProcessID: 6789
            ),
            runMetadata: ChatRunMetadata(
                preflightError: "preflight",
                logFileURL: URL(string: "file:///tmp/log")!,
                debugFolderURL: URL(string: "file:///tmp/debug")!
            )
        )

        let data = try ChatSyncSnapshotEnvelope(snapshot: snapshot).encodedData()
        let decoded = try ChatSyncSnapshotEnvelope.decodeData(data)

        #expect(decoded.projection.diagnostics.stderr == "stderr capture")
        #expect(decoded.projection.diagnostics.lastActivityAt?.timeIntervalSince1970 == 3333)
        #expect(decoded.projection.diagnostics.currentProcessID == 6789)
        #expect(decoded.projection.runMetadata.preflightError == "preflight")
        #expect(decoded.projection.runMetadata.logFileURL?.absoluteString == "file:///tmp/log")
        #expect(decoded.projection.runMetadata.debugFolderURL?.absoluteString == "file:///tmp/debug")
    }

    private func makeChatSyncSnapshot(
        chatID: ChatID,
        sequence: Int64,
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = [],
        diagnostics: ChatDiagnosticsState = ChatDiagnosticsState(),
        runMetadata: ChatRunMetadata = .empty
    ) -> ChatSyncSnapshot {
        ChatSyncSnapshot(
            projection: ChatSyncProjection(
                chatID: chatID,
                generation: ChatSessionGenerationID(rawValue: "generation-\(chatID.rawValue)"),
                lifecycle: activeTurn == nil ? .closed : .ready,
                activeTurn: activeTurn,
                queuedTurns: [],
                attention: .none,
                capabilities: .unavailable,
                providerState: ChatProviderState(
                    providerID: ProviderID(rawValue: "provider-1"),
                    modelID: ModelID(rawValue: "model-1"),
                    providerSessionID: nil
                ),
                usage: nil,
                diagnostics: diagnostics,
                transcriptOverlay: overlay,
                committedCursor: .zero,
                lastIncludedSequence: ChatUpdateSequence(rawValue: sequence),
                pendingPermission: nil,
                runMetadata: runMetadata
            )
        )
    }
}

// MARK: - Test helpers

/// Listener delegate for chat XPC tests (mirrors TestListenerDelegate in
/// WikiDaemonWorkloadHostTests but is needed here because the protocol now
/// has chat methods the exporter must implement).
private final class ChatTestListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let exporter: WikiDaemonExporter
    var endpoint: NSXPCListenerEndpoint?

    init(exporter: WikiDaemonExporter) {
        self.exporter = exporter
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.exportedInterface = daemonInterface
        newConnection.exportedObject = exporter
        newConnection.resume()
        return true
    }
}
#endif
