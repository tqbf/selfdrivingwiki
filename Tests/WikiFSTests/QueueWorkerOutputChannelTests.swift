#if canImport(WikiFSEngine)
import Foundation
import Synchronization
import Testing
@testable import WikiFSEngine
import WikiFSCore

@Suite("Queue worker output channel", .serialized, .timeLimit(.minutes(1)))
struct QueueWorkerOutputChannelTests {
    @Test("progress publishes before persistence and survives persistence failure")
    func progressPublishesBeforePersistence() async throws {
        let order = LockedLog<String>()
        let channel = makeChannel(
            order: order,
            appendProgress: { _, _ in
                order.append("persist")
                throw TestFailure.expected
            })
        let itemID = QueueItem.ID(rawValue: "progress-item")
        let event = await subscribeOne(to: channel)

        channel.emitProgress(itemID: itemID, line: "line")

        #expect(order.values == ["publish:progress", "persist"])
        guard case .progress(let receivedID, let line) = try await event.value else {
            Issue.record("Expected progress event")
            return
        }
        #expect(receivedID == itemID)
        #expect(line == "line")
    }

    @Test("transcript persists before publication")
    func transcriptPersistsBeforePublication() async throws {
        let order = LockedLog<String>()
        let channel = makeChannel(
            order: order,
            persistTranscript: { _ in order.append("persist") })
        let attempt = QueueAttemptID(
            itemID: QueueItem.ID(rawValue: "transcript-item"),
            attempt: 0)
        let event = await subscribeOne(to: channel)
        channel.beginTranscript(attempt)

        channel.emitTranscript(attemptID: attempt, event: .assistantText("hello"))

        #expect(order.values == ["persist", "publish:transcript"])
        guard case .transcript(let update) = try await event.value else {
            Issue.record("Expected transcript event")
            return
        }
        #expect(update.attemptID == attempt)
        #expect(update.batchNumber == 0)
        channel.finishTranscript(attempt)
    }

    @Test("failed transcript persistence prevents publication")
    func failedTranscriptPersistencePreventsPublication() async throws {
        let order = LockedLog<String>()
        let channel = makeChannel(
            order: order,
            persistTranscript: { _ in
                order.append("persist")
                throw TestFailure.expected
            })
        let attempt = QueueAttemptID(
            itemID: QueueItem.ID(rawValue: "failed-transcript-item"),
            attempt: 0)
        channel.beginTranscript(attempt)

        channel.emitTranscript(attemptID: attempt, event: .assistantText("not durable"))

        #expect(order.values == ["persist"])
        channel.finishTranscript(attempt)
    }

    @Test("final usage publishes before persistence")
    func finalUsagePublishesBeforePersistence() async throws {
        let order = LockedLog<String>()
        let channel = makeChannel(
            order: order,
            persistUsage: { _, json in
                #expect(json != nil)
                order.append("persist")
            })
        let usage = makeUsage()
        let itemID = QueueItem.ID(rawValue: "usage-item")
        let event = await subscribeOne(to: channel)

        channel.emitUsage(itemID: itemID, usage: usage)

        #expect(order.values == ["publish:usage", "persist"])
        guard case .usage(let receivedID, let receivedUsage) = try await event.value else {
            Issue.record("Expected usage event")
            return
        }
        #expect(receivedID == itemID)
        #expect(receivedUsage == usage)
    }

    @Test("run paths publish before persistence")
    func runPathsPublishBeforePersistence() async throws {
        let order = LockedLog<String>()
        let channel = makeChannel(
            order: order,
            persistRunPaths: { _, logURL, debugURL in
                #expect(logURL == "file:///run.jsonl")
                #expect(debugURL == "file:///debug/")
                order.append("persist")
            })
        let itemID = QueueItem.ID(rawValue: "paths-item")
        let logURL = URL(string: "file:///run.jsonl")
        let debugURL = URL(string: "file:///debug/")
        let event = await subscribeOne(to: channel)

        channel.emitRunPaths(itemID: itemID, logURL: logURL, debugURL: debugURL)

        #expect(order.values == ["publish:runPaths", "persist"])
        guard case .runPaths(let receivedID, let receivedLog, let receivedDebug) = try await event.value else {
            Issue.record("Expected run-path event")
            return
        }
        #expect(receivedID == itemID)
        #expect(receivedLog == logURL)
        #expect(receivedDebug == debugURL)
    }

    @Test("live usage and pending permission are runtime-only")
    func runtimeOnlyOutputsDoNotPersist() async throws {
        let order = LockedLog<String>()
        let channel = makeChannel(order: order)
        let itemID = QueueItem.ID(rawValue: "runtime-item")
        let first = await subscribeOne(to: channel)
        channel.emitLiveUsage(itemID: itemID, usage: makeUsage())
        _ = try await first.value

        let second = await subscribeOne(to: channel)
        channel.emitPendingPermission(itemID: itemID, permission: nil)
        _ = try await second.value

        #expect(order.values == ["publish:liveUsage", "publish:pendingPermission"])
    }

