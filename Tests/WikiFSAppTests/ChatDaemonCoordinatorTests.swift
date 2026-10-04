#if os(macOS)
import Foundation
import Observation
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

@MainActor
struct ChatDaemonCoordinatorTests {
    private let fixtureWikiID = WikiID(rawValue: "coordinator-test-wiki")

    @Test func sessionRegistryUsesStableInstances() {
        let coordinator = makeCoordinator()

        let first = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        let second = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        let draft = coordinator.session(wikiID: fixtureWikiID, for: nil)

        #expect(first === second)
        #expect(draft.chatID == .draft)
    }

    /// `session(wikiID:for:)` runs inside view bodies
    /// (`WikiDetailView.chatSurface`), so a repeated lookup for a chat whose
    /// wiki pairing is already recorded must not publish an Observation
    /// mutation. The pre-fix code wrote `chatWikiIDs[chatID] = wikiID`
    /// unconditionally — an observable mutation on every body evaluation
    /// (measured at ~78 calls/second against the 2026-10-03 live beachball).
    ///
    /// Toolchain caveat: dictionary subscript mutation takes the `_modify`
    /// path, which does not notify observers on this toolchain. The contract
    /// this pins is that a repeated lookup performs NO observable write at
    /// all, so any observer path (setter, future toolchain semantics) stays
    /// quiet. Whether the live loop was driven by such notifications is
    /// unconfirmed — see progress/ 2026-10-03 beachball record.
    @Test func repeatedSessionLookupEmitsNoObservationInvalidation() {
        let coordinator = makeCoordinator()
        let chat = ChatID(rawValue: "chat-1")
        _ = coordinator.session(wikiID: fixtureWikiID, for: chat)

        // `onChange` is @Sendable and nonisolated; the flag is only mutated
        // synchronously on the main actor inside this test, so the unsafe
        // local is scoped and race-free here.
        nonisolated(unsafe) var invalidated = false
        withObservationTracking {
            _ = coordinator.chatWikiIDs
            _ = coordinator.session(wikiID: fixtureWikiID, for: chat)
        } onChange: {
            invalidated = true
        }

        #expect(invalidated == false)
    }

    /// The guard must not over-correct: when the pairing genuinely changes,
    /// the write still lands so `route(chatID:update:)` can resolve the
    /// owning wiki. Asserted by value, not by onChange: dictionary subscript
    /// mutation goes through the `_modify` path, which does not notify
    /// observers on this toolchain (see
    /// `observationTrackingDetectsWholePropertyWrites` for the machinery
    /// positive control).
    @Test func sessionLookupStillPublishesWhenPairingChanges() {
        let coordinator = makeCoordinator()
        let chat = ChatID(rawValue: "chat-1")
        _ = coordinator.session(wikiID: fixtureWikiID, for: chat)
        #expect(coordinator.chatWikiIDs[chat] == fixtureWikiID)

        _ = coordinator.session(
            wikiID: WikiID(rawValue: "coordinator-test-wiki-b"),
            for: chat)

        #expect(coordinator.chatWikiIDs[chat] == WikiID(rawValue: "coordinator-test-wiki-b"))
    }

    /// Machinery positive control for the two tests above: a whole-property
    /// assignment through the generated setter DOES publish a mutation to a
    /// registered `withObservationTracking` observer. This proves the silence
    /// result in `repeatedSessionLookupEmitsNoObservationInvalidation` is a
    /// property of the code under test, not of a broken tracking setup.
    @Test func observationTrackingDetectsWholePropertyWrites() {
        let coordinator = makeCoordinator()
        let chat = ChatID(rawValue: "chat-1")
        _ = coordinator.session(wikiID: fixtureWikiID, for: chat)

        nonisolated(unsafe) var invalidated = false
        withObservationTracking {
            _ = coordinator.chatWikiIDs
        } onChange: {
            invalidated = true
        }

        coordinator.chatWikiIDs = [:]

        #expect(invalidated)
    }

    @Test func resetDraftReplacesDraftSession() {
        let coordinator = makeCoordinator()
        let first = coordinator.session(wikiID: fixtureWikiID, for: nil)

        coordinator.resetDraft()

        #expect(coordinator.session(wikiID: fixtureWikiID, for: nil) !== first)
    }

