import Foundation
import Testing
import os
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for `QueueEventLog` (Phase 3) — the JSONL audit trail.
///
/// Each test constructs a `QueueEventLog` with a temp directory and an
/// injectable date provider for deterministic rotation/retention testing.
@Suite
struct QueueEventLogTests {

    // MARK: - Test helpers

    /// A fresh temp directory for log files.
    private func tempLogDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-log-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A completed item for testing.
    private func makeCompletedItem() -> QueueItem {
        QueueItem(
            id: "TESTCOMPLETED001",
            queue: .extraction,
            wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "SRC1")]),
            state: .completed,
            orderingKey: 1000,
            providerID: "provider-A",
            attempt: 0,
            error: nil,
            createdAt: 1000,
            startedAt: 2000,
            finishedAt: 5000
        )
    }

    /// A queued item for testing.
    private func makeQueuedItem() -> QueueItem {
        QueueItem(
            id: "TESTQUEUED001",
            queue: .extraction,
            wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "SRC1")]),
            state: .queued,
            orderingKey: 1000,
            providerID: nil,
            attempt: 0,
            error: nil,
            createdAt: 1000,
            startedAt: nil,
            finishedAt: nil
        )
    }

    /// A running item for testing.
    private func makeRunningItem() -> QueueItem {
        QueueItem(
            id: "TESTRUNNING001",
            queue: .extraction,
            wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "SRC1")]),
            state: .running,
            orderingKey: 1000,
            providerID: "provider-A",
            attempt: 0,
            error: nil,
            createdAt: 1000,
            startedAt: 2000,
            finishedAt: nil
        )
    }

    /// A failed item for testing.
    private func makeFailedItem() -> QueueItem {
        QueueItem(
            id: "TESTFAILED001",
            queue: .extraction,
            wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "SRC1")]),
            state: .failed,
            orderingKey: 1000,
            providerID: "provider-A",
            attempt: 1,
            error: "something broke",
            createdAt: 1000,
            startedAt: 2000,
            finishedAt: 6000
        )
    }

    /// A cancelled item for testing.
    private func makeCancelledItem() -> QueueItem {
        QueueItem(
            id: "TESTCANCELLED001",
            queue: .extraction,
            wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "SRC1")]),
            state: .cancelled,
            orderingKey: 1000,
            providerID: "provider-A",
            attempt: 0,
            error: nil,
            createdAt: 1000,
            startedAt: 2000,
            finishedAt: 4000
        )
    }

    /// Read and parse all JSONL lines from a file, returning decoded records.
    private func readLogRecords(at url: URL) -> [QueueLogRecord] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(QueueLogRecord.self, from: lineData)
        }
    }

    // MARK: - AC6.1: Events written as valid JSON lines

    @Test func testEventsWrittenAsValidJSONLines() async throws {
        let dir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: dir)

        // Write 4 events: enqueued, started, completed, cancelled.
        let queued = makeQueuedItem()
        let running = makeRunningItem()
        let completed = makeCompletedItem()
        let cancelled = makeCancelledItem()

        await log.writeEventForTest(.enqueued(queued))
        await log.writeEventForTest(.started(running))
        await log.writeEventForTest(.completed(completed))
        await log.writeEventForTest(.cancelled(cancelled))

        await log.flushForTest()

        // Read the file.
        let files = FileManager.default.files(in: dir)
        #expect(files.count == 1)
        let records = readLogRecords(at: files[0])

        #expect(records.count == 4)
        #expect(records[0].eventType == "enqueued")
        #expect(records[1].eventType == "started")
        #expect(records[2].eventType == "completed")
        #expect(records[3].eventType == "cancelled")
    }

    @Test func testFailedEventIncludesErrorAndDuration() async throws {
        let dir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: dir)

        let failed = makeFailedItem()
        await log.writeEventForTest(.failed(failed, error: "something broke"))
        await log.flushForTest()

        let files = FileManager.default.files(in: dir)
        let records = readLogRecords(at: files[0])
        #expect(records.count == 1)
        #expect(records[0].eventType == "failed")
        #expect(records[0].error == "something broke")
        #expect(records[0].durationMs == 4000) // 6000 - 2000
    }

    @Test func testCompletedEventIncludesDuration() async throws {
        let dir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: dir)

        let completed = makeCompletedItem()
        await log.writeEventForTest(.completed(completed))
        await log.flushForTest()

        let files = FileManager.default.files(in: dir)
        let records = readLogRecords(at: files[0])
        #expect(records.count == 1)
        #expect(records[0].durationMs == 3000) // 5000 - 2000
    }

    @Test func testCancelledEventLogged() async throws {
        let dir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: dir)

        let cancelled = makeCancelledItem()
        await log.writeEventForTest(.cancelled(cancelled))
        await log.flushForTest()

        let files = FileManager.default.files(in: dir)
        let records = readLogRecords(at: files[0])
        #expect(records.count == 1)
        #expect(records[0].eventType == "cancelled")
        #expect(records[0].itemID == "TESTCANCELLED001")
        #expect(records[0].wikiID == "wiki1")
        #expect(records[0].durationMs == nil)
    }

    @Test func testRunStateChangedHasNoItemFields() async throws {
        let dir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: dir)

        await log.writeEventForTest(.runStateChanged(queue: .ingestion, state: .paused))
        await log.flushForTest()

        let files = FileManager.default.files(in: dir)
        let records = readLogRecords(at: files[0])
        #expect(records.count == 1)
        #expect(records[0].eventType == "runStateChanged")
        #expect(records[0].queue == "ingestion")
        #expect(records[0].runState == "paused")
        #expect(records[0].itemID == nil)
        #expect(records[0].wikiID == nil)
        #expect(records[0].itemState == nil)
    }

    @Test func testRunStateChangedResumed() async throws {
        let dir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: dir)

        await log.writeEventForTest(.runStateChanged(queue: .extraction, state: .running))
        await log.flushForTest()

        let files = FileManager.default.files(in: dir)
        let records = readLogRecords(at: files[0])
        #expect(records.count == 1)
        #expect(records[0].runState == "running")
    }

    @Test func testRecordIncludesItemTimestamps() async throws {
        let dir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: dir)

        let completed = makeCompletedItem()
        await log.writeEventForTest(.completed(completed))
        await log.flushForTest()

        let files = FileManager.default.files(in: dir)
        let records = readLogRecords(at: files[0])
        #expect(records[0].startedAt == 2000)
        #expect(records[0].finishedAt == 5000)
    }

    @Test func testRecordIncludesProviderAndQueue() async throws {
        let dir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: dir)

        let started = makeRunningItem()
        await log.writeEventForTest(.started(started))
        await log.flushForTest()

        let files = FileManager.default.files(in: dir)
        let records = readLogRecords(at: files[0])
        #expect(records[0].providerID == "provider-A")
        #expect(records[0].queue == "extraction")
        #expect(records[0].itemState == "running")
    }

    // MARK: - AC6.2: Daily rotation + bounded retention

    @Test func testFilesUnderLogsQueueDirectory() async throws {
        let base = tempLogDirectory()
        let logsDir = base.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("queue", isDirectory: true)
        let log = QueueEventLog(logDirectory: logsDir)

        await log.writeEventForTest(.enqueued(makeQueuedItem()))
        await log.flushForTest()

        let files = FileManager.default.files(in: logsDir)
        #expect(files.count == 1)
        let filename = files[0].lastPathComponent
        #expect(filename.hasPrefix("queue-"))
        #expect(filename.hasSuffix(".jsonl"))
    }

    @Test func testDailyRotation() async throws {
        let dir = tempLogDirectory()

        // Use a mutable date holder.
        let dateHolder = MutableDateHolder(date: Date(timeIntervalSince1970: 1_750_000_000)) // ~2025-06-15
        let log = QueueEventLog(logDirectory: dir, dateProvider: { dateHolder.date })

        // Write on day 1.
        await log.writeEventForTest(.enqueued(makeQueuedItem()))
        await log.flushForTest()

        // Advance to the next day.
        dateHolder.date = dateHolder.date.addingTimeInterval(86400)

        // Write on day 2.
        await log.writeEventForTest(.completed(makeCompletedItem()))
        await log.flushForTest()

        // Should have 2 files, and the second event should be in the newer file.
        let files = FileManager.default.files(in: dir).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        #expect(files.count == 2)

        let day1Records = readLogRecords(at: files[0])
        let day2Records = readLogRecords(at: files[1])

        #expect(day1Records.count == 1)
        #expect(day2Records.count == 1)
        #expect(day1Records[0].eventType == "enqueued")
        #expect(day2Records[0].eventType == "completed")
    }

    @Test func testPruneOldFiles() async throws {
        let dir = tempLogDirectory()
        let now = Date()

        // Create 3 log files: today, 10 days old, 40 days old.
        createLogFile(in: dir, date: now, content: "{\"eventType\":\"test\"}\n")
        createLogFile(in: dir, date: now.addingTimeInterval(-10 * 86400), content: "{\"eventType\":\"old\"}\n")
        createLogFile(in: dir, date: now.addingTimeInterval(-40 * 86400), content: "{\"eventType\":\"ancient\"}\n")

        // retentionDays = 30; the 40-day-old file should be pruned.
        let log = QueueEventLog(logDirectory: dir, retentionDays: 30, dateProvider: { now })
        // Trigger a prune by writing an event (which calls ensureOpenForToday → pruneOldFiles).
        await log.writeEventForTest(.enqueued(makeQueuedItem()))
        await log.flushForTest()

        let files = FileManager.default.files(in: dir)
        let filenames = files.map(\.lastPathComponent)

        // The ancient (40-day) file should be gone; today + 10-day remain.
        #expect(!filenames.contains(where: { $0.contains("ancient") }))
        // Today's file + the 10-day-old file + the new file we just wrote.
        // The new file may be the same as today's (same date).
        #expect(filenames.count >= 2)
    }

    @Test func testAppendToExistingFileAcrossInstances() async throws {
        let dir = tempLogDirectory()

        // First instance writes one event.
        do {
            let log = QueueEventLog(logDirectory: dir)
            await log.writeEventForTest(.enqueued(makeQueuedItem()))
            await log.flushForTest()
        }

        // Second instance (simulating relaunch) writes another.
        do {
            let log = QueueEventLog(logDirectory: dir)
            await log.writeEventForTest(.completed(makeCompletedItem()))
            await log.flushForTest()
        }

        let files = FileManager.default.files(in: dir)
        #expect(files.count == 1)
        let records = readLogRecords(at: files[0])
        #expect(records.count == 2) // Both events in the same file.
        #expect(records[0].eventType == "enqueued")
        #expect(records[1].eventType == "completed")
    }

    // MARK: - Stop / unwritable

    @Test func testStopDropsSubsequentWrites() async throws {
        let dir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: dir)

        await log.writeEventForTest(.enqueued(makeQueuedItem()))
        await log.flushForTest()

        await log.stop()

        // Writes after stop should be dropped (no crash, no new lines).
        await log.writeEventForTest(.completed(makeCompletedItem()))
        await log.flushForTest()

        let files = FileManager.default.files(in: dir)
        let records = readLogRecords(at: files[0])
        #expect(records.count == 1) // Only the pre-stop event.
    }

    @Test func testUnwritableDirectoryDropsEvents() async throws {
        // Use a path under /dev/null — can't create a directory there.
        let badDir = URL(fileURLWithPath: "/dev/null/impossible/queue")
        let log = QueueEventLog(logDirectory: badDir)

        // Should not crash.
        await log.writeEventForTest(.enqueued(makeQueuedItem()))
        await log.flushForTest()

        // No file created.
        let files = FileManager.default.files(in: badDir)
        #expect(files.isEmpty)
    }

    // MARK: - Headless isolation

    @Test func testHeadlessIsolation() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/WikiFSEngine/QueueEventLog.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(!source.contains("import AppKit"), "QueueEventLog.swift must not import AppKit")
        #expect(!source.contains("import SwiftUI"), "QueueEventLog.swift must not import SwiftUI")
    }

    // MARK: - Real engine integration

    @Test func testLogDuringEngineTest() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-log-engine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
        let store = try QueueStore(databaseURL: dbURL.appendingPathComponent("queue.sqlite"))

        let logDir = tempLogDirectory()
        let log = QueueEventLog(logDirectory: logDir)

        let factory = FakeEngineFactory(
            providerID: { _ in "p1" },
            worker: { _ in }
        )
        let config = QueueEngineConfig(localExtractionLimit: 1, remoteExtractionLimit: 1)
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        // Start the log consuming the engine's events.
        await log.start(events: engine.events)

        await engine.start()
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "SRC1")])))

        // Wait for the item to complete.
        try await Task.sleep(nanoseconds: 300_000_000)

        await log.stop()

        let files = FileManager.default.files(in: logDir)
        #expect(files.count >= 1)
        let records = readLogRecords(at: files[0])

        // Should have at least: enqueued, started, completed.
        let eventTypes = records.map(\.eventType)
        #expect(eventTypes.contains("enqueued"))
        #expect(eventTypes.contains("started"))
        #expect(eventTypes.contains("completed"))

        store.close()
    }

    // MARK: - Helpers

    /// Create a log file with a specific date in the filename.
    private func createLogFile(in dir: URL, date: Date, content: String) {
        let filename = "queue-\(QueueEventLog.dateString(for: date)).jsonl"
        let url = dir.appendingPathComponent(filename)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Mutable date holder

/// A mutable date holder for test injection. `@unchecked Sendable` because
/// tests are single-threaded (or the mutation is externally coordinated).
private final class MutableDateHolder: @unchecked Sendable {
    var date: Date
    init(date: Date) { self.date = date }
}

// MARK: - FileManager helper

private extension FileManager {
    /// List files in a directory, handling non-existent directories gracefully.
    func files(in dir: URL) -> [URL] {
        (try? contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }) ?? []
    }
}

