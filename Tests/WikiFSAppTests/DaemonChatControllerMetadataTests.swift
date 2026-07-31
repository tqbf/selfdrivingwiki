#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

@MainActor
struct DaemonChatControllerMetadataTests {
    @Test func startClaimsAndSnapshotsConfiguration() async throws {
        let harness = try ControllerHarness()
        let provider = ProviderID(rawValue: "provider-claim")
        let model = ModelID(rawValue: "model-claim")
        try harness.store.updateChatModelOverride(id: harness.chat.id, providerId: provider, modelId: model)
        let controller = try harness.makeController(clock: { Date(timeIntervalSince1970: 42) })
        let submission = harness.makeSubmission(commandID: "claim-command", turnID: "claim-turn")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))

        let turn = try #require(try harness.store.listPersistedChatTurns(chatID: harness.chat.id).first)
        let request = try #require((await harness.runtime.snapshot()).startRequests.first)
        #expect(turn.claimedAt == Date(timeIntervalSince1970: 42))
        #expect(turn.providerID == request.providerID)
        #expect(turn.modelID == request.modelID)
    }

    @Test func successWinsTerminalRace() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "success-race-command", turnID: "success-race-turn")
        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))

        await harness.runtime.emit(.turnCompleted(submission.turnID))
        await harness.runtime.emit(.turnFailed(turnID: submission.turnID, category: .runtimeError, message: "late"))

        let turn = try await terminalTurn(harness, turnID: submission.turnID)
        #expect(turn.state == .completed)
    }

    @Test func cancelWinsTerminalRace() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "cancel-race-command", turnID: "cancel-race-turn")
        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))

        await controller.cancel(turnID: submission.turnID)
        await harness.runtime.emit(.turnCompleted(submission.turnID))

        let turn = try await terminalTurn(harness, turnID: submission.turnID)
        #expect(turn.state == .cancelled)
    }

    @Test func transportCloseInterruptsActiveTurn() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "close-command", turnID: "close-turn")
        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))

        await harness.runtime.emit(.transportClosed(status: 9))

        let turn = try await terminalTurn(harness, turnID: submission.turnID)
        #expect(turn.state == .failed)
        #expect(turn.terminalMessage == "The daemon transport exited before the turn completed.")
    }

    @Test func staleGenerationUsageIsRejected() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "stale-usage-command", turnID: "stale-usage-turn")
        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))

        await harness.runtime.emit(.usage(usage(input: 8, output: 3)), generation: ChatSessionGenerationID(rawValue: "stale"))
        for _ in 0..<10 { await Task.yield() }

        let turn = try #require(try harness.store.listPersistedChatTurns(chatID: harness.chat.id).first)
        #expect(turn.usage.inputTokens == nil)
    }

    @Test func staleGenerationTerminalIsRejected() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "stale-terminal-command", turnID: "stale-terminal-turn")
        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))

        await harness.runtime.emit(.turnCompleted(submission.turnID), generation: ChatSessionGenerationID(rawValue: "stale"))
        for _ in 0..<10 { await Task.yield() }

        let turn = try #require(try harness.store.listPersistedChatTurns(chatID: harness.chat.id).first)
        #expect(turn.state == .providerSubmitted)
    }

    @Test func terminalUsageUpdateIsRejected() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "terminal-usage-command", turnID: "terminal-usage-turn")
        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        await harness.runtime.emit(.usage(usage(input: 5, output: 2)))
        for _ in 0..<10 { await Task.yield() }
        let persistedUsage = try #require(try harness.store.chatTurnUsage(chatID: harness.chat.id, turnID: submission.turnID))
        #expect(persistedUsage.inputTokens == 5)
        #expect(persistedUsage.outputTokens == 2)
        await harness.runtime.emit(.turnCompleted(submission.turnID))
        let terminal = try await terminalTurn(harness, turnID: submission.turnID)
        await harness.runtime.emit(.usage(usage(input: 9, output: 4)))
        for _ in 0..<10 { await Task.yield() }

        let after = try #require(try harness.store.listPersistedChatTurns(chatID: harness.chat.id).first)
        #expect(after.usage == terminal.usage)
    }

    @Test func restartUsesInjectedBootstrapClock() throws {
        let harness = try ControllerHarness()
        let queued = try harness.store.enqueuePersistedChatTurn(
            chatID: harness.chat.id,
            submission: harness.makeSubmission(commandID: "restart-clock-command", turnID: "restart-clock-turn")
        )
        _ = try harness.store.claimNextPersistedChatTurn(
            chatID: harness.chat.id,
            claimID: ChatTurnClaimID(rawValue: "restart-clock-claim"),
            claimedAt: Date(timeIntervalSince1970: 1)
        )
        let bootstrapAt = Date(timeIntervalSince1970: 99)

        _ = try harness.makeController(clock: { bootstrapAt })

        let turn = try #require(try harness.store.listPersistedChatTurns(chatID: harness.chat.id).first(where: { $0.submission.turnID == queued.submission.turnID }))
        #expect(turn.finishedAt == bootstrapAt)
        #expect(turn.state == .failed)
    }

    @Test func duplicateCommandReturnsExistingTurn() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "duplicate-command", turnID: "duplicate-turn")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))

        #expect(try harness.store.listPersistedChatTurns(chatID: harness.chat.id).count == 1)
    }

    @Test func warmSessionSubtractsBaseline() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let first = harness.makeSubmission(commandID: "warm-first-command", turnID: "warm-first-turn")
        _ = try await controller.submit(harness.makeSubmitRequest(submission: first))
        await harness.runtime.emit(.usage(usage(input: 10, output: 4)))
        try await usageValues(harness, turnID: first.turnID, input: 10, output: 4)
        await harness.runtime.emit(.turnCompleted(first.turnID))
        _ = try await terminalTurn(harness, turnID: first.turnID)

        let second = harness.makeSubmission(commandID: "warm-second-command", turnID: "warm-second-turn")
        _ = try await controller.submit(harness.makeSubmitRequest(submission: second))
        await harness.runtime.emit(.usage(usage(input: 17, output: 7)))
        try await usageValues(harness, turnID: second.turnID, input: 7, output: 3)
    }

    private func terminalTurn(_ harness: ControllerHarness, turnID: ChatTurnID) async throws -> PersistedChatTurn {
        for _ in 0..<100 {
            if let turn = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
                .first(where: {
                    $0.submission.turnID == turnID
                        && [.completed, .cancelled, .failed].contains($0.state)
                }) {
                return turn
            }
            await Task.yield()
        }
        throw MetadataTestError.terminalTurnDidNotArrive(turnID)
    }

    private func usageValues(
        _ harness: ControllerHarness,
        turnID: ChatTurnID,
        input: Int,
        output: Int
    ) async throws {
        for _ in 0..<100 {
            if let usage = try harness.store.chatTurnUsage(chatID: harness.chat.id, turnID: turnID),
               usage.inputTokens == input,
               usage.outputTokens == output {
                return
            }
            await Task.yield()
        }
        throw MetadataTestError.usageDidNotArrive(turnID)
    }

    private func usage(input: Int, output: Int) -> SessionUsage {
        SessionUsage(
            inputTokens: input, outputTokens: output, totalTokens: input + output,
            cachedReadTokens: nil, thoughtTokens: nil, cost: nil, currency: nil,
            contextUsed: 0, contextSize: 0
        )
    }
}

private enum MetadataTestError: Error {
    case terminalTurnDidNotArrive(ChatTurnID)
    case usageDidNotArrive(ChatTurnID)
}
#endif
