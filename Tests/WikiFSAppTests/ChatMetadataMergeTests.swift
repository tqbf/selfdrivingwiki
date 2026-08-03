import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

struct ChatMetadataMergeTests {
    @Test func liveTurnReplacesSamePersistedTurn() {
        let turn = ChatTurnID(rawValue: "turn")
        let persisted = usage(turnID: turn, input: 2, output: 3)
        let live = ChatMetadataLiveSnapshot(
            turnID: turn,
            state: .responding,
            providerID: ProviderID(rawValue: "provider"),
            modelID: ModelID(rawValue: "model"),
            usage: sessionUsage(input: 7, output: 11))
        let merged = ChatMetadataProjection.mergedUsage(persisted: persisted, live: live)
        #expect(merged?.turnID == turn)
        #expect(merged?.inputTokens == 7)
        #expect(merged?.outputTokens == 11)
    }

    @Test func persistedCatchUpDoesNotDoubleCount() {
        let turn = ChatTurnID(rawValue: "turn")
        let merged = ChatMetadataProjection.mergedUsages(
            persisted: [usage(turnID: turn, input: 7, output: 11)],
            live: .init(turnID: turn, state: .responding, providerID: nil, modelID: nil, usage: sessionUsage(input: 7, output: 11)))
        #expect(merged.count == 1)
        #expect(merged[0].inputTokens == 7)
        #expect(merged[0].outputTokens == 11)
    }

    @Test func differentTurnRemainsHistorical() {
        let persisted = usage(turnID: .init(rawValue: "old"), input: 2, output: 3)
        let merged = ChatMetadataProjection.mergedUsages(
            persisted: [persisted],
            live: .init(turnID: .init(rawValue: "active"), state: .responding, providerID: nil, modelID: nil, usage: sessionUsage(input: 7, output: 11)))
        #expect(merged.map(\.turnID) == [ChatTurnID(rawValue: "old"), ChatTurnID(rawValue: "active")])
        #expect(merged.first?.inputTokens == 2)
        #expect(merged.last?.inputTokens == 7)
    }

    @Test func terminalPersistedValueReplacesLiveOverlay() {
        let turn = ChatTurnID(rawValue: "turn")
        let live = ChatMetadataLiveSnapshot(turnID: turn, state: .responding, providerID: nil, modelID: nil, usage: sessionUsage(input: 7, output: 11))
        let terminal = usage(turnID: turn, input: 8, output: 13)
        #expect(ChatMetadataProjection.mergedUsage(persisted: terminal, live: nil) == terminal)
        #expect(ChatMetadataProjection.mergedUsage(persisted: terminal, live: live)?.inputTokens == 7)
    }

    private func usage(turnID: ChatTurnID, input: Int, output: Int) -> ChatTurnUsage {
        .init(turnID: turnID, providerID: nil, modelID: nil, startedAt: .distantPast, finishedAt: nil, state: .providerSubmitted, inputTokens: input, outputTokens: output, thoughtTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, cost: nil, currency: nil)
    }

    private func sessionUsage(input: Int, output: Int) -> SessionUsage {
        .init(inputTokens: input, outputTokens: output, totalTokens: input + output, cachedReadTokens: nil, thoughtTokens: nil, cost: nil, currency: nil, contextUsed: 0, contextSize: 0)
    }
}
