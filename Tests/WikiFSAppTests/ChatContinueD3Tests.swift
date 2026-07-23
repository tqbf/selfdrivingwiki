#if os(macOS)
import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for Phase D3 — continue a persisted chat (seeded-fallback).
///
/// Three gate points:
///   (a) `continuationPreamble` — byte cap enforced, user/assistant roles only,
///       the "continuing an earlier chat" preamble present, and the new
///       user message included in full at the end.
///   (b) `continueTakeoverDecision` — the takeover matrix: idle → take over;
///       between-turns (interactive session alive, not generating) → end-then-
///       take-over; mid-generation (or queued) → refused.
///   (c) continue appends to the SAME chat row — `seq` continues, title
///       preserved, `updatedAt` bumps.
@MainActor
struct ChatContinueD3Tests {

    private func tempModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-d3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    // MARK: - (a) continuationPreamble builder

    private func msg(_ seq: Int, _ event: AgentEvent) -> ChatMessage {
        ChatMessage(
            id: PageID(rawValue: "01MSG\(seq)\(String(repeating: "0", count: 20))"),
            chatID: PageID(rawValue: "01CHAT\(String(repeating: "0", count: 22))"),
            seq: seq,
            event: event,
            createdAt: Date(timeIntervalSince1970: TimeInterval(1000 + seq)))
    }

    @Test func preambleIncludesUserAndAssistantRowsOnly() {
        let messages: [ChatMessage] = [
            msg(0, .userText("What is this wiki about?")),
            msg(1, .assistantText("It is about testing.")),
            msg(2, .toolUse(name: "Bash", inputSummary: "wikictl page list")),
            msg(3, .toolResult(isError: false, summary: "[page1, page2]")),
            msg(4, .systemInit(model: "claude")),
            msg(5, .assistantText("More detail here.")),
        ]
        let preamble = AgentOperationRunner.continuationPreamble(
            from: messages, newMessage: "Tell me more about page1.", maxBytes: 10_000)

        // The user/assistant text rows survive; tool/system rows are dropped.
        #expect(preamble.contains("What is this wiki about?"))
        #expect(preamble.contains("It is about testing."))
        #expect(preamble.contains("More detail here."))
        #expect(!preamble.contains("wikictl page list"))
        #expect(!preamble.contains("page1, page2"))
        #expect(!preamble.contains("claude"))  // systemInit model is dropped
    }

    @Test func preambleHasContinuingHeaderAndNewMessage() {
        let messages: [ChatMessage] = [
            msg(0, .userText("Hello")),
            msg(1, .assistantText("Hi")),
        ]
        let preamble = AgentOperationRunner.continuationPreamble(
            from: messages, newMessage: "Next question?", maxBytes: 10_000)

        // The "continuing an earlier chat" preamble is present.
        #expect(preamble.contains("continuing an earlier chat"))
        // The new user message is included in full at the end.
        #expect(preamble.contains("--- new message ---"))
        #expect(preamble.contains("Next question?"))
        #expect(preamble.hasSuffix("Next question?"))
    }

    @Test func preambleByteCapIsEnforced() {
        // Each assistant row is ~100 bytes; cap at 600 bytes so only a few fit.
        let big = String(repeating: "x", count: 200)
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            messages.append(msg(i * 2, .userText("Q\(i) " + big)))
            messages.append(msg(i * 2 + 1, .assistantText("A\(i) " + big)))
        }
        let maxBytes = 600
        let preamble = AgentOperationRunner.continuationPreamble(
            from: messages, newMessage: "final", maxBytes: maxBytes)