    @Test func ingestForTestingDeliversSyncUpdateToOpenSession() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = makeSnapshot(sequence: 0)
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        let session = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        await coordinator.rehydrate(wikiID: fixtureWikiID, chatID: ChatID(rawValue: "chat-1"))

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(
                    sequence: 1,
                    activeTurn: makeActiveTurn(state: .responding),
                    overlay: [makeMessage(role: .assistant, text: "hello")]
                )
            )
        )

        #expect(session.displayTranscript.rows.count == 1)
        #expect(session.runState.isAnswering)
        #expect(coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))
        #expect(coordinator.anyChatGenerating)
    }

    @Test func terminalToolCallStatusesFireExternalWriteHintOncePerCall() async {
        let coordinator = makeCoordinator()
        _ = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        var hintedWikiIDs: [WikiID] = []
        coordinator.onSuspectedExternalWrite = { hintedWikiIDs.append($0) }

        func ingestToolCall(id: String, status: ChatToolCallStatus, sequence: Int64) {
            coordinator.ingestForTesting(
                QueueEventEnvelope.chatSyncUpdate(
                    chatID: ChatID(rawValue: "chat-1"),
                    update: makeUpdate(
                        sequence: sequence,
                        activeTurn: makeActiveTurn(state: .responding),
                        overlay: [
                            .toolCall(
                                ChatTranscriptToolCallItem(
                                    toolCallID: ToolCallID(rawValue: id),
                                    turnID: ChatTurnID(rawValue: "turn-1"),
                                    toolName: "Bash",
                                    status: status,
                                    detail: "a shell command",
                                    output: nil,
                                    permissionRequestID: nil,
                                    updatedAt: Date(timeIntervalSince1970: 30)))
                        ])
                )
            )
        }

        // Non-terminal states mean nothing can have run yet — no hint.
        ingestToolCall(id: "tool-1", status: .pending, sequence: 1)
        ingestToolCall(id: "tool-1", status: .running, sequence: 2)
        #expect(hintedWikiIDs.isEmpty)

        // Every terminal state fires: a shell that committed and then exited
        // non-zero (failed), or was stopped mid-run (cancelled), has still
        // possibly written.
        ingestToolCall(id: "tool-1", status: .completed, sequence: 3)
        #expect(hintedWikiIDs == [fixtureWikiID])
        ingestToolCall(id: "tool-2", status: .failed, sequence: 4)
        ingestToolCall(id: "tool-3", status: .cancelled, sequence: 5)
        #expect(hintedWikiIDs.count == 3)

        // Later updates keep carrying the same terminal item — no repeats.
        ingestToolCall(id: "tool-1", status: .completed, sequence: 6)
        ingestToolCall(id: "tool-2", status: .failed, sequence: 7)
        #expect(hintedWikiIDs.count == 3)
    }

    @Test func toolCallDedupIsNamespacedPerChat() async {
        let coordinator = makeCoordinator()
        // Two chats over DIFFERENT wikis, each reporting the SAME tool-call id.
        _ = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        _ = coordinator.session(
            wikiID: WikiID(rawValue: "coordinator-test-wiki-2"),
            for: ChatID(rawValue: "chat-2"))
        var hintedWikiIDs: [WikiID] = []
        coordinator.onSuspectedExternalWrite = { hintedWikiIDs.append($0) }

        func ingest(chat: String, wiki: WikiID, sequence: Int64) {
            coordinator.ingestForTesting(
                QueueEventEnvelope.chatSyncUpdate(
                    chatID: ChatID(rawValue: chat),
                    update: makeUpdate(
                        sequence: sequence,
                        overlay: [
                            .toolCall(
                                ChatTranscriptToolCallItem(
                                    toolCallID: ToolCallID(rawValue: "shared-tool-id"),
                                    turnID: ChatTurnID(rawValue: "turn-1"),
                                    toolName: "Bash",
                                    status: .completed,
                                    detail: "a shell command",
                                    output: nil,
                                    permissionRequestID: nil,
                                    updatedAt: Date(timeIntervalSince1970: 30)))
                        ])
                )
            )
        }

        ingest(chat: "chat-1", wiki: fixtureWikiID, sequence: 1)
        ingest(chat: "chat-2", wiki: WikiID(rawValue: "coordinator-test-wiki-2"), sequence: 1)
        #expect(hintedWikiIDs == [fixtureWikiID, WikiID(rawValue: "coordinator-test-wiki-2")])

        // The shared id does not suppress either chat's later repeats.
        ingest(chat: "chat-1", wiki: fixtureWikiID, sequence: 2)
        #expect(hintedWikiIDs.count == 2)
    }

    @Test func discardingChatClearsItsToolCallDedupState() async {
        let coordinator = makeCoordinator()
        let chatID = ChatID(rawValue: "chat-1")
        _ = coordinator.session(wikiID: fixtureWikiID, for: chatID)
        var hintCount = 0
        coordinator.onSuspectedExternalWrite = { _ in hintCount += 1 }

        let update = QueueEventEnvelope.chatSyncUpdate(
            chatID: chatID,
            update: makeUpdate(
                sequence: 1,
                overlay: [
                    .toolCall(
                        ChatTranscriptToolCallItem(
                            toolCallID: ToolCallID(rawValue: "tool-1"),
                            turnID: ChatTurnID(rawValue: "turn-1"),
                            toolName: "Bash",
                            status: .completed,
                            detail: "a shell command",
                            output: nil,
                            permissionRequestID: nil,
                            updatedAt: Date(timeIntervalSince1970: 30)))
                ])
        )

        coordinator.ingestForTesting(update)
        #expect(hintCount == 1)

        // Discarding the chat's mirror clears its dedup set: a re-created
        // mirror may replay the same terminal item, and the hint fires again
        // (one idempotent reload) instead of being suppressed forever.
        coordinator.discard(chatID: chatID)
        _ = coordinator.session(wikiID: fixtureWikiID, for: chatID)
        coordinator.ingestForTesting(update)
        #expect(hintCount == 2)
    }

    /// The production seam end to end: a RECORDED-shape durable tool-call item
    /// (the exact JSON the durable transcript stores — same keys, same date
    /// encoding) decodes through the real `ChatTranscriptItem` Codable, rides
    /// the versioned `ChatSyncUpdateEnvelope` wire, crosses the XPC envelope's
    /// own JSON encode/decode roundtrip, and drives the hint on `route`.
    /// Values are redacted; the SHAPE is the production one (verified against
    /// recorded durable rows: terminal items omit `permissionRequestID`).
    @Test func recordedWireEnvelopeDrivesHintThroughRealDecodeSeam() async throws {
        let recordedItemJSON = """
        {"toolCall":{"_0":{"toolName":"Bash","toolCallID":"recorded-tool-1","turnID":"recorded-turn-1","status":"failed","detail":"a shell command that exited non-zero after committing","output":"partial output","updatedAt":812753795.344805}}}
        """
        let item = try JSONDecoder().decode(ChatTranscriptItem.self, from: Data(recordedItemJSON.utf8))
        guard case .toolCall(let call) = item else {
            Issue.record("Recorded-shape JSON did not decode as a tool-call item")
            return
        }
        #expect(call.status == .failed)

        let coordinator = makeCoordinator()
        _ = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        var hintedWikiIDs: [WikiID] = []
        coordinator.onSuspectedExternalWrite = { hintedWikiIDs.append($0) }

        let update = ChatSyncUpdate(
            reason: .sessionEvent(.started(turnID: call.turnID)),
            projection: makeSnapshot(
                sequence: 1,
                activeTurn: makeActiveTurn(state: .responding),
                overlay: [item]).projection)

        // The versioned wire hop the daemon performs…
        let versioned = try ChatSyncUpdateEnvelope(update: update).encodedData()
        // …and the XPC envelope's own JSON encode/decode roundtrip.
        let envelope = QueueEventEnvelope(
            kind: .chatSyncUpdate,
            chatID: ChatID(rawValue: "chat-1"),
            chatStateData: versioned)
        let wireData = try JSONEncoder().encode(envelope)
        let decodedEnvelope = try JSONDecoder().decode(QueueEventEnvelope.self, from: wireData)

        coordinator.ingestForTesting(decodedEnvelope)

        // The failed (terminal) recorded item fired the reload hint.
        #expect(hintedWikiIDs == [fixtureWikiID])
    }

    @Test func messageOnlyUpdatesDoNotFireExternalWriteHint() {
        let coordinator = makeCoordinator()
        _ = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        var hintedWikiIDs: [WikiID] = []
        coordinator.onSuspectedExternalWrite = { hintedWikiIDs.append($0) }

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(
                    sequence: 1,
                    activeTurn: makeActiveTurn(state: .responding),
                    overlay: [makeMessage(role: .assistant, text: "hello")])
            )
        )

        #expect(hintedWikiIDs.isEmpty)
    }

    @Test func toolCallForChatWithoutKnownWikiDoesNotFireHint() {
        let coordinator = makeCoordinator()
        var hintedWikiIDs: [WikiID] = []
        coordinator.onSuspectedExternalWrite = { hintedWikiIDs.append($0) }

        // No session was ever created for chat-9 — the coordinator cannot know
        // its wiki, so the hint must be skipped (not crashed on).
        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-9"),
                update: makeUpdate(
                    sequence: 1,
                    overlay: [
                        .toolCall(
                            ChatTranscriptToolCallItem(
                                toolCallID: ToolCallID(rawValue: "tool-9"),
                                turnID: ChatTurnID(rawValue: "turn-1"),
                                toolName: "Bash",
                                status: .completed,
                                detail: "a read-only command",
                                output: nil,
                                permissionRequestID: nil,
                                updatedAt: Date(timeIntervalSince1970: 30)))
                    ])
            )
        )

        #expect(hintedWikiIDs.isEmpty)
    }

    @Test func runningStateTokenBumpsOnlyOnGeneratingMembershipChanges() {
        let coordinator = makeCoordinator()
        let before = coordinator.runningStateToken

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 1, activeTurn: makeActiveTurn(state: .responding))
            )
        )
        let afterStart = coordinator.runningStateToken
        #expect(afterStart == before + 1)

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 2, activeTurn: makeActiveTurn(state: .responding))
            )
        )
        #expect(coordinator.runningStateToken == afterStart)

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 3, activeTurn: nil)
            )
        )
        #expect(coordinator.runningStateToken == afterStart + 1)
        #expect(!coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))
    }

    @Test func commandMethodsForwardTypedRequests() async throws {
        let stub = StubChatDaemonCommands()
        stub.nextSubmitChatID = ChatID(rawValue: "submit-id")
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())

        let submitID = try await coordinator.submitTurn(
            ChatSubmitRequest(
                wikiID: WikiID(rawValue: "wiki-1"),
                chatID: nil,
                submission: ChatTurnSubmission(
                    commandID: ChatCommandID(rawValue: "command-1"),
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    userText: "question",
                    contextReferences: [],
                    submittedAt: Date(timeIntervalSince1970: 10)
                )
            )
        )
        await coordinator.resolvePermission(
            wikiID: fixtureWikiID,
            chatID: ChatID(rawValue: "chat-1"),
            intent: .approve(optionID: PermissionOptionID(rawValue: "allow"))
        )
        await coordinator.setThinkingEffort(
            wikiID: fixtureWikiID,
            chatID: ChatID(rawValue: "chat-1"),
            optionID: ChatConfigurationOptionID(rawValue: "reasoning_mode"),
            valueID: ChatConfigurationValueID(rawValue: "high"))
        await coordinator.stop(wikiID: fixtureWikiID, chatID: ChatID(rawValue: "chat-1"))

        #expect(submitID == ChatID(rawValue: "submit-id"))
        #expect(stub.submitTurnCalls.count == 1)
        #expect(stub.submitTurnCalls.first?.wikiID == WikiID(rawValue: "wiki-1"))
        #expect(stub.resolveCalls.first?.wikiID == fixtureWikiID)
        #expect(stub.resolveCalls.first?.optionId == "allow")
        #expect(stub.configOptionCalls.first?.wikiID == fixtureWikiID)
        #expect(stub.configOptionCalls.first?.value == "high")
        #expect(stub.stopWikiIDs == [fixtureWikiID])
        #expect(stub.stopCalls == [ChatID(rawValue: "chat-1")])
    }

    @Test func copyDiagnosticsUsesCoordinatorSnapshotAndRotatesOnlyAfterCopySucceeds() async throws {
        let chatID = ChatID(rawValue: "diagnostic-chat")
        let correlation = ChatDiagnosticCorrelation.Value(rawValue: chatID.rawValue)
        let trace = ChatDiagnosticTrace(source: .app)
        let fingerprint = trace.fingerprint("same content")
        _ = trace.record(
            stage: .displayProjection,
            outcome: .accepted,
            payload: .init(correlation: .init(chat: correlation), detail: "app-display")
        )
        let renderer = ChatTranscriptRenderExecutor(
            mutate: { command, revision, acknowledgement in
                acknowledgement(.init(
                    kind: command.kind,
                    revision: revision,
                    rowID: command.rowID,
                    outcome: .success
                ))
            },
            reportAnomaly: { _ in Issue.record("Unexpected renderer anomaly.") },
            diagnosticTrace: trace
        )
        renderer.submit(.init(
            context: .init(transcriptID: .chat(chatID)),
            rows: [.assistantMessage(
                id: ChatMessageID(rawValue: "diagnostic-message"),
                turnID: ChatTurnID(rawValue: "diagnostic-turn"),
                text: "redacted from the diagnostic payload",
                createdAt: .distantPast,
                contentState: .final
            )]
        ))
        let before = trace.snapshot(chat: correlation)
        let stub = StubChatDaemonCommands()
        stub.diagnosticSnapshot = ChatDiagnosticSnapshotEnvelope(
            process: .init(source: .daemon),
            events: [
                .init(
                    process: .init(source: .daemon),
                    sequence: .init(1),
                    stage: .syncAcceptance,
                    payload: .init(correlation: .init(chat: correlation), detail: "daemon-sync"),
                    outcome: .accepted
                )
            ],
            droppedRecordCount: 3,
            droppedByteCount: 144,
            summary: ["runtime": "daemon"]
        )
        let coordinator = ChatDaemonCoordinator(
            client: stub,
            eventSink: DaemonQueueEventSink(),
            diagnosticTrace: trace
        )
        var copied: Data?

        try await coordinator.copyDiagnostics(for: chatID) { copied = $0 }

        let data = try #require(copied)
        let snapshot = try JSONDecoder().decode(ChatDiagnosticMergedSnapshot.self, from: data)
        #expect(!String(decoding: data, as: UTF8.self).contains("redacted from the diagnostic payload"))
        #expect(stub.diagnosticSnapshotRequests == [.init(chat: correlation)])
        #expect(Set(snapshot.sources) == [.app, .daemon])
        #expect(snapshot.events.map(\.payload.detail).contains("app-display"))
        #expect(snapshot.events.map(\.payload.detail).contains("daemon-sync"))
        #expect(snapshot.events.map(\.stage).contains(.renderPlanning))
        #expect(snapshot.events.map(\.stage).contains(.domAcknowledgement))
        #expect(snapshot.daemonSummary["runtime"] == "daemon")
        #expect(snapshot.mergeOrder == "source-instance-sequence; timestamps-informational")
        let daemonRetention = snapshot.retention.first { $0.source == .daemon }
        #expect(daemonRetention?.droppedRecordCount == 3)
        #expect(daemonRetention?.droppedByteCount == 144)
        #expect(stub.diagnosticResetRequests == [.init(chat: correlation)])

        let after = trace.snapshot(chat: correlation)
        #expect(after.events.isEmpty)
        #expect(after.process.instanceID != before.process.instanceID)
        #expect(trace.fingerprint("same content") != fingerprint)
    }

    @Test func failedDiagnosticCopyPreservesTraceForRetry() async {
        let chatID = ChatID(rawValue: "diagnostic-chat")
        let correlation = ChatDiagnosticCorrelation.Value(rawValue: chatID.rawValue)
        let trace = ChatDiagnosticTrace(source: .app)
        let fingerprint = trace.fingerprint("same content")
        _ = trace.record(
            stage: .displayProjection,
            outcome: .accepted,
            payload: .init(correlation: .init(chat: correlation), detail: "app-display")
        )
        let before = trace.snapshot(chat: correlation)
        let stub = StubChatDaemonCommands()
        let coordinator = ChatDaemonCoordinator(
            client: stub,
            eventSink: DaemonQueueEventSink(),
            diagnosticTrace: trace
        )

        do {
            try await coordinator.copyDiagnostics(
                for: chatID,
            ) { _ in
                throw StubError.throwing
            }
            Issue.record("Expected the diagnostic destination to fail.")
        } catch StubError.throwing {
            // Expected: the trace remains available for a retry.
        } catch {
            Issue.record("Unexpected diagnostic copy failure: \(error)")
        }

        let after = trace.snapshot(chat: correlation)
        #expect(after.process.instanceID == before.process.instanceID)
        #expect(after.events == before.events)
        #expect(trace.fingerprint("same content") == fingerprint)
        #expect(stub.diagnosticResetRequests.isEmpty)
    }

    @Test func failedDaemonDiagnosticResetRetiresAppFingerprintEpochButKeepsRetryRing() async {
        let chatID = ChatID(rawValue: "diagnostic-reset-failure")
        let correlation = ChatDiagnosticCorrelation.Value(rawValue: chatID.rawValue)
        let trace = ChatDiagnosticTrace(source: .app)
        _ = trace.record(
            stage: .displayProjection,
            outcome: .accepted,
            payload: .init(correlation: .init(chat: correlation), detail: "app-display")
        )
        let fingerprint = trace.fingerprint("same content")
        let before = trace.snapshot(chat: correlation)
        let stub = StubChatDaemonCommands()
        stub.shouldThrowDiagnosticReset = true
        let coordinator = ChatDaemonCoordinator(
            client: stub,
            eventSink: DaemonQueueEventSink(),
            diagnosticTrace: trace
        )

        do {
            try await coordinator.copyDiagnostics(for: chatID) { _ in }
            Issue.record("Expected daemon diagnostic reset failure.")
        } catch StubError.throwing {
            // The artifact was written, so the key must not remain reusable.
        } catch {
            Issue.record("Unexpected reset failure: \(error)")
        }

        let after = trace.snapshot(chat: correlation)
        #expect(after.events == before.events)
        #expect(after.process.instanceID == before.process.instanceID)
        #expect(trace.fingerprint("same content") != fingerprint)
    }

    @Test func jsonlDiagnosticsExportUsesCoordinatorSnapshotAndRotatesAfterWrite() async throws {
        let chatID = ChatID(rawValue: "jsonl-chat")
        let correlation = ChatDiagnosticCorrelation.Value(rawValue: chatID.rawValue)
        let trace = ChatDiagnosticTrace(source: .app)
        _ = trace.record(
            stage: .displayProjection,
            outcome: .accepted,
            payload: .init(correlation: .init(chat: correlation), detail: "app-display")
        )
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("tmp/chat-diagnostics-export-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                DebugLog.store("chat diagnostics export test cleanup failed: \(error)")
            }
        }
        let url = directory.appendingPathComponent("chat-diagnostics.jsonl")
        let stub = StubChatDaemonCommands()
        let coordinator = ChatDaemonCoordinator(
            client: stub,
            eventSink: DaemonQueueEventSink(),
            diagnosticTrace: trace
        )

        try await coordinator.writeDiagnosticsJSONL(
            for: chatID,
            to: url
        )

        let line = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
        #expect(line.contains("app-display"))
        #expect(line.contains("retention"))
        #expect(stub.diagnosticSnapshotRequests == [.init(chat: correlation)])
        #expect(stub.diagnosticResetRequests == [.init(chat: correlation)])
        #expect(trace.snapshot(chat: correlation).events.isEmpty)
    }

    @Test func rehydrateUsesAuthoritativeSnapshot() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = makeSnapshot(
            sequence: 4,
            activeTurn: makeActiveTurn(state: .responding),
            overlay: [makeMessage(role: .assistant, text: "seed")]
        )
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())

        await coordinator.rehydrate(wikiID: fixtureWikiID, chatID: ChatID(rawValue: "chat-1"))

        let session = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        #expect(session.displayTranscript.rows.count == 1)
        #expect(session.runState.isAnswering)
        #expect(coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))
    }

    @Test func rehydrateFailureClearsLivenessClaim() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = makeSnapshot(sequence: 1, activeTurn: makeActiveTurn(state: .responding))
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coordinator.rehydrate(wikiID: fixtureWikiID, chatID: ChatID(rawValue: "chat-1"))
        #expect(coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))

        stub.shouldThrow = true
        await coordinator.rehydrate(wikiID: fixtureWikiID, chatID: ChatID(rawValue: "chat-1"))

        let session = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        #expect(session.runState == .idle)
        #expect(!coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))
    }

    @Test func sessionWiresAuthoritativeSnapshotLoaderForGapRecovery() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = makeSnapshot(sequence: 1)
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coordinator.rehydrate(wikiID: fixtureWikiID, chatID: ChatID(rawValue: "chat-1"))

        let session = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        stub.sessionState = makeSnapshot(
            sequence: 4,
            runMetadata: ChatRunMetadata(preflightError: "resynced")
        )

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 4)
            )
        )

        await expectEventually(session.preflightError == "resynced")
        #expect(stub.sessionStateRequests.count >= 2)
    }

    @Test func persistedOnlyBaselineAcceptsFirstLiveUpdateWithoutSnapshotRoundTrip() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = makeSnapshot(
            sequence: 0,
            generation: "persisted-chat-1",
            activeTurn: nil
        )
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coordinator.rehydrate(wikiID: fixtureWikiID, chatID: ChatID(rawValue: "chat-1"))
        stub.sessionStateRequests.removeAll()

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(
                    sequence: 1,
                    generation: "generation-live",
                    activeTurn: makeActiveTurn(state: .responding),
                    overlay: [makeMessage(role: .assistant, text: "live")]
                )
            )
        )

        let session = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "chat-1"))
        await expectEventually(session.runState.isAnswering)
        #expect(stub.sessionStateRequests.isEmpty)
    }

    @Test func draftSessionDoesNotWireConfigCallback() {
        let coordinator = makeCoordinator()
        #expect(coordinator.session(wikiID: fixtureWikiID, for: nil).onSetChatConfigOption == nil)
    }

    @Test func providerSignalReloadsDraftOpenAndRestoredSessions() async throws {
        let directory = try providerConfigDirectory()
        defer { removeProviderConfigDirectory(directory) }
        try AgentProvidersConfig.seed(discovered: []).writeAtomically(to: directory)
        let coordinator = ChatDaemonCoordinator(
            client: StubChatDaemonCommands(),
            eventSink: DaemonQueueEventSink(),
            providersConfigurationDirectory: directory)
        let draft = coordinator.session(wikiID: fixtureWikiID, for: nil)
        let open = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "open"))
        let restored = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "restored"))

        let committed = try await AgentProvidersConfigStore(
            directory: directory,
            postLocal: { _ in },
            postDarwin: {}).mutate {
                $0.settingSelectedModel(
                    ModelID(rawValue: "new-model"),
                    forProvider: ProviderID(rawValue: "claude-acp"))
            }
        coordinator.reloadProviderConfigurationIfNeeded()

        #expect(draft.providerConfiguration.generation == committed.generation)
        #expect(open.providerConfiguration.generation == committed.generation)
        #expect(restored.providerConfiguration.generation == committed.generation)
        #expect(open.selectedModelId(forProvider: ProviderID(rawValue: "claude-acp")) == ModelID(rawValue: "new-model"))
    }

    @Test func activationRepairsMissedProviderGeneration() async throws {
        let directory = try providerConfigDirectory()
        defer { removeProviderConfigDirectory(directory) }
        try AgentProvidersConfig.seed(discovered: []).writeAtomically(to: directory)
        let coordinator = ChatDaemonCoordinator(
            client: StubChatDaemonCommands(),
            eventSink: DaemonQueueEventSink(),
            providersConfigurationDirectory: directory)
        let session = coordinator.session(wikiID: fixtureWikiID, for: ChatID(rawValue: "idle"))
        let oldGeneration = session.providerConfiguration.generation

        let committed = try await AgentProvidersConfigStore(
            directory: directory,
            postLocal: { _ in },
            postDarwin: {}).mutate {
                $0.settingSelectedModel(
                    ModelID(rawValue: "activation-model"),
                    forProvider: ProviderID(rawValue: "claude-acp"))
            }
        #expect(session.providerConfiguration.generation == oldGeneration)

        coordinator.applicationDidBecomeActive()

        #expect(session.providerConfiguration.generation == committed.generation)
        #expect(session.selectedModelId(forProvider: ProviderID(rawValue: "claude-acp")) == ModelID(rawValue: "activation-model"))
    }

    @Test func stableHolderPublishesTransportReplacement() {
        let holder = ChatDaemonCoordinatorHolder()
        let coordinator = makeCoordinator()
        let observation = ObservationCounter()

        withObservationTracking {
            _ = holder.coordinator
        } onChange: {
            observation.increment()
        }

        #expect(holder.coordinator == nil)
        holder.replace(with: coordinator)
        #expect(observation.count == 1)
        #expect(holder.coordinator === coordinator)

        holder.replace(with: nil)
        #expect(holder.coordinator == nil)
    }

    private func providerConfigDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeProviderConfigDirectory(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Failed to remove the provider-config fixture: \(error)") }
    }

    private func makeCoordinator() -> ChatDaemonCoordinator {
        ChatDaemonCoordinator(client: StubChatDaemonCommands(), eventSink: DaemonQueueEventSink())
    }

    private func makeSnapshot(
        sequence: Int64,
        generation: String = "generation-1",
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = [],
        runMetadata: ChatRunMetadata = .empty
    ) -> ChatSyncSnapshot {
        ChatSyncSnapshot(
            projection: ChatSyncProjection(
                chatID: ChatID(rawValue: "chat-1"),
                generation: ChatSessionGenerationID(rawValue: generation),
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
                diagnostics: ChatDiagnosticsState(),
                transcriptOverlay: overlay,
                committedCursor: .zero,
                lastIncludedSequence: ChatUpdateSequence(rawValue: sequence),
                pendingPermission: nil,
                runMetadata: runMetadata
            )
        )
    }

    private func makeUpdate(
        sequence: Int64,
        generation: String = "generation-1",
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = []
    ) -> ChatSyncUpdate {
        ChatSyncUpdate(
            reason: .sessionEvent(.started(turnID: ChatTurnID(rawValue: "turn-1"))),
            projection: makeSnapshot(
                sequence: sequence,
                generation: generation,
                activeTurn: activeTurn,
                overlay: overlay
            ).projection
        )
    }

    private func makeActiveTurn(state: ChatTurnState) -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: ChatTurnID(rawValue: "turn-1"),
            commandID: ChatCommandID(rawValue: "command-1"),
            visibleText: "visible",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10),
            state: state
        )
    }

    private func makeMessage(
        role: ChatTranscriptMessageRole,
        text: String
    ) -> ChatTranscriptItem {
        .message(
            ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: "\(role.rawValue)-\(text)"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: role,
                text: text,
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
    }

    private func expectEventually(
        _ condition: @autoclosure @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<50 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Condition was not met before timeout.")
    }
}

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

