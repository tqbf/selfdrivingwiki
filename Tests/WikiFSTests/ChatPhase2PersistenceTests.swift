import Foundation
import Testing
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
@testable import WikiFSCore
#if os(macOS)
@testable import WikiFSSearch
#endif

struct ChatPhase2PersistenceTests {
    private static let tantivyMarkerKey = "tantivy.rebuild.required"

    private func submission(
        commandID: String,
        turnID: String,
        text: String,
        refs: [ChatContextReference] = [],
        submittedAt: TimeInterval = 1
    ) -> ChatTurnSubmission {
        ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: commandID),
            turnID: ChatTurnID(rawValue: turnID),
            userText: text,
            contextReferences: refs,
            submittedAt: Date(timeIntervalSince1970: submittedAt)
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fileURL(prefix: String) throws -> URL {
        let dir = repositoryRoot()
            .appendingPathComponent("tmp/\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func withDatabase<T>(at databaseURL: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw WikiStoreError.open("could not open sqlite fixture")
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func execute(_ sql: String, at databaseURL: URL) throws {
        try withDatabase(at: databaseURL) { database in
            sqlite3_busy_timeout(database, 5000)
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
                throw WikiStoreError.sqlite(code: -1, message: message)
            }
        }
    }

    @Test func enqueueTurnsAreDenseAndIdempotentByCommandID() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Queue")
        let first = submission(commandID: "cmd-1", turnID: "turn-1", text: "first")
        let second = submission(commandID: "cmd-2", turnID: "turn-2", text: "second")

        let insertedFirst = try store.enqueuePersistedChatTurn(chatID: chat.id, submission: first)
        let insertedDuplicate = try store.enqueuePersistedChatTurn(chatID: chat.id, submission: first)
        let insertedSecond = try store.enqueuePersistedChatTurn(chatID: chat.id, submission: second)

        #expect(insertedFirst.ordinal == 0)
        #expect(insertedDuplicate.ordinal == 0)
        #expect(insertedDuplicate.submission.turnID == insertedFirst.submission.turnID)
        #expect(insertedSecond.ordinal == 1)
        #expect(try store.listPersistedChatTurns(chatID: chat.id).map(\.ordinal) == [0, 1])
    }