        // The total UTF-8 size must not exceed the cap (a couple bytes of slack
        // for the head-trim rounding).
        #expect(preamble.utf8.count <= maxBytes + 8)
        // The new message is ALWAYS included in full, even under the cap.
        #expect(preamble.hasSuffix("final"))
        // Older rows are dropped in favor of the most recent context.
        #expect(!preamble.contains("Q0 "))
    }

    @Test func preambleEmptyHistoryIsJustNewMessage() {
        let preamble = AgentOperationRunner.continuationPreamble(
            from: [], newMessage: "Fresh start", maxBytes: 10_000)

        // No transcript rows → the header + footer + new message only.
        #expect(preamble.contains("continuing an earlier chat"))
        #expect(preamble.hasSuffix("Fresh start"))
    }

    @Test func preambleIncludesResultTextAsAssistant() {
        // A `.result` with non-empty text doubles as the final assistant answer.
        let messages: [ChatMessage] = [
            msg(0, .userText("Summarize")),
            msg(1, .result(isError: false, text: "Here is the summary.")),
        ]
        let preamble = AgentOperationRunner.continuationPreamble(
            from: messages, newMessage: "Thanks", maxBytes: 10_000)

        #expect(preamble.contains("Here is the summary."))
    }

    @Test func preambleDeduplicatesAssistantTextAndResult() {
        // A turn typically persists BOTH `.assistantText` (streamed) and
        // `.result` (boundary) with identical text. The preamble must include
        // the text only ONCE — not duplicated.
        let messages: [ChatMessage] = [
            msg(0, .userText("What is Paris?")),
            msg(1, .assistantText("Paris is the capital of France.")),
            msg(2, .result(isError: false, text: "Paris is the capital of France.")),
        ]
        let preamble = AgentOperationRunner.continuationPreamble(
            from: messages, newMessage: "Next", maxBytes: 10_000)

        // The text appears exactly once (count the occurrences).
        let count = preamble.components(separatedBy: "Paris is the capital of France.").count - 1
        #expect(count == 1)
    }

    @Test func preambleRespectsMaxTurns() {
        // 20 user/assistant turns, maxTurns = 4 → only the last 4 survive.
        var messages: [ChatMessage] = []
        for i in 0..<20 {
            messages.append(msg(i, .userText("turn\(i)")))
        }
        let preamble = AgentOperationRunner.continuationPreamble(
            from: messages, newMessage: "end", maxTurns: 4, maxBytes: 100_000)

        #expect(!preamble.contains("turn0"))
        #expect(!preamble.contains("turn15"))
        #expect(preamble.contains("turn16"))
        #expect(preamble.contains("turn17"))
        #expect(preamble.contains("turn18"))
        #expect(preamble.contains("turn19"))
    }

    // MARK: - (b) takeover predicate

    @Test func takeover_idle_whenNothingRunning() {
        let decision = AgentOperationRunner.continueTakeoverDecision(
            isRunning: false, isInteractiveSession: false,
            isGenerating: false, isAwaitingGenerationSlot: false)
        #expect(decision == .idle)
    }

    @Test func takeover_betweenTurns_whenSessionAliveButIdle() {
        // An interactive session process is alive, but not generating (between
        // turns — the gate and edit lock released at the last messageStop).
        let decision = AgentOperationRunner.continueTakeoverDecision(
            isRunning: true, isInteractiveSession: true,
            isGenerating: false, isAwaitingGenerationSlot: false)
        #expect(decision == .betweenTurns)
    }

    @Test func takeover_refused_whenGenerating() {
        let decision = AgentOperationRunner.continueTakeoverDecision(
            isRunning: true, isInteractiveSession: true,
            isGenerating: true, isAwaitingGenerationSlot: false)
        #expect(decision == .refused)
    }

    @Test func takeover_refused_whenAwaitingSlot() {
        // Queued behind another launcher's generation → cannot interrupt.
        let decision = AgentOperationRunner.continueTakeoverDecision(
            isRunning: true, isInteractiveSession: true,
            isGenerating: false, isAwaitingGenerationSlot: true)
        #expect(decision == .refused)
    }

    @Test func takeover_betweenTurns_whenNonInteractiveRunAliveButNotGenerating() {
        // Edge case: a one-shot run (ingest/lint) somehow alive without the
        // generation flag. End it rather than strand a process.
        let decision = AgentOperationRunner.continueTakeoverDecision(
            isRunning: true, isInteractiveSession: false,
            isGenerating: false, isAwaitingGenerationSlot: false)
        #expect(decision == .betweenTurns)
    }

    @Test func takeover_refused_whenGeneratingAndNotInteractive() {
        // Generating always wins over the interactive check.
        let decision = AgentOperationRunner.continueTakeoverDecision(
            isRunning: true, isInteractiveSession: false,
            isGenerating: true, isAwaitingGenerationSlot: false)
        #expect(decision == .refused)
    }

    // MARK: - (c) continue appends to the SAME chat row

    @Test func continueAppendsToSameChatRow_seqContinues_titlePreserved() throws {
        let (model, store) = try tempModel()
        // Create a chat with two persisted messages (a prior turn).
        let chat = try store.createChat(kind: .edit, title: "Original Title")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .userText("first question"),
            .assistantText("first answer"),
        ])
        model.reloadFromStore()

        // Simulate the continue path's STORE effect: append the new session's
        // events to the SAME chat row (this is what the transcript sink does).
        // The builder produces the first prompt from the persisted history.
        let history = model.chatMessages(chatID: chat.id)
        let firstPrompt = AgentOperationRunner.continuationPreamble(
            from: history, newMessage: "follow up question")
        #expect(firstPrompt.contains("first question"))
        #expect(firstPrompt.contains("first answer"))
        #expect(firstPrompt.contains("follow up question"))

        // Append the new session's first events to the same row (seq continues).
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .userText(firstPrompt),
            .assistantText("follow up answer"),
        ])
        model.reloadChats()

        let after = model.chatMessages(chatID: chat.id)
        // Seq continues: 0,1 (original) + 2,3 (continue) = 4 rows.
        #expect(after.count == 4)
        #expect(after.map(\.seq) == [0, 1, 2, 3])
        // The continued prompt and answer are the last two rows.
        #expect(after[2].event == .userText(firstPrompt))
        #expect(after[3].event == .assistantText("follow up answer"))

        // Title is preserved across the continue.
        let summary = model.chats.first { $0.id == chat.id }
        #expect(summary?.title == "Original Title")
    }

    @Test func continueBumpsUpdatedAtToTopOfRecent() throws {
        let (model, store) = try tempModel()
        let chat = try store.createChat(kind: .edit, title: "Older Chat")
        let other = try store.createChat(kind: .edit, title: "Newer Chat")
        _ = try store.appendChatMessages(chatID: chat.id, events: [.userText("a"), .assistantText("b")])
        _ = try store.appendChatMessages(chatID: other.id, events: [.userText("c"), .assistantText("d")])
        model.reloadChats()

        // `other` was created later → it's on top initially.
        let initial = model.chats.sorted { $0.updatedAt > $1.updatedAt }
        #expect(initial.first?.id == other.id)

        // Continuing `chat` appends to it, bumping its updatedAt past `other`.
        _ = try store.appendChatMessages(chatID: chat.id, events: [.userText("continue")])
        model.reloadChats()

        let after = model.chats.sorted { $0.updatedAt > $1.updatedAt }
        #expect(after.first?.id == chat.id)
    }

    // MARK: - (d) adaptive preamble budget (#825)

    @Test func adaptiveBudget_shortConversation_usesFloorBudget() {
        // A shallow conversation (depth ≤ floorDepth) gets the legacy cap.
        let budget = AgentOperationRunner.adaptivePreambleBudget(eligibleTurns: 3)
        #expect(budget.maxTurns == AgentOperationRunner.adaptiveFloorTurns)
        #expect(budget.maxBytes == AgentOperationRunner.adaptiveFloorBytes)
    }

    @Test func adaptiveBudget_atFloorDepth_usesFloorBudget() {
        // Exactly at the floor depth → still the floor budget (ramp starts above).
        let budget = AgentOperationRunner.adaptivePreambleBudget(
            eligibleTurns: AgentOperationRunner.adaptiveFloorDepth)
        #expect(budget.maxTurns == AgentOperationRunner.adaptiveFloorTurns)
        #expect(budget.maxBytes == AgentOperationRunner.adaptiveFloorBytes)
    }

    @Test func adaptiveBudget_zeroDepthStillYieldsFloor() {
        // Depth 0 (empty/fresh chat) is clamped to the floor — never negative
        // or zero, so the header + new message still render as before.
        let budget = AgentOperationRunner.adaptivePreambleBudget(eligibleTurns: 0)
        #expect(budget.maxTurns == AgentOperationRunner.adaptiveFloorTurns)
        #expect(budget.maxBytes == AgentOperationRunner.adaptiveFloorBytes)
    }

    @Test func adaptiveBudget_rampsUpBetweenFloorAndCeiling() {
        // A mid-depth conversation lands strictly between floor and ceiling.
        let midDepth = (AgentOperationRunner.adaptiveFloorDepth
                        + AgentOperationRunner.adaptiveCeilingDepth) / 2
        let floor = AgentOperationRunner.adaptivePreambleBudget(
            eligibleTurns: AgentOperationRunner.adaptiveFloorDepth)
        let mid = AgentOperationRunner.adaptivePreambleBudget(eligibleTurns: midDepth)
        let ceiling = AgentOperationRunner.adaptivePreambleBudget(
            eligibleTurns: AgentOperationRunner.adaptiveCeilingDepth)

        // Monotonic: floor ≤ mid ≤ ceiling in both dimensions.
        #expect(mid.maxTurns >= floor.maxTurns)
        #expect(mid.maxTurns <= ceiling.maxTurns)
        #expect(mid.maxBytes >= floor.maxBytes)
        #expect(mid.maxBytes <= ceiling.maxBytes)
        // The ramp actually grows past the floor for a deep-ish conversation.
        #expect(mid.maxTurns > floor.maxTurns)
        #expect(mid.maxBytes > floor.maxBytes)
    }

    @Test func adaptiveBudget_atCeilingDepth_reachesCeiling() {
        // At the ceiling depth the budget saturates at the ceiling values.
        let budget = AgentOperationRunner.adaptivePreambleBudget(
            eligibleTurns: AgentOperationRunner.adaptiveCeilingDepth)
        #expect(budget.maxTurns == AgentOperationRunner.adaptiveCeilingTurns)
        #expect(budget.maxBytes == AgentOperationRunner.adaptiveCeilingBytes)
    }

    @Test func adaptiveBudget_farAboveCeiling_saturates() {
        // Far beyond the ceiling depth → identical to the at-ceiling budget.
        let atCeiling = AgentOperationRunner.adaptivePreambleBudget(
            eligibleTurns: AgentOperationRunner.adaptiveCeilingDepth)
        let farAbove = AgentOperationRunner.adaptivePreambleBudget(
            eligibleTurns: AgentOperationRunner.adaptiveCeilingDepth * 10)
        #expect(farAbove.maxTurns == atCeiling.maxTurns)
        #expect(farAbove.maxBytes == atCeiling.maxBytes)
    }

    @Test func adaptiveBudget_isMonotonicNonDecreasingAcrossDepth() {
        // Sweeping depth 0…ceiling+20 must never decrease either dimension.
        var prev = AgentOperationRunner.adaptivePreambleBudget(eligibleTurns: 0)
        for depth in 1...(AgentOperationRunner.adaptiveCeilingDepth + 20) {
            let cur = AgentOperationRunner.adaptivePreambleBudget(eligibleTurns: depth)
            #expect(cur.maxTurns >= prev.maxTurns)
            #expect(cur.maxBytes >= prev.maxBytes)
            prev = cur
        }
    }

    @Test func adaptiveBudget_neverExceedsCeiling() {
        // Bounded: no depth, however large, exceeds the ceiling budget.
        for depth in [0, 1, 10, 50, 80, 100, 1_000, 1_000_000] {
            let budget = AgentOperationRunner.adaptivePreambleBudget(eligibleTurns: depth)
            #expect(budget.maxTurns <= AgentOperationRunner.adaptiveCeilingTurns)
            #expect(budget.maxBytes <= AgentOperationRunner.adaptiveCeilingBytes)
        }
    }

    @Test func projectedPreambleTurns_countsEligibleUserAssistantRows() {
        // Depth is measured the same way the window is filled: user/assistant
        // text rows only, with the .result-duplicates-.assistantText dedup.
        let messages: [ChatMessage] = [
            msg(0, .userText("q")),
            msg(1, .assistantText("a")),
            msg(2, .toolUse(name: "Bash", inputSummary: "x")),
            msg(3, .toolResult(isError: false, summary: "y")),
            msg(4, .systemInit(model: "m")),
            msg(5, .result(isError: false, text: "a")),  // dup of msg1 → dropped
        ]
        let turns = AgentOperationRunner.projectedPreambleTurns(from: messages)
        #expect(turns.count == 2)
        #expect(turns.map(\.role) == ["user", "assistant"])
    }

    @Test func preambleAdaptiveWindowKeepsMoreTurnsForDeepConversations() {
        // A 40-turn conversation. The legacy flat 10-turn cap would keep only
        // turn30…turn39; the adaptive window scales maxTurns up for this depth,
        // so it retains early turns the flat cap would have lost. Byte budget
        // is generous here so the turn-count window is the binding constraint.
        var messages: [ChatMessage] = []
        for i in 0..<40 {
            messages.append(msg(i, .userText("turn\(i)")))
        }
        let depth = AgentOperationRunner.projectedPreambleTurns(from: messages).count
        let budget = AgentOperationRunner.adaptivePreambleBudget(eligibleTurns: depth)

        #expect(depth == 40)
        #expect(budget.maxTurns > AgentOperationRunner.adaptiveFloorTurns)   // ramp grew
        #expect(budget.maxTurns <= AgentOperationRunner.adaptiveCeilingTurns)

        let preamble = AgentOperationRunner.continuationPreamble(
            from: messages, newMessage: "next",
            maxTurns: budget.maxTurns, maxBytes: budget.maxBytes)

        // Parse the surviving turn indices per-line (avoids the "turn1" ⊂
        // "turn10" substring trap).
        let prefix = "[user] turn"
        let kept: Set<Int> = Set(
            preamble.split(separator: "\n").compactMap { line -> Int? in
                let s = String(line)
                guard s.hasPrefix(prefix) else { return nil }
                return Int(s.dropFirst(prefix.count))
            }
        )
        #expect(kept.contains(39))                 // most recent always survives
        let lowestKept = kept.min() ?? -1
        #expect(lowestKept >= 0 && lowestKept < 30)  // an early turn legacy cap drops
    }

    @Test func preambleAdaptiveWindowStillRespectsByteCeiling() {
        // Even with the grown byte budget, deep + verbose conversations stay
        // within the ceiling; the new message is always included in full.
        let big = String(repeating: "x", count: 400)
        var messages: [ChatMessage] = []
        for i in 0..<100 {  // well past the ceiling depth → ceiling budget
            messages.append(msg(i, .userText("Q\(i) " + big)))
            messages.append(msg(i + 100, .assistantText("A\(i) " + big)))
        }
        let budget = AgentOperationRunner.adaptivePreambleBudget(
            eligibleTurns: AgentOperationRunner.projectedPreambleTurns(from: messages).count)
        #expect(budget.maxBytes == AgentOperationRunner.adaptiveCeilingBytes)

        let preamble = AgentOperationRunner.continuationPreamble(
            from: messages, newMessage: "the real new question",
            maxTurns: budget.maxTurns, maxBytes: budget.maxBytes)

        // Bounded by the ceiling (+ a couple bytes slack for head-trim rounding).
        #expect(preamble.utf8.count <= AgentOperationRunner.adaptiveCeilingBytes + 8)
        #expect(preamble.hasSuffix("the real new question"))
    }
}
#endif
