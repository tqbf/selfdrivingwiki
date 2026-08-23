#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("Sessions plugin boot", .serialized, .timeLimit(.minutes(1)))
struct SessionsPluginBootTests {
    @Test("session appends persist until the chat persistence entry is removed")
    func sessionAppendsPersistUntilPersistenceDisposal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove sessions plugin fixture: \(error)")
            }
        }
        let databaseURL = directory.appendingPathComponent("wiki.sqlite", isDirectory: false)
        let storeEntry = Entry(
            id: EntryID("store"),
            plugin: StorePlugin.id,
            config: [
                "databasePath": .string(databaseURL.path),
                "wikiID": .string("sessions-plugin-test"),
            ])
        let sessionsEntry = Entry(id: EntryID("sessions"), plugin: SessionsPlugin.id)
        let persistenceEntry = Entry(
            id: EntryID("chat-persistence"),
            plugin: ChatsPersistencePlugin.id)
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                StorePlugin.definition,
                SessionsPlugin.definition,
                ChatsPersistencePlugin.definition,
            ]),
            layers: [PatchFile(entries: [storeEntry, sessionsEntry, persistenceEntry])]))

        let store = try #require(try await booted.context.find(StoreServiceKeys.store))
        let sessions = try #require(try await booted.context.find(SessionServiceKeys.sessions))
        let chat = try store.createChat(kind: .edit, title: "Cordis session log")

        await sessions.append(
            chatID: chat.id,
            events: [.userText("persisted"), .messageStop])
        #expect(try store.chatMessages(chatID: chat.id).map(\.event) == [.userText("persisted")])

        try await booted.tree.update(to: [storeEntry, sessionsEntry])
        await sessions.append(chatID: chat.id, events: [.assistantText("after disposal")])
        #expect(try store.chatMessages(chatID: chat.id).map(\.event) == [.userText("persisted")])

        try await booted.shutdown()
    }
}
#endif