    @Test("multiple ready subscribers receive the same event and finish")
    func multicastSubscribersReceiveAndFinish() async throws {
        let channel = makeChannel(order: LockedLog<String>())
        let firstReady = AsyncStream<Void>.makeStream()
        let secondReady = AsyncStream<Void>.makeStream()
        let firstStream = channel.events {
            firstReady.continuation.yield(())
            firstReady.continuation.finish()
        }
        let secondStream = channel.events {
            secondReady.continuation.yield(())
            secondReady.continuation.finish()
        }
        let first = Task { await collect(firstStream) }
        let second = Task { await collect(secondStream) }
        _ = try await firstValue(from: firstReady.stream)
        _ = try await firstValue(from: secondReady.stream)
        let itemID = QueueItem.ID(rawValue: "multicast-item")

        channel.emitProgress(itemID: itemID, line: "shared")
        channel.finish()

        #expect(await first.value.count == 1)
        #expect(await second.value.count == 1)
    }

    @Test("stale scope invalidation cannot revoke replacement dispatch")
    func staleScopeInvalidationCannotRevokeReplacementDispatch() async throws {
        let order = LockedLog<String>()
        let channel = makeChannel(
            order: order,
            appendProgress: { _, _ in order.append("persist") })
        let attempt = QueueAttemptID(
            itemID: QueueItem.ID(rawValue: "replacement-item"),
            attempt: 0)
        let staleScope = channel.makeScope(attemptID: attempt)
        let replacementScope = channel.makeScope(attemptID: attempt)
        let event = await subscribeOne(to: channel)

        let staleDrain = channel.invalidate(staleScope)
        for await _ in staleDrain {}
        replacementScope.emitProgress(
            itemID: attempt.itemID,
            line: "replacement remains active")

        guard case .progress(let itemID, let line) = try await event.value else {
            Issue.record("Expected replacement progress event")
            return
        }
        #expect(itemID == attempt.itemID)
        #expect(line == "replacement remains active")
        #expect(order.values == ["publish:progress", "persist"])

        let transcriptEvent = await subscribeOne(to: channel)
        replacementScope.emitTranscript(.assistantText("replacement transcript"))
        guard case .transcript(let update) = try await transcriptEvent.value else {
            Issue.record("Expected replacement transcript event")
            return
        }
        #expect(update.attemptID == attempt)
        #expect(update.batchNumber == 0)
    }

    @Test("closing scope admission rejects scopes created after shutdown starts")
    func lateScopeAfterClosureIsInert() async throws {
        let order = LockedLog<String>()
        let channel = makeChannel(order: order)
        let ready = AsyncStream<Void>.makeStream()
        let stream = channel.events {
            ready.continuation.yield(())
            ready.continuation.finish()
        }
        let events = Task { await collect(stream) }
        _ = try await firstValue(from: ready.stream)

        let drains = channel.invalidateAllScopes()
        let attempt = QueueAttemptID(
            itemID: QueueItem.ID(rawValue: "late-scope-item"),
            attempt: 0)
        let lateScope = channel.makeScope(attemptID: attempt)
        lateScope.emitProgress(itemID: attempt.itemID, line: "must not publish")
        for drain in drains {
            for await _ in drain {}
        }
        channel.finish()

        #expect(await events.value.isEmpty)
        #expect(order.values.isEmpty)
    }

    private func makeChannel(
        order: LockedLog<String>,
        appendProgress: @escaping @Sendable (QueueItem.ID, String) throws -> Void = { _, _ in },
        persistTranscript: @escaping @Sendable (QueueTranscriptUpdate) throws -> Void = { _ in },
        persistUsage: @escaping @Sendable (QueueItem.ID, String?) throws -> Void = { _, _ in },
        persistRunPaths: @escaping @Sendable (QueueItem.ID, String?, String?) throws -> Void = { _, _, _ in }
    ) -> QueueWorkerOutputChannel {
        QueueWorkerOutputChannel(
            appendProgress: appendProgress,
            persistTranscript: persistTranscript,
            persistUsage: persistUsage,
            persistRunPaths: persistRunPaths,
            observePublication: { event in order.append("publish:\(event.kindName)") })
    }

    private func subscribeOne(
        to channel: QueueWorkerOutputChannel
    ) async -> Task<QueueEvent, Error> {
        let ready = AsyncStream<Void>.makeStream()
        let stream = channel.events {
            ready.continuation.yield(())
            ready.continuation.finish()
        }
        let task = Task<QueueEvent, Error> {
            try await firstValue(from: stream)
        }
        for await _ in ready.stream { break }
        return task
    }

    private func collect(_ stream: AsyncStream<QueueEvent>) async -> [QueueEvent] {
        var events: [QueueEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func firstValue<Element: Sendable>(
        from stream: AsyncStream<Element>
    ) async throws -> Element {
        for await value in stream { return value }
        throw TestFailure.streamEnded
    }

    private func makeUsage() -> SessionUsage {
        SessionUsage(
            inputTokens: 1,
            outputTokens: 2,
            totalTokens: 3,
            cachedReadTokens: nil,
            thoughtTokens: nil,
            cost: nil,
            currency: nil,
            contextUsed: 3,
            contextSize: 100)
    }
}

private enum TestFailure: Error {
    case expected
    case streamEnded
}

private final class LockedLog<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    var values: [Element] {
        storage.withLock { $0 }
    }

    func append(_ value: Element) {
        storage.withLock { $0.append(value) }
    }
}

private extension QueueEvent {
    var kindName: String {
        switch self {
        case .enqueued: "enqueued"
        case .started: "started"
        case .progress: "progress"
        case .transcript: "transcript"
        case .liveUsage: "liveUsage"
        case .usage: "usage"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .runStateChanged: "runStateChanged"
        case .reordered: "reordered"
        case .runPaths: "runPaths"
        case .pendingPermission: "pendingPermission"
        }
    }
}
#endif