    @Test func editClaimSubmitAndFinishPersistedTurns() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Queue")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: submission(commandID: "cmd-1", turnID: "turn-1", text: "draft")
        )
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: submission(commandID: "cmd-2", turnID: "turn-2", text: "follow up", submittedAt: 2)
        )

        let edited = try store.editPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            userText: "edited",
            contextReferences: [.page(PageID(rawValue: "page-1"))],
            editedAt: Date(timeIntervalSince1970: 3)
        )
        #expect(edited.submission.userText == "edited")
        #expect(edited.submission.contextReferences == [.page(PageID(rawValue: "page-1"))])

        let claimed1 = try #require(try store.claimNextPersistedChatTurn(
            chatID: chat.id,
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            claimedAt: Date(timeIntervalSince1970: 4)
        ))
        #expect(claimed1.submission.turnID == ChatTurnID(rawValue: "turn-1"))
        #expect(claimed1.state == .claimed)

        let submitted = try store.markPersistedChatTurnProviderSubmitted(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            providerSessionID: AcpSessionID(rawValue: "acp-1"),
            submittedAt: Date(timeIntervalSince1970: 5)
        )
        #expect(submitted.state == .providerSubmitted)
        #expect(submitted.providerSessionID == AcpSessionID(rawValue: "acp-1"))

        let finished = try store.finishPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            state: .completed,
            terminalMessage: nil
        )
        #expect(finished.state == .completed)

        let claimed2 = try #require(try store.claimNextPersistedChatTurn(
            chatID: chat.id,
            claimID: ChatTurnClaimID(rawValue: "claim-2"),
            claimedAt: Date(timeIntervalSince1970: 6)
        ))
        #expect(claimed2.submission.turnID == ChatTurnID(rawValue: "turn-2"))
    }

    @Test func fileBackedTurnLifecycleRoundTripsAcrossReopen() throws {
        let url = try fileURL(prefix: "chat-phase2-turn-roundtrip")
        var store = try GRDBWikiStore(databaseURL: url)
        let chat = try store.createChat(kind: .edit, title: "Queue")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: submission(
                commandID: "cmd-1",
                turnID: "turn-1",
                text: "draft",
                refs: [
                    .page(PageID(rawValue: "page-1")),
                    .source(SourceID(rawValue: "source-1")),
                    .chat(ChatID(rawValue: "chat-2")),
                ],
                submittedAt: 1
            )
        )
        _ = try store.editPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            userText: "edited",
            contextReferences: [
                .page(PageID(rawValue: "page-1")),
                .source(SourceID(rawValue: "source-1")),
                .chat(ChatID(rawValue: "chat-2")),
            ],
            editedAt: Date(timeIntervalSince1970: 2)
        )
        _ = try store.claimNextPersistedChatTurn(
            chatID: chat.id,
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            claimedAt: Date(timeIntervalSince1970: 3)
        )
        _ = try store.markPersistedChatTurnProviderSubmitted(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            providerSessionID: AcpSessionID(rawValue: "acp-1"),
            submittedAt: Date(timeIntervalSince1970: 4)
        )
        _ = try store.finishPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            state: .completed,
            terminalMessage: "done"
        )
        store.close()

        store = try GRDBWikiStore(databaseURL: url)
        let turns = try store.listPersistedChatTurns(chatID: chat.id)
        #expect(turns.count == 1)
        let turn = try #require(turns.first)

        #expect(turn.chatID == chat.id)
        #expect(turn.ordinal == 0)
        #expect(turn.submission.commandID == ChatCommandID(rawValue: "cmd-1"))
        #expect(turn.submission.turnID == ChatTurnID(rawValue: "turn-1"))
        #expect(turn.submission.userText == "edited")
        #expect(turn.submission.contextReferences == [
            .page(PageID(rawValue: "page-1")),
            .source(SourceID(rawValue: "source-1")),
            .chat(ChatID(rawValue: "chat-2")),
        ])
        #expect(turn.submission.submittedAt == Date(timeIntervalSince1970: 1))
        #expect(turn.editedAt == Date(timeIntervalSince1970: 2))
        #expect(turn.state == .completed)
        #expect(turn.claimID == ChatTurnClaimID(rawValue: "claim-1"))
        #expect(turn.claimedAt == Date(timeIntervalSince1970: 3))
        #expect(turn.providerSubmittedAt == Date(timeIntervalSince1970: 4))
        #expect(turn.providerSessionID == AcpSessionID(rawValue: "acp-1"))
        #expect(turn.terminalMessage == "done")
    }

    @Test func providerSubmittedAndTerminalPersistenceAreIdempotent() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Queue")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: submission(commandID: "cmd-1", turnID: "turn-1", text: "draft")
        )
        _ = try store.claimNextPersistedChatTurn(
            chatID: chat.id,
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            claimedAt: Date(timeIntervalSince1970: 2)
        )

        let firstSubmitted = try store.markPersistedChatTurnProviderSubmitted(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            providerSessionID: AcpSessionID(rawValue: "acp-1"),
            submittedAt: Date(timeIntervalSince1970: 3)
        )
        let secondSubmitted = try store.markPersistedChatTurnProviderSubmitted(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            providerSessionID: AcpSessionID(rawValue: "acp-2"),
            submittedAt: Date(timeIntervalSince1970: 4)
        )
        #expect(secondSubmitted == firstSubmitted)
        #expect(secondSubmitted.providerSubmittedAt == Date(timeIntervalSince1970: 3))
        #expect(secondSubmitted.providerSessionID == AcpSessionID(rawValue: "acp-1"))

        let firstFinished = try store.finishPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            state: .completed,
            terminalMessage: "done"
        )
        let secondFinished = try store.finishPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            state: .completed,
            terminalMessage: "different"
        )
        #expect(secondFinished == firstFinished)
        #expect(secondFinished.terminalMessage == "done")
    }

    @Test func invalidPersistedTurnTransitionsThrow() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Queue")
        _ = try store.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: submission(commandID: "cmd-1", turnID: "turn-1", text: "draft")
        )

        #expect(throws: WikiStoreError.self) {
            _ = try store.markPersistedChatTurnProviderSubmitted(
                chatID: chat.id,
                turnID: ChatTurnID(rawValue: "turn-1"),
                claimID: ChatTurnClaimID(rawValue: "wrong-claim"),
                providerSessionID: nil,
                submittedAt: Date(timeIntervalSince1970: 2)
            )
        }

        #expect(throws: WikiStoreError.self) {
            _ = try store.finishPersistedChatTurn(
                chatID: chat.id,
                turnID: ChatTurnID(rawValue: "turn-1"),
                claimID: ChatTurnClaimID(rawValue: "claim-1"),
                state: .queued,
                terminalMessage: "illegal"
            )
        }

        _ = try store.claimNextPersistedChatTurn(
            chatID: chat.id,
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            claimedAt: Date(timeIntervalSince1970: 2)
        )
        _ = try store.finishPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            state: .completed,
            terminalMessage: "done"
        )

        let winner = try store.finishPersistedChatTurn(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            claimID: ChatTurnClaimID(rawValue: "claim-1"),
            state: .failed,
            terminalMessage: "different terminal"
        )
        #expect(winner.state == .completed)
        #expect(winner.terminalMessage == "done")
    }

    @Test func transcriptItemsRoundTripAndProjectToCompatibilityMessages() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Transcript")
        let items: [ChatTranscriptItem] = [
            .message(.init(
                messageID: ChatMessageID(rawValue: "message-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .assistant,
                text: "Hello",
                createdAt: Date(timeIntervalSince1970: 1)
            )),
            .toolCall(.init(
                toolCallID: ToolCallID(rawValue: "tool-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                toolName: "Read",
                status: .running,
                detail: "README.md",
                permissionRequestID: nil,
                updatedAt: Date(timeIntervalSince1970: 2)
            )),
            .turnFailure(.init(
                failureID: ChatTranscriptFailureID(rawValue: "failure-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                category: .runtimeError,
                message: "boom",
                createdAt: Date(timeIntervalSince1970: 3)
            )),
        ]

        let inserted = try store.appendChatTranscriptItems(chatID: chat.id, items: items)
        #expect(inserted.map(\.cursor.rawValue) == [1, 2, 3])

        let page = try store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 10)
        #expect(page.checkpoint == ChatTranscriptCursor(rawValue: 3))
        #expect(page.items.map(\.item) == items)

        let messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.count == 3)
        #expect(messages[0].event == .assistantText("Hello"))
        #expect(messages[1].event == .toolUse(name: "Read", inputSummary: "README.md"))
        #expect(messages[2].event == .turnFailed(reason: .agentError("boom")))
    }

    @Test func transcriptPagingUsesCursorAndCheckpoint() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Transcript")
        try store.appendChatTranscriptItems(chatID: chat.id, items: [
            .systemNotice(.init(
                noticeID: ChatTranscriptNoticeID(rawValue: "notice-1"),
                turnID: nil,
                kind: .session,
                title: "Started",
                message: "Ready",
                createdAt: Date(timeIntervalSince1970: 1)
            )),
            .message(.init(
                messageID: ChatMessageID(rawValue: "message-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .user,
                text: "Hello",
                createdAt: Date(timeIntervalSince1970: 2)
            )),
            .message(.init(
                messageID: ChatMessageID(rawValue: "message-2"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .assistant,
                text: "Hi",
                createdAt: Date(timeIntervalSince1970: 3)
            )),
        ])

        let first = try store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 2)
        #expect(first.items.map(\.cursor.rawValue) == [1, 2])
        #expect(first.checkpoint == ChatTranscriptCursor(rawValue: 3))
        #expect(first.nextCursor == ChatTranscriptCursor(rawValue: 2))

        let second = try store.readChatTranscriptPage(chatID: chat.id, after: first.nextCursor, limit: 2)
        #expect(second.items.map(\.cursor.rawValue) == [3])
        #expect(second.checkpoint == ChatTranscriptCursor(rawValue: 3))
        #expect(second.nextCursor == ChatTranscriptCursor(rawValue: 3))
        #expect(try store.chatTranscriptCheckpoint(chatID: chat.id) == ChatTranscriptCursor(rawValue: 3))
    }

    @Test func duplicateEqualNoticeAndFailureItemsKeepDistinctDurableCursors() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Duplicate durable items")
        let timestamp = Date(timeIntervalSince1970: 1)
        let firstNotice = ChatTranscriptItem.systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "notice-1"),
            turnID: nil,
            kind: .session,
            title: "Started",
            message: "Ready",
            createdAt: timestamp
        ))
        let secondNotice = ChatTranscriptItem.systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "notice-2"),
            turnID: nil,
            kind: .session,
            title: "Started",
            message: "Ready",
            createdAt: timestamp
        ))
        let firstFailure = ChatTranscriptItem.turnFailure(.init(
            failureID: ChatTranscriptFailureID(rawValue: "failure-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            category: .runtimeError,
            message: "Failed",
            createdAt: timestamp
        ))
        let secondFailure = ChatTranscriptItem.turnFailure(.init(
            failureID: ChatTranscriptFailureID(rawValue: "failure-2"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            category: .runtimeError,
            message: "Failed",
            createdAt: timestamp
        ))

        let inserted = try store.appendChatTranscriptItems(
            chatID: chat.id,
            items: [firstNotice, secondNotice, firstFailure, secondFailure]
        )

        #expect(inserted.map(\.cursor.rawValue) == [1, 2, 3, 4])
        #expect(try store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 10).items.map(\.item)
            == [firstNotice, secondNotice, firstFailure, secondFailure])
    }

    @Test func legacyStoreMigrationAssignsCanonicalIDs() throws {
        let url = try fileURL(prefix: "chat-transcript-id-migration")
        var store: GRDBWikiStore? = try GRDBWikiStore(databaseURL: url)
        let chat = try #require(try store?.createChat(kind: .edit, title: "Legacy"))
        let notice = ChatTranscriptItem.systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "temporary-notice"),
            turnID: nil,
            kind: .session,
            title: "Started",
            message: "Ready",
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let failure = ChatTranscriptItem.turnFailure(.init(
            failureID: ChatTranscriptFailureID(rawValue: "temporary-failure"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            category: .runtimeError,
            message: "Failed",
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        _ = try store?.appendChatTranscriptItems(chatID: chat.id, items: [notice, failure])
        store = nil

        let legacyNoticeJSON = try legacyJSON(from: notice, removing: "noticeID")
        let legacyFailureJSON = try legacyJSON(from: failure, removing: "failureID")
        try execute(
            """
            UPDATE chat_transcript_items SET item_json = '\(legacyNoticeJSON)' WHERE chat_id = '\(chat.id.rawValue)' AND cursor = 1;
            UPDATE chat_transcript_items SET item_json = '\(legacyFailureJSON)' WHERE chat_id = '\(chat.id.rawValue)' AND cursor = 2;
            PRAGMA user_version = 46;
            """,
            at: url
        )

        let migrated = try GRDBWikiStore(databaseURL: url)
        let items = try migrated.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 10).items.map(\.item)
        guard case .systemNotice(let migratedNotice) = items[0],
              case .turnFailure(let migratedFailure) = items[1]
        else {
            Issue.record("Expected migrated notice and failure items.")
            return
        }
        #expect(migratedNotice.noticeID.rawValue == "chat-transcript-v47:systemNotice:\(chat.id.rawValue):1")
        #expect(migratedFailure.failureID.rawValue == "chat-transcript-v47:turnFailure:\(chat.id.rawValue):2")
        #expect(migrated.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func legacyStoreMigrationIsIdempotent() throws {
        // The preceding migration test proves the initial rewrite. A current
        // database must retain those exact values on the next open.
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Stable IDs")
        let item = ChatTranscriptItem.systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "notice-stable"),
            turnID: nil,
            kind: .session,
            title: "Started",
            message: "Ready",
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        _ = try store.appendChatTranscriptItems(chatID: chat.id, items: [item])
        let first = try store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 1)
        let second = try store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 1)
        #expect(first == second)
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    private func legacyJSON(from item: ChatTranscriptItem, removing key: String) throws -> String {
        let data = try JSONEncoder().encode(item)
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let itemCase = key == "noticeID" ? "systemNotice" : "turnFailure"
        var associated = try #require(root[itemCase] as? [String: Any])
        var payload = try #require(associated["_0"] as? [String: Any])
        payload.removeValue(forKey: key)
        associated["_0"] = payload
        root[itemCase] = associated
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    @Test func phase2MigrationPreservesNonChatRowsAndMarksTantivyRebuild() throws {
        let url = try fileURL(prefix: "chat-phase2-migration")
        try execute(
            """
            PRAGMA foreign_keys = ON;
            CREATE TABLE pages (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                slug TEXT NOT NULL,
                body_markdown TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                version INTEGER NOT NULL DEFAULT 1,
                created_by TEXT,
                last_edited_by TEXT
            );
            CREATE UNIQUE INDEX pages_slug_unique ON pages(slug);
            CREATE TABLE wiki_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
            VALUES ('page-1', 'Preserved', 'preserved', 'body', 1, 1, 1);

            CREATE TABLE chats (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                summary TEXT,
                summary_at REAL,
                acp_session_id TEXT,
                model_provider_id TEXT,
                model_id TEXT
            );
            CREATE INDEX chats_updated ON chats(updated_at);
            CREATE TABLE chat_messages (
                id TEXT PRIMARY KEY,
                chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                seq INTEGER NOT NULL,
                role TEXT NOT NULL,
                event_json TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                summary TEXT,
                summary_kind TEXT,
                summary_at REAL,
                is_draft INTEGER NOT NULL DEFAULT 0,
                draft_handle TEXT
            );
            CREATE UNIQUE INDEX chat_messages_seq ON chat_messages(chat_id, seq);
            CREATE UNIQUE INDEX chat_messages_draft_handle
                ON chat_messages(draft_handle) WHERE draft_handle IS NOT NULL;
            CREATE TABLE chat_chunks (
                chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                chunk_idx INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY (chat_id, chunk_idx)
            ) WITHOUT ROWID;
            CREATE TABLE chat_search (
                chat_id TEXT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                body TEXT NOT NULL
            );
            INSERT INTO chats (id, kind, title, created_at, updated_at, acp_session_id)
            VALUES ('chat-1', 'edit', 'Legacy Chat', 1, 1, 'acp-1');
            INSERT INTO chat_messages (id, chat_id, seq, role, event_json, text, created_at)
            VALUES ('msg-1', 'chat-1', 0, 'user', '{"userText":{"_0":"hello"}}', 'hello', 1);
            INSERT INTO chat_chunks (chat_id, chunk_idx, embedding) VALUES ('chat-1', 0, X'0102');
            INSERT INTO chat_search (chat_id, title, body) VALUES ('chat-1', 'Legacy Chat', 'hello');
            PRAGMA user_version = 45;
            """,
            at: url
        )

        let store = try GRDBWikiStore(databaseURL: url)
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        let page = try store.getPage(id: PageID(rawValue: "page-1"))
        #expect(page.title == "Preserved")
        #expect(try store.listChats().isEmpty)
        #expect(try store.getMetadata(Self.tantivyMarkerKey) == "1")
    }

    #if os(macOS)
    @Test func tantivyRebuildMarkerClearsAfterServiceRebuild() async throws {
        let (store, url) = try TestStoreFactory.fileBacked(prefix: "chat-phase2-tantivy")
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "wiki-1"))
        _ = try store.createPage(title: "Searchable")
        try store.setMetadata(Self.tantivyMarkerKey, value: "1")

        let service = try TantivySearchService(
            wikiID: WikiID(rawValue: "wiki-1"),
            containerDirectory: url.deletingLastPathComponent(),
            contentSource: StoreBackedTantivyContentSource(store: store)
        )
        await service.rebuildIfNeeded()

        #expect(try store.getMetadata(Self.tantivyMarkerKey) == "0")
    }
    #endif
}
