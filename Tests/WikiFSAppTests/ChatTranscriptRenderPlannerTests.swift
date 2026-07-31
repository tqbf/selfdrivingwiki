#if os(macOS)
import Testing
@testable import WikiFS
@testable import WikiFSTypes

struct ChatTranscriptRenderPlannerTests {
    private let transcript = TranscriptID.chat(ChatID(rawValue: "chat-render"))
    private let turn = ChatTurnID(rawValue: "turn-render")

    @Test func firstSnapshotReloadsAndUnchangedSnapshotDoesNothing() {
        let desired = snapshot(rows: [row("a", text: "One")])
        #expect(ChatTranscriptRenderPlanner.commands(previous: nil, desired: desired) == [.reload(desired)])
        #expect(ChatTranscriptRenderPlanner.commands(previous: desired, desired: desired).isEmpty)
    }

    @Test func sameIdentityWithNewContentReplacesThatRow() {
        let previous = snapshot(rows: [row("a", text: "Before")])
        let changed = row("a", text: "After")
        #expect(ChatTranscriptRenderPlanner.commands(
            previous: previous,
            desired: snapshot(rows: [changed])
        ) == [.replace(changed)])
    }

    @Test func differentIdentityAtEqualCountReloadsInsteadOfReplacingLastRow() {
        let previous = snapshot(rows: [row("a", text: "One")])
        let desired = snapshot(rows: [row("b", text: "Two")])
        #expect(ChatTranscriptRenderPlanner.commands(previous: previous, desired: desired) == [.reload(desired)])
    }

    @Test func tailRowsAppendAndMiddleRowsInsertByIdentity() {
        let a = row("a", text: "A")
        let b = row("b", text: "B")
        let c = row("c", text: "C")
        #expect(ChatTranscriptRenderPlanner.commands(
            previous: snapshot(rows: [a]), desired: snapshot(rows: [a, b, c])
        ) == [.append([b, c])])
        #expect(ChatTranscriptRenderPlanner.commands(
            previous: snapshot(rows: [a, c]), desired: snapshot(rows: [a, b, c])
        ) == [.insert(b, before: c.id)])
    }

    @Test func existingReplacementStaysAheadOfAnAppendBoundary() {
        let before = row("a", text: "Before")
        let after = row("a", text: "After")
        let appended = row("b", text: "New block")
        #expect(ChatTranscriptRenderPlanner.commands(
            previous: snapshot(rows: [before]),
            desired: snapshot(rows: [after, appended])
        ) == [.replace(after), .append([appended])])
    }

    @Test func removesByIdentityAndReloadsForReorderOrContextChange() {
        let a = row("a", text: "A")
        let b = row("b", text: "B")
        let c = row("c", text: "C")
        #expect(ChatTranscriptRenderPlanner.commands(
            previous: snapshot(rows: [a, b, c]), desired: snapshot(rows: [a, c])
        ) == [.remove(b.id)])

        let previous = snapshot(rows: [a, b])
        let reordered = snapshot(rows: [b, a])
        #expect(ChatTranscriptRenderPlanner.commands(previous: previous, desired: reordered) == [.reload(reordered)])

        let reset = ChatTranscriptRenderSnapshot(
            context: .init(transcriptID: transcript, resetToken: 1), rows: [a, b]
        )
        #expect(ChatTranscriptRenderPlanner.commands(previous: previous, desired: reset) == [.reload(reset)])

        let styleChange = ChatTranscriptRenderSnapshot(
            context: .init(transcriptID: transcript, style: .activityFeed), rows: [a, b]
        )
        #expect(ChatTranscriptRenderPlanner.commands(previous: previous, desired: styleChange) == [.reload(styleChange)])
    }

    private func snapshot(rows: [ChatDisplayRow]) -> ChatTranscriptRenderSnapshot {
        .init(context: .init(transcriptID: transcript), rows: rows)
    }

    private func row(_ id: String, text: String) -> ChatDisplayRow {
        .assistantMessage(
            id: ChatMessageID(rawValue: id),
            turnID: turn,
            text: text,
            createdAt: .distantPast,
            contentState: .final
        )
    }
}

@MainActor
struct ChatTranscriptRenderExecutorTests {
    private let transcript = TranscriptID.chat(ChatID(rawValue: "chat-executor"))
    private let turn = ChatTurnID(rawValue: "turn-executor")

