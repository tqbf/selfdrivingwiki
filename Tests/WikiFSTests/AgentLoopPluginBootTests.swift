#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("Agent loop plugin boot", .serialized, .timeLimit(.minutes(1)))
struct AgentLoopPluginBootTests {
    @Test("minimal turn appends lifecycle events and pre-step can short-circuit")
    func minimalTurnAppendsEventsAndPreStepShortCircuits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-loop-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove agent loop plugin fixture: \(error)")
            }
        }
        let databaseURL = directory.appendingPathComponent("wiki.sqlite", isDirectory: false)
        let storeEntry = Entry(
            id: EntryID("store"),
            plugin: StorePlugin.id,
            config: [
                "databasePath": .string(databaseURL.path),
                "wikiID": .string("agent-loop-plugin-test"),
            ])
        let sessionsEntry = Entry(id: EntryID("sessions"), plugin: SessionsPlugin.id)
        let persistenceEntry = Entry(
            id: EntryID("chat-persistence"),
            plugin: ChatsPersistencePlugin.id)
        let agentLoopEntry = Entry(id: EntryID("agent-loop"), plugin: AgentLoopPlugin.id)
        let handlerID = PluginID("test.agent-loop-handler")
        let handler = PluginDefinition(
            id: handlerID,
            dependencies: [ServiceDependency(AgentLoopServiceKeys.agentLoop)]
        ) {
            try ComponentDefinition(
                label: "test.agent-loop-handler",
                dependencies: [ServiceDependency(AgentLoopServiceKeys.agentLoop)]
            ) { activation in
                _ = try await activation.require(AgentLoopServiceKeys.agentLoop)
                _ = try await activation.on(AgentLoopEventKeys.preStep) { request, next in
                    guard request.prompt == "blocked" else { return try await next() }
                    var request = request
                    request.events = [.assistantText("blocked by policy")]
                    return request
                }
                _ = try await activation.on(AgentLoopEventKeys.request) { request, _ in
                    var request = request
                    request.events = [.assistantText("stub response")]
                    return request
                }
            }
        }
        let handlerEntry = Entry(id: EntryID("handler"), plugin: handlerID)
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                StorePlugin.definition,
                SessionsPlugin.definition,
                ChatsPersistencePlugin.definition,
                AgentLoopPlugin.definition,
                handler,
            ]),
            layers: [PatchFile(entries: [
                storeEntry, sessionsEntry, persistenceEntry, agentLoopEntry, handlerEntry,
            ])]))

        let store = try #require(try await booted.context.find(StoreServiceKeys.store))
        let agentLoop = try #require(try await booted.context.find(AgentLoopServiceKeys.agentLoop))
        let chat = try store.createChat(kind: .edit, title: "Cordis agent loop")
        let turn = AgentTurnRequest(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            userText: "hello")

        let events = try await agentLoop.enqueue(turn)
        #expect(events == [.assistantText("stub response")])
        #expect(try store.chatMessages(chatID: chat.id).map(\.event) == [
            .userText("hello"),
            .assistantText("stub response"),
        ])

        let gated = try await agentLoop.preStep(AgentStepRequest(turn: turn, prompt: "blocked"))
        #expect(gated.events == [.assistantText("blocked by policy")])

        try await booted.shutdown()
    }
}
#endif