@MainActor
final class StubChatDaemonCommands: ChatDaemonCommands, @unchecked Sendable {
    var submitTurnCalls: [ChatSubmitRequest] = []
    var stopCalls: [ChatID] = []
    var stopWikiIDs: [WikiID] = []
    var resolveCalls: [ChatPermissionResolveRequest] = []
    var sessionStateRequests: [ChatID] = []
    var sessionStateWikiIDs: [WikiID] = []
    var configOptionCalls: [ChatConfigOptionRequest] = []
    var diagnosticSnapshotRequests: [ChatDiagnosticSnapshotRequest] = []
    var diagnosticResetRequests: [ChatDiagnosticResetRequest] = []

    var nextSubmitChatID = ChatID(rawValue: "stub-submit-chat-id")
    var sessionState: ChatSyncSnapshot?
    var diagnosticSnapshot: ChatDiagnosticSnapshotEnvelope?
    var shouldThrow = false
    var shouldThrowDiagnosticReset = false

    func submitChatTurn(_ request: ChatSubmitRequest) async throws -> ChatID {
        submitTurnCalls.append(request)
        if shouldThrow { throw StubError.throwing }
        return nextSubmitChatID
    }

    func stopChat(wikiID: WikiID, chatID: ChatID) async throws {
        stopWikiIDs.append(wikiID)
        stopCalls.append(chatID)
        if shouldThrow { throw StubError.throwing }
    }