    @Test func serializesCommandsUntilEachRevisionAcknowledges() {
        let recorder = RenderMutationRecorder()
        let executor = makeExecutor(recorder)
        let a = row("a", text: "A")
        let b = row("b", text: "B")

        executor.submit(snapshot([a]))
        #expect(recorder.commands.count == 1)
        #expect(executor.state == .awaitingReload)
        recorder.succeedCurrent()
        executor.submit(snapshot([a, b]))
        #expect(recorder.commands.map(\.command) == [.reload(snapshot([a])), .append([b])])
        #expect(executor.state == .applying(.append([b]), ChatTranscriptRenderRevision(rawValue: 2)))
        recorder.succeedCurrent()
        #expect(executor.state == .idle)
    }

    @Test func rendererTraceCarriesTypedChatThroughPlanningAndDOMAcknowledgement() {
        let recorder = RenderMutationRecorder()
        let trace = ChatDiagnosticTrace(source: .app)
        let executor = makeExecutor(recorder, diagnosticTrace: trace)

        executor.submit(snapshot([row("a", text: "A")]))
        recorder.succeedCurrent()

        let correlation = ChatDiagnosticCorrelation.Value(rawValue: "chat-executor")
        let events = trace.snapshot(chat: correlation).events
        #expect(events.map(\.stage).contains(.renderPlanning))
        #expect(events.map(\.stage).contains(.domAcknowledgement))
        #expect(events.allSatisfy { $0.payload.correlation.chat == correlation })
    }

    @Test func rendererTraceCoalescesReplacementPlanningAcrossDOMAcknowledgements() {
        let recorder = RenderMutationRecorder()
        let trace = ChatDiagnosticTrace(source: .app)
        let executor = makeExecutor(recorder, diagnosticTrace: trace)
        let original = row("a", text: "A")
        let firstReplacement = row("a", text: "AB")
        let latestReplacement = row("a", text: "ABC")

        executor.submit(snapshot([original]))
        recorder.succeedCurrent()
        executor.submit(snapshot([firstReplacement]))
        recorder.succeedCurrent()
        executor.submit(snapshot([latestReplacement]))
        recorder.succeedCurrent()

        let chat = ChatDiagnosticCorrelation.Value(rawValue: "chat-executor")
        let row = ChatDiagnosticCorrelation.Value(rawValue: original.id.domValue)
        let planning = trace.snapshot(chat: chat).events.filter {
            $0.stage == .renderPlanning && $0.payload.correlation.displayRow == row
        }
        #expect(planning.count == 1)
        #expect(planning[0].outcome == .coalesced)
        #expect(planning[0].payload.correlation.rendererRevision == .init(3))
    }

    @Test func acknowledgementKeepsTheOriginatingChatAfterDesiredChatSwitches() {
        let recorder = RenderMutationRecorder()
        let trace = ChatDiagnosticTrace(source: .app)
        let executor = makeExecutor(recorder, diagnosticTrace: trace)
        let chatA = TranscriptID.chat(ChatID(rawValue: "chat-a"))
        let chatB = TranscriptID.chat(ChatID(rawValue: "chat-b"))

        executor.submit(.init(context: .init(transcriptID: chatA), rows: [row("a", text: "A")]))
        executor.submit(.init(context: .init(transcriptID: chatB), rows: [row("b", text: "B")]))
        recorder.succeedCurrent()

        let acknowledgedA = trace.snapshot(chat: .init(rawValue: "chat-a")).events.filter {
            $0.stage == .domAcknowledgement
        }
        let acknowledgedB = trace.snapshot(chat: .init(rawValue: "chat-b")).events.filter {
            $0.stage == .domAcknowledgement
        }
        #expect(acknowledgedA.count == 1)
        #expect(acknowledgedB.isEmpty)
    }