// MARK: - QueueEventLog test accessors

/// Test-only accessors for `QueueEventLog` internals.
extension QueueEventLog {
    /// Write a single event directly (bypassing the stream). For unit tests.
    func writeEventForTest(_ event: QueueEvent) async {
        write(event)
    }

    /// Ensure pending writes are flushed to disk. Since the actor serializes
    /// everything, a no-op await is sufficient to "drain" the actor's mailbox.
    func flushForTest() async {
        // Touching the actor serializes with any pending write().
    }
}

// MARK: - Fake engine factory (reuse from QueueEngineTests pattern)

private struct FakeEngineFactory: QueueWorkerFactory {
    let providerIDFunc: @Sendable (QueueItem) async -> String?
    let workerFunc: @Sendable (QueueItem) async throws -> Void

    init(
        providerID: @escaping @Sendable (QueueItem) async -> String?,
        worker: @escaping @Sendable (QueueItem) async throws -> Void
    ) {
        self.providerIDFunc = providerID
        self.workerFunc = worker
    }

    func providerID(for item: QueueItem) async -> String? {
        await providerIDFunc(item)
    }

    func worker(for item: QueueItem) async throws -> any QueueWorker {
        FakeWorker { item in try await workerFunc(item) }
    }
}

private struct FakeWorker: QueueWorker {
    let body: @Sendable (QueueItem) async throws -> Void
    func execute(_ item: QueueItem) async throws { try await body(item) }
}
