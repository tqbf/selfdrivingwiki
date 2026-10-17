import Foundation
import Testing
@testable import WikiFSCore

/// Schema pins for the `chat_attachments` table (v57→v58): the ladder
/// recreates a dropped table while preserving chats, and the fresh schema is
/// born with the table at the current version. Modeled on
/// `ChangeRevisionTests` (rewind → reopen → assert), NON-self-satisfying:
/// the rewind drops the future table before stamping v57.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatAttachmentsMigrationTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-attach-migrate-\(UUID().uuidString).sqlite")
    }

    @Test("a v57 DB with the future table dropped migrates to v58 and preserves chats")
    func v57DBMigratesToV58PreservingChats() throws {
        let url = tempURL()
        let store = try GRDBWikiStore(databaseURL: url)
        let survivor = try store.createChat(kind: .edit, title: "Survivor")
        store.close()

        // Rewind to v57 WITHOUT the future table (a v57 DB cannot have it).
        var rewind = "DROP TABLE IF EXISTS chat_attachments;\n"
        rewind += "DROP INDEX IF EXISTS chat_attachments_by_chat;\n"
        rewind += "PRAGMA user_version = 57;"
        try MetadataSQLiteFixtureSupport.execute(rewind, at: url)

        let migrated = try GRDBWikiStore(databaseURL: url)
        #expect(migrated.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        #expect(GRDBWikiStore.schemaVersion == 58)

        // The table is recreated (empty) and usable.
        #expect(try migrated.chatAttachments(chatID: survivor.id).isEmpty)
        try migrated.setChatAttachments(chatID: survivor.id, targets: [
            .page(PageID(rawValue: "01HPOSTMIGRATE")),
        ])
        #expect(try migrated.chatAttachments(chatID: survivor.id)
            == [.page(PageID(rawValue: "01HPOSTMIGRATE"))])

        // The chat survived the migration.
        #expect(try migrated.listChats().map(\.title) == ["Survivor"])
    }

    @Test("a fresh DB is created at v58 with the chat_attachments table")
    func freshDBHasTheTableAtCurrentVersion() throws {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        #expect(GRDBWikiStore.schemaVersion == 58)

        // The table exists and is usable on the fresh path too.
        let chat = try store.createChat(kind: .edit, title: "")
        #expect(try store.chatAttachments(chatID: chat.id).isEmpty)
        try store.setChatAttachments(chatID: chat.id, targets: [
            .source(SourceID(rawValue: "01HFRESH")),
        ])
        #expect(try store.chatAttachments(chatID: chat.id)
            == [.source(SourceID(rawValue: "01HFRESH"))])
    }
}