    @Test func coalescesOnlyPendingReplacementForTheSameRow() {
        let recorder = RenderMutationRecorder()
        let executor = makeExecutor(recorder)
        let original = row("a", text: "A")
        let first = row("a", text: "AB")
        let latest = row("a", text: "ABC")

        executor.submit(snapshot([original]))
        recorder.succeedCurrent()
        executor.submit(snapshot([first]))
        executor.submit(snapshot([latest]))
        #expect(recorder.commands.count == 2)
        recorder.succeedCurrent()
        #expect(recorder.commands.map(\.command) == [
            .reload(snapshot([original])), .replace(first), .replace(latest)
        ])
    }

    @Test func failedPatchSchedulesOneReloadFromTheLatestSnapshot() {
        let recorder = RenderMutationRecorder()
        let anomalies = RenderAnomalyRecorder()
        let executor = makeExecutor(recorder, anomalies: anomalies)
        let original = row("a", text: "A")
        let changed = row("a", text: "AB")
        let latest = row("a", text: "ABC")

        executor.submit(snapshot([original]))
        recorder.succeedCurrent()
        executor.submit(snapshot([changed]))
        executor.submit(snapshot([latest]))
        recorder.finishCurrent(outcome: .missingRow)

        #expect(recorder.commands.map(\.command) == [
            .reload(snapshot([original])), .replace(changed), .reload(snapshot([latest]))
        ])
        #expect(anomalies.items == [.failedAcknowledgement(.missingRow)])
        recorder.finishCurrent(outcome: .timeout)
        #expect(recorder.commands.count == 3)
    }

    @Test func acknowledgementMismatchDoesNotAdvanceStateAndTriggersRecovery() {
        let recorder = RenderMutationRecorder()
        let anomalies = RenderAnomalyRecorder()
        let executor = makeExecutor(recorder, anomalies: anomalies)
        let original = row("a", text: "A")
        let changed = row("a", text: "AB")

        executor.submit(snapshot([original]))
        recorder.succeedCurrent()
        executor.submit(snapshot([changed]))
        recorder.finishCurrent(kind: .append, outcome: .success)

        #expect(anomalies.items == [.invalidAcknowledgement(expected: .replace, received: .append)])
        #expect(recorder.commands.last?.command == .reload(snapshot([changed])))
    }

    @Test func undefinedAndJavaScriptErrorAcknowledgementsDoNotAdvancePatches() {
        for outcome in [
            ChatTranscriptRenderAcknowledgementOutcome.undefined,
            .javaScriptException,
            .error,
            .timeout
        ] {
            let recorder = RenderMutationRecorder()
            let anomalies = RenderAnomalyRecorder()
            let executor = makeExecutor(recorder, anomalies: anomalies)
            let original = row("a", text: "A")
            let changed = row("a", text: "AB")

            executor.submit(snapshot([original]))
            recorder.succeedCurrent()
            executor.submit(snapshot([changed]))
            recorder.finishCurrent(outcome: outcome)

            #expect(anomalies.items == [.failedAcknowledgement(outcome)])
            #expect(recorder.commands.last?.command == .reload(snapshot([changed])))
        }
    }

    private func makeExecutor(
        _ recorder: RenderMutationRecorder,
        anomalies: RenderAnomalyRecorder = .init(),
        diagnosticTrace: ChatDiagnosticTrace = ChatDiagnostics.appTrace
    ) -> ChatTranscriptRenderExecutor {
        ChatTranscriptRenderExecutor(
            mutate: recorder.record,
            reportAnomaly: anomalies.record,
            diagnosticTrace: diagnosticTrace
        )
    }

    private func snapshot(_ rows: [ChatDisplayRow]) -> ChatTranscriptRenderSnapshot {
        .init(context: .init(transcriptID: transcript), rows: rows)
    }

    private func row(_ id: String, text: String) -> ChatDisplayRow {
        .assistantMessage(
            id: ChatMessageID(rawValue: id), turnID: turn, text: text,
            createdAt: .distantPast, contentState: .final
        )
    }
}

@MainActor
private final class RenderMutationRecorder {
    struct Entry {
        let command: ChatTranscriptRenderCommand
        let revision: ChatTranscriptRenderRevision
        let completion: @MainActor (ChatTranscriptRenderAcknowledgement) -> Void
    }

    private(set) var commands: [Entry] = []

    func record(
        command: ChatTranscriptRenderCommand,
        revision: ChatTranscriptRenderRevision,
        completion: @escaping @MainActor (ChatTranscriptRenderAcknowledgement) -> Void
    ) {
        commands.append(Entry(command: command, revision: revision, completion: completion))
    }

    func succeedCurrent() {
        finishCurrent(outcome: .success)
    }

    func finishCurrent(
        kind: ChatTranscriptRenderCommandKind? = nil,
        outcome: ChatTranscriptRenderAcknowledgementOutcome
    ) {
        guard let entry = commands.last else { return }
        entry.completion(.init(
            kind: kind ?? entry.command.kind,
            revision: entry.revision,
            rowID: entry.command.rowID,
            outcome: outcome
        ))
    }
}

@MainActor
private final class RenderAnomalyRecorder {
    private(set) var items: [ChatTranscriptRendererAnomaly] = []
    func record(_ anomaly: ChatTranscriptRendererAnomaly) { items.append(anomaly) }
}
#endif
