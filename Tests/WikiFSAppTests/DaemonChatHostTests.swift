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

    @Test func daemonDiagnosticRingEvictsOldestAndRotatesAfterAcknowledgedExport() async {
        let trace = DaemonChatDiagnostics()
        let chat = ChatDiagnosticCorrelation.Value(rawValue: "daemon-ring-chat")
        for index in 0...256 {
            await trace.record(
                stage: .persistence,
                outcome: .accepted,
                correlation: .init(chat: chat, updateSequence: .init(UInt64(index))),
                detail: "persisted"
            )
        }
        let before = await trace.snapshot(chat: chat)
        #expect(before.events.count == 256)
        #expect(before.droppedRecordCount == 1)
        #expect(before.droppedByteCount > 0)

        await trace.resetAfterSuccessfulExport()
        let after = await trace.snapshot(chat: chat)
        #expect(after.events.isEmpty)
        #expect(after.process.instanceID != before.process.instanceID)
    }

    @Test func daemonDiagnosticsCoalesceProviderUpdatesForTheSameDurableItem() async {
        let trace = DaemonChatDiagnostics()
        let chat = ChatDiagnosticCorrelation.Value(rawValue: "coalesced-daemon-chat")
        let item = ChatDiagnosticCorrelation.Value(rawValue: "coalesced-item")
        for update in 1...3 {
            await trace.record(
                stage: .providerReceipt,
                outcome: .accepted,
                correlation: .init(
                    chat: chat,
                    updateSequence: .init(UInt64(update)),
                    durableItem: item
                ),
                detail: "provider-delta"
            )
        }

        let snapshot = await trace.snapshot(chat: chat)
        #expect(snapshot.events.count == 1)
        #expect(snapshot.events[0].outcome == .coalesced)
        #expect(snapshot.events[0].payload.correlation.updateSequence == .init(3))
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-chat-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDaemon(dir: URL) -> WikiDaemon {
        WikiDaemon(containerDirectory: dir)
    }

    private func makeProfileDaemon(
        dir: URL,
        name: String = "Test"
    ) async throws -> (daemon: WikiDaemon, wiki: WikiDescriptor) {
        let daemon = try await WikiDaemon.profileBackedForTesting(containerDirectory: dir)
        let created = try #require(await daemon.createWiki(name: name))
        let wiki = try JSONDecoder().decode(WikiDescriptor.self, from: created)
        try await daemon.prepareWiki(wiki.id)
        return (daemon, wiki)
    }

    // MARK: - Store-level operations (the layer the chat host delegates to)

    @Test func chatStoreCreatesRowAndSeedsFirstMessage() async throws {
        let dir = makeTempDir()

        // This store-level test verifies persistence independently of daemon routing.
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
        _ = daemon.testFixtureCreateWiki(name: "Test")

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
        _ = daemon.testFixtureCreateWiki(name: "Test")

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
        _ = daemon.testFixtureCreateWiki(name: "Test")

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
        _ = daemon.testFixtureCreateWiki(name: "Test")

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
        _ = daemon.testFixtureCreateWiki(name: "Test")

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
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir)
        let store = try daemon.resolvePreparedStore(wikiID: wiki.id)
        let chat = try store.createChat(kind: .edit, title: "Checkpoint Disabled")
        let host = try await daemon.ensureChatHost(wikiID: wiki.id)

        let usesCheckpoint = try await host.controllerUsesStreamingCheckpointForTesting(
            chatID: chat.id,
            wikiID: wiki.id
        )

        #expect(usesCheckpoint == false)
    }

    @Test func idleControllerEvictionRemovesOnlyAQuiescentController() async throws {
        let dir = makeTempDir()
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir)
        let store = try daemon.resolvePreparedStore(wikiID: wiki.id)
        let chat = try store.createChat(kind: .edit, title: "Idle")
        let host = try await daemon.ensureChatHost(wikiID: wiki.id)

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
        _ = daemon.testFixtureCreateWiki(name: "Test")

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
        _ = daemon.testFixtureCreateWiki(name: "ChatTest")

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
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir, name: "ChatTest")
        let store = try daemon.resolvePreparedStore(wikiID: wiki.id)
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

        let stateRequest = ChatSessionStateRequest(wikiID: wiki.id, chatID: chat.id)
        let stateRequestData = try JSONEncoder().encode(stateRequest)
        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.chatSessionState(request: stateRequestData) { data in
                cont.resume(returning: data)
            }
        }

        let decoded = try ChatSyncSnapshotEnvelope.decodeData(replyData)

        #expect(decoded.projection.chatID == chat.id)
        #expect(decoded.projection.lastIncludedSequence == .initial)
        #expect(decoded.projection.committedCursor == .zero)
    }

    @Test func xpcChatDiagnosticSnapshotRoundTripsVersionedRedactedEnvelope() async throws {
        let dir = makeTempDir()
        let daemon = makeDaemon(dir: dir)
        let exporter = WikiDaemonExporter(daemon: daemon)
        let listener = NSXPCListener.anonymous()
        let delegate = ChatTestListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! WikiDaemonProtocol
        let request = try JSONEncoder().encode(ChatDiagnosticSnapshotRequest(chat: .init(rawValue: "chat-xpc")))
        let replyData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            proxy.chatDiagnosticSnapshot(request: request) { data in
                continuation.resume(returning: data)
            }
        }

        let snapshot = try JSONDecoder().decode(ChatDiagnosticSnapshotEnvelope.self, from: replyData)
        try snapshot.validatingVersion()
        #expect(snapshot.process.source == .daemon)
        #expect(snapshot.events.allSatisfy { $0.payload.correlation.chat == .init(rawValue: "chat-xpc") })

        let resetRequest = try JSONEncoder().encode(
            ChatDiagnosticResetRequest(chat: .init(rawValue: "chat-xpc"))
        )
        let resetReply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            proxy.resetChatDiagnostics(request: resetRequest) { data in
                continuation.resume(returning: data)
            }
        }
        #expect(resetReply == Data("{\"ok\":true}".utf8))

        let afterResetReply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            proxy.chatDiagnosticSnapshot(request: request) { data in
                continuation.resume(returning: data)
            }
        }
        let afterReset = try JSONDecoder().decode(ChatDiagnosticSnapshotEnvelope.self, from: afterResetReply)
        #expect(afterReset.process.instanceID != snapshot.process.instanceID)
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

        let stateRequest = ChatSessionStateRequest(
            wikiID: WikiID(rawValue: "missing-wiki"),
            chatID: ChatID(rawValue: "nonexistent"))
        let stateRequestData = try JSONEncoder().encode(stateRequest)
        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.chatSessionState(request: stateRequestData) { data in
                cont.resume(returning: data)
            }
        }

        #expect(replyData.isEmpty)
    }

    @Test func persistedOnlyChatSessionStateReadPerformsOneBoundedRecoveryWriteThenStabilizes() async throws {
        let dir = makeTempDir()
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir, name: "ChatTest")
        let store = try daemon.resolvePreparedStore(wikiID: wiki.id)
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

        let host = try await daemon.ensureChatHost(wikiID: wiki.id)
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

        // Stop a non-existent chat. The daemon must not crash.
        let request = ChatStopRequest(
            wikiID: WikiID(rawValue: "missing-wiki"),
            chatID: ChatID(rawValue: "nonexistent"))
        let requestData = try JSONEncoder().encode(request)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.stopChat(request: requestData) { cont.resume() }
        }
    }

    // MARK: - RC3: Shared generation gate

    @Test func profileLauncherFactoryReturnsDistinctOperationObjects() async throws {
        let dir = makeTempDir()
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir)

        let identities = try await daemon.distinctLauncherPairIdentitiesForTesting(
            wikiID: wiki.id)

        #expect(identities.firstGate != identities.secondGate)
        #expect(identities.firstLauncher != identities.secondLauncher)
    }

    @Test func concurrentFirstAccessCreatesOneChatHost() async throws {
        let dir = makeTempDir()
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir)

        let identities = try await withThrowingTaskGroup(
            of: ObjectIdentifier.self,
            returning: [ObjectIdentifier].self
        ) { group in
            for _ in 0..<10 {
                group.addTask {
                    ObjectIdentifier(try await daemon.ensureChatHost(wikiID: wiki.id))
                }
            }
            var values: [ObjectIdentifier] = []
            for try await identity in group {
                values.append(identity)
            }
            return values
        }

        #expect(Set(identities).count == 1)
    }

    @Test func daemonChatHostUsesSharedGenerationGate() async throws {
        let dir = makeTempDir()
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir)
        let host = try await daemon.ensureChatHost(wikiID: wiki.id)
        let firstGate = await host.testSharedGenerationGate

        let store = try daemon.resolvePreparedStore(wikiID: wiki.id)
        let firstChat = try store.createChat(kind: .edit, title: "First Gate Chat")
        let secondChat = try store.createChat(kind: .edit, title: "Second Gate Chat")

        await #expect(throws: DaemonChatError.self) {
            try await host.submitTurn(ChatSubmitRequest(
                wikiID: wiki.id,
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
        let secondGateAfterFirstController = await host.testSharedGenerationGate

        await #expect(throws: DaemonChatError.self) {
            try await host.submitTurn(ChatSubmitRequest(
                wikiID: wiki.id,
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
        let thirdGateAfterSecondController = await host.testSharedGenerationGate

        #expect(firstGate === secondGateAfterFirstController)
        #expect(firstGate === thirdGateAfterSecondController)
    }

    @Test func newChatPreflightFailureRollsBackCreatedRowAndPropagatesError() async throws {
        let dir = makeTempDir()
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir)
        let host = try await daemon.ensureChatHost(wikiID: wiki.id)
        let store = try daemon.resolvePreparedStore(wikiID: wiki.id)

        await #expect(throws: DaemonChatError.self) {
            try await host.startChat(wikiID: wiki.id, firstMessage: "new chat preflight")
        }

        #expect(try store.listChats().isEmpty)
        #expect(await host.liveControllerCountForTesting() == 0)
    }

    @Test func existingChatPreflightFailurePreservesRowAndPropagatesError() async throws {
        let dir = makeTempDir()
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir)
        let host = try await daemon.ensureChatHost(wikiID: wiki.id)
        let store = try daemon.resolvePreparedStore(wikiID: wiki.id)
        let existing = try store.createChat(kind: .edit, title: "Existing chat")

        await #expect(throws: DaemonChatError.self) {
            try await host.submitTurn(ChatSubmitRequest(
                wikiID: wiki.id,
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

    @Test func coldAndWarmConfigurationControllersKeepOneIdleEvictionTimer() async throws {
        let dir = makeTempDir()
        let (daemon, wiki) = try await makeProfileDaemon(dir: dir)
        let store = try daemon.resolvePreparedStore(wikiID: wiki.id)
        let chat = try store.createChat(kind: .edit, title: "Cold configuration")
        let host = try await daemon.ensureChatHost(wikiID: wiki.id)

        try await host.setChatConfigOption(
            chatID: chat.id,
            option: "thought_level",
            value: "high"
        )

        #expect(await host.hasLiveSession(chat.id))
        #expect(await host.isIdleEvictionScheduledForTesting(chatID: chat.id))
        #expect(await host.idleEvictionTaskCountForTesting(chatID: chat.id) == 1)

        // A warm acquire revokes the old task before the option reaches the
        // controller, then re-arms exactly one timer for the idle controller.
        try await host.setChatConfigOption(
            chatID: chat.id,
            option: "thought_level",
            value: "low"
        )
        #expect(await host.isIdleEvictionScheduledForTesting(chatID: chat.id))
        #expect(await host.idleEvictionTaskCountForTesting(chatID: chat.id) == 1)
        #expect(await host.evictIdleControllerForTesting(chatID: chat.id))
        #expect(await host.hasLiveSession(chat.id) == false)
        #expect(await host.isIdleEvictionScheduledForTesting(chatID: chat.id) == false)
    }

    @Test func injectedIdleDelayExercisesTheProductionColdEvictionTimer() async throws {
        let dir = makeTempDir()
        let wikiID = WikiID(rawValue: "injected-timer-wiki")
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("wiki.sqlite"))
        let chat = try store.createChat(kind: .edit, title: "Injected timer")
        var wikiRegistry = WikiRegistry()
        wikiRegistry.add(WikiDescriptor(
            id: wikiID,
            displayName: "Injected timer",
            createdAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: Date(timeIntervalSince1970: 1)
        ))
        try wikiRegistry.save(to: dir)
        let coordinator = await MainActor.run {
            ExtractionCoordinator(
                containerDirectory: dir,
                localExtractorFactory: { UnavailablePdf2MarkdownExtractor() }
            )
        }
        let gate = await MainActor.run {
            GenerationGate(laneLimits: [.ingest: 1, .interactive: 1])
        }
        let launcherPair = await MainActor.run {
            makeTestLauncherPair(
                extractionCoordinator: coordinator,
                generationGate: gate)
        }
        let host = await MainActor.run {
            DaemonChatHost(
                containerDirectory: dir,
                launcherPair: launcherPair,
                storeResolver: { requestedWikiID in
                    requestedWikiID == wikiID ? store : nil
                },
                pushEvent: { _ in },
                providerServices: UnavailableAgentProviderServices(),
                idleEvictionDelay: .zero
            )
        }

        try await host.setChatConfigOption(
            chatID: chat.id,
            option: "thought_level",
            value: "high"
        )

        for _ in 0..<50 {
            if await host.hasLiveSession(chat.id) == false {
                #expect(await host.isIdleEvictionScheduledForTesting(chatID: chat.id) == false)
                return
            }
            await Task.yield()
        }
        Issue.record("injected idle-eviction timer did not remove the cold controller")
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
            wikiID: WikiID(rawValue: "missing-wiki"),
            chatID: ChatID(rawValue: "nonexistent"),
            option: "thought_level",
            value: "high")
        let requestData = try JSONEncoder().encode(request)

        let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            proxy.setChatConfigOption(request: requestData) { data in
                cont.resume(returning: data)
            }
        }

        // The reply should be valid JSON with an error (no session) — not a crash.
        let replyDict = try #require(
            JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        let error = try #require(replyDict["error"] as? String)
        #expect(error.isEmpty == false)
    }

    @Test func wikiScopedChatRequestDTOsRoundTripWikiID() throws {
        let wikiID = WikiID(rawValue: "wiki-scoped-dto")
        let chatID = ChatID(rawValue: "chat-scoped-dto")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let message = try decoder.decode(
            ChatMessageRequest.self,
            from: encoder.encode(ChatMessageRequest(
                wikiID: wikiID, chatID: chatID, message: "hello")))
        let stop = try decoder.decode(
            ChatStopRequest.self,
            from: encoder.encode(ChatStopRequest(wikiID: wikiID, chatID: chatID)))
        let state = try decoder.decode(
            ChatSessionStateRequest.self,
            from: encoder.encode(ChatSessionStateRequest(wikiID: wikiID, chatID: chatID)))
        let permission = try decoder.decode(
            ChatPermissionResolveRequest.self,
            from: encoder.encode(ChatPermissionResolveRequest(
                wikiID: wikiID, chatID: chatID, optionId: "allow", approve: true)))
        let config = try decoder.decode(
            ChatConfigOptionRequest.self,
            from: encoder.encode(ChatConfigOptionRequest(
                wikiID: wikiID, chatID: chatID, option: "thought_level", value: "high")))

        #expect(message.wikiID == wikiID)
        #expect(stop.wikiID == wikiID)
        #expect(state.wikiID == wikiID)
        #expect(permission.wikiID == wikiID)
        #expect(config.wikiID == wikiID)
    }

    @Test func chatConfigOptionRequestEncodingDecoding() throws {
        // Verify the request type round-trips cleanly.
        let request = ChatConfigOptionRequest(
            wikiID: WikiID(rawValue: "wiki-xyz"),
            chatID: ChatID(rawValue: "chat-xyz"),
            option: "thought_level",
            value: "medium")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatConfigOptionRequest.self, from: data)

        #expect(decoded.wikiID == WikiID(rawValue: "wiki-xyz"))
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