    func chatSessionState(wikiID: WikiID, chatID: ChatID) async throws -> ChatSyncSnapshot {
        sessionStateWikiIDs.append(wikiID)
        sessionStateRequests.append(chatID)
        if shouldThrow { throw StubError.throwing }
        return sessionState ?? ChatSyncSnapshot(
            projection: ChatSyncProjection(
                chatID: chatID,
                generation: ChatSessionGenerationID(rawValue: "generation-default"),
                lifecycle: .closed,
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
            )
        )
    }

    func chatDiagnosticSnapshot(_ request: ChatDiagnosticSnapshotRequest) async throws -> ChatDiagnosticSnapshotEnvelope {
        diagnosticSnapshotRequests.append(request)
        try request.validatingVersion()
        if shouldThrow { throw StubError.throwing }
        return diagnosticSnapshot ?? ChatDiagnosticSnapshotEnvelope(
            process: .init(source: .daemon),
            events: []
        )
    }

    func resetChatDiagnostics(_ request: ChatDiagnosticResetRequest) async throws {
        diagnosticResetRequests.append(request)
        try request.validatingVersion()
        if shouldThrowDiagnosticReset { throw StubError.throwing }
        if shouldThrow { throw StubError.throwing }
    }

    func resolveChatPermission(_ request: ChatPermissionResolveRequest) async throws {
        resolveCalls.append(request)
        if shouldThrow { throw StubError.throwing }
    }

    func setChatConfigOption(_ request: ChatConfigOptionRequest) async throws {
        configOptionCalls.append(request)
        if shouldThrow { throw StubError.throwing }
    }
}

private enum StubError: Error {
    case throwing
}
#endif
