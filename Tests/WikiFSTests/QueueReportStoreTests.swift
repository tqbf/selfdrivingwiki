import Foundation
import Testing
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import WikiFSEngine
@testable import WikiFSCore

/// Durable attempt-report store behavior (plan §2): additive v7 migration,
/// attempt isolation, monotonic revisions across same-attempt execution
/// resets, stale attempt/execution rejection, `requeue` non-interference,
/// interrupted projection, cascade pruning, and bounded summaries.
@Suite("QueueReportStore")
struct QueueReportStoreTests {

    // MARK: - Helpers

    private func makeStore() throws -> QueueStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-report-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"))
    }

    private func makeItem(
        _ store: QueueStore,
        sourceIDs: [SourceID] = [SourceID(rawValue: "src-1")]
    ) throws -> QueueItem {
        try store.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: WikiID(rawValue: "wiki-a"),
            payload: QueueItemPayload(sourceIDs: sourceIDs)))
    }

    private func scope(_ sourceIDs: [SourceID]) -> QueueReportScope {
        .targets(sourceIDs.map { QueueReportTargetRecord(target: .source($0), state: .planned) })
    }

    // MARK: Migration + reopen

    @Test("Report persists across store reopen (migration v7)")
    func reportStoreMigrationAndReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-report-reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("queue.sqlite")

        let item = try {
            let store = try QueueStore(databaseURL: url)
            defer { store.close() }
            let item = try makeItem(store)
            _ = try store.beginReport(
                attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
                executionID: QueueExecutionID(rawValue: UUID()),
                operation: .ingest,
                scope: scope([SourceID(rawValue: "s1"), SourceID(rawValue: "s2")]))
            return item
        }()

        // Reopen the same file: the header + rows survive.
        let reopened = try QueueStore(databaseURL: url)
        defer { reopened.close() }
        let loaded = try reopened.loadReport(itemID: item.id)
        guard let loaded else {
            Issue.record("Report missing after reopen")
            return
        }
        #expect(loaded.revision == QueueReportRevision(rawValue: 1))
        #expect(loaded.targets.count == 2)
        #expect(loaded.operation == .ingest)
    }

    // MARK: Durable usage (v8)

    /// Run raw SQL on a closed DB file, bypassing the store — stages states
    /// the store's own API cannot produce (the FTS5DesyncMigrationTests
    /// bypass).
    private func executeRaw(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        let detail = message.map { String(cString: $0) } ?? ""
        if message != nil { sqlite3_free(message) }
        #expect(rc == SQLITE_OK, "raw SQL failed (\(rc)): \(detail)")
    }

    /// Single-cell raw read (the FTS5DesyncMigrationTests bypass).
    private func scalar(_ sql: String, at url: URL) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    /// The usage columns the v8 migration adds.
    private static let usageColumnNames = [
        "input_tokens", "output_tokens", "cached_read_tokens",
        "thought_tokens", "cost", "currency",
    ]

    @Test("Pre-usage report DB migrates on reopen; legacy report decodes nil usage; completion commits durable usage")
    func preUsageReportDatabaseMigratesAndCommitsUsage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-report-preusage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("queue.sqlite")

        let execution = QueueExecutionID(rawValue: UUID())
        let item = try {
            let store = try QueueStore(databaseURL: url)
            defer { store.close() }
            let item = try makeItem(store)
            _ = try store.beginReport(
                attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
                executionID: execution,
                operation: .ingest,
                scope: scope([SourceID(rawValue: "s1")]))
            return item
        }()

        // Rewind the report header to its PRE-USAGE (v7) shape: rebuild the
        // table without the six usage columns and un-track the v8 migration,
        // so the reopen below replays the genuine pre-usage upgrade path.
        try executeRaw("""
        ALTER TABLE queue_attempt_reports RENAME TO queue_attempt_reports_pre_v8;
        CREATE TABLE queue_attempt_reports (
            item_id        TEXT NOT NULL REFERENCES queue_items(id) ON DELETE CASCADE,
            attempt        INTEGER NOT NULL,
            execution_id   TEXT NOT NULL,
            operation      TEXT NOT NULL,
            scope          TEXT NOT NULL,
            phase          TEXT NOT NULL,
            provider_id    TEXT,
            model          TEXT,
            availability   TEXT NOT NULL,
            result_summary TEXT,
            revision       INTEGER NOT NULL,
            updated_at     INTEGER NOT NULL,
            PRIMARY KEY (item_id, attempt)
        ) WITHOUT ROWID;
        INSERT INTO queue_attempt_reports (
            item_id, attempt, execution_id, operation, scope, phase,
            provider_id, model, availability, result_summary, revision, updated_at
        )
            SELECT item_id, attempt, execution_id, operation, scope, phase,
                   provider_id, model, availability, result_summary, revision, updated_at
            FROM queue_attempt_reports_pre_v8;
        DROP TABLE queue_attempt_reports_pre_v8;
        DELETE FROM grdb_migrations WHERE identifier = 'v8_add_attempt_report_usage';
        """, at: url)
        for column in Self.usageColumnNames {
            #expect(scalar(
                """
                SELECT COUNT(*) FROM pragma_table_info('queue_attempt_reports')
                WHERE name = '\(column)'
                """, at: url) == "0",
                "pre-usage DB must lack \(column)")
        }

        // Reopen: v8 runs, the columns are added, and the legacy report —
        // whose usage columns are NULL — decodes `usage == nil` (never
        // zeros).
        let reopened = try QueueStore(databaseURL: url)
        let legacy = try reopened.loadReport(itemID: item.id)
        #expect(legacy?.usage == nil)
        #expect(legacy?.targets.isEmpty == false)

        // The completion mutation commits the launcher's run-total usage.
        let usage = SessionUsage(
            inputTokens: 4_178, outputTokens: 537, totalTokens: 4_715,
            cachedReadTokens: 133_376, cachedWriteTokens: nil,
            thoughtTokens: 395, cost: 0.0421, currency: "USD",
            contextUsed: 0, contextSize: 0, modelId: "claude-sonnet-4-5")
        _ = try reopened.commitReportMutation(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: execution,
            mutation: QueueIngestionReporting.agentCompletionMutation(
                operation: .ingest, usage: usage))
        let expected = QueueReportUsage(
            inputTokens: 4_178, outputTokens: 537,
            cachedReadTokens: 133_376, thoughtTokens: 395,
            cost: 0.0421, currency: "USD")
        #expect(try reopened.loadReport(itemID: item.id)?.usage == expected)
        reopened.close()

        // Reopen again: the committed usage is DURABLE — the fix for token
        // counts vanishing from Run Details after completion/reload.
        let final = try QueueStore(databaseURL: url)
        defer { final.close() }
        #expect(try final.loadReport(itemID: item.id)?.usage == expected)
    }

    @Test("Usage survives non-usage mutations; a new execution resets it")
    func usageCommitSemantics() throws {
        let store = try makeStore()
        defer { store.close() }
        let item = try makeItem(store)
        let attemptID = QueueAttemptID(itemID: item.id, attempt: 0)
        let execution = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: attemptID,
            executionID: execution,
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))

        let usage = QueueReportUsage(
            inputTokens: 10, outputTokens: 20,
            cachedReadTokens: nil, thoughtTokens: 5,
            cost: 0.001, currency: "USD")
        _ = try store.commitReportMutation(
            attemptID: attemptID,
            executionID: execution,
            mutation: QueueReportMutation(usage: usage))
        #expect(try store.loadReport(itemID: item.id)?.usage == usage)

        // A non-usage mutation (mid-run phase + target upsert) must NOT
        // clobber the committed usage — the COALESCE write preserves it.
        _ = try store.commitReportMutation(
            attemptID: attemptID,
            executionID: execution,
            mutation: QueueReportMutation(
                phase: .running,
                targetUpserts: [QueueReportTargetRecord(
                    target: .source(SourceID(rawValue: "src-1")),
                    state: .submitted)]))
        #expect(try store.loadReport(itemID: item.id)?.usage == usage)

        // A new execution on the SAME attempt resets the header: the dead
        // dispatch's usage goes NULL with the rest of its progress.
        let secondExecution = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: attemptID,
            executionID: secondExecution,
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))
        #expect(try store.loadReport(itemID: item.id)?.usage == nil)
    }

    // MARK: Attempt isolation

    @Test("Retry preserves the previous attempt's report; current attempt has none")
    func retryPreservesPreviousAttemptReport() throws {
        let store = try makeStore()
        let item = try makeItem(store)
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: QueueExecutionID(rawValue: UUID()),
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))

        // A retry is valid only from a terminal state; cancel first.
        try store.markCancelled(id: item.id)
        try store.retryItem(id: item.id)

        // Current attempt has no report yet — old jobs / fresh retries are
        // "not reported", never zero.
        #expect(try store.loadReport(itemID: item.id) == nil)

        // A new report for attempt 1 begins fresh at revision 1...
        let attempt1 = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 1),
            executionID: QueueExecutionID(rawValue: UUID()),
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))
        #expect(attempt1.revision == QueueReportRevision(rawValue: 1))

        // ...and the previous attempt's rows are preserved (attempt isolation).
        let legacy = try store.loadReportSummaries(itemIDs: [item.id])
        #expect(legacy[item.id]?.attempt == 1)
    }

    // MARK: Monotonic revisions + execution resets

    @Test("New execution on the SAME attempt resets progress and advances the revision")
    func sameAttemptExecutionResetAdvancesRevision() throws {
        let store = try makeStore()
        let item = try makeItem(store, sourceIDs: [SourceID(rawValue: "s1")])
        let firstExecution = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: firstExecution,
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))

        try store.markRunning(id: item.id, providerID: ProviderID(rawValue: "p"))
        _ = try store.commitReportMutation(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: firstExecution,
            mutation: QueueReportMutation(
                phase: .running,
                targetUpserts: [QueueReportTargetRecord(
                    target: .source(SourceID(rawValue: "s1")),
                    state: .submitted)]))

        // Halt-resume style redispatch: a new lease (execution) activates.
        let secondExecution = QueueExecutionID(rawValue: UUID())
        let reset = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: secondExecution,
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))

        #expect(reset.revision.rawValue > 1)
        #expect(reset.executionID == secondExecution)
        #expect(reset.phase == .planned)
        #expect(reset.targets.first?.state == .planned)
        #expect(reset.provider == nil)
        #expect(reset.resultSummary == nil)
    }

    @Test("Old-execution mutation is rejected with staleExecution")
    func staleExecutionRejected() throws {
        let store = try makeStore()
        let item = try makeItem(store)
        let first = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: first,
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))

        let second = QueueExecutionID(rawValue: UUID())
        _ = try store.activateReportExecution(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: second)

        do {
            _ = try store.commitReportMutation(
                attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
                executionID: first,
                mutation: QueueReportMutation(resultSummary: "late old-lease write"))
            Issue.record("Expected a staleExecution rejection")
        } catch let error as QueueReportStoreError {
            guard case .staleExecution(let attemptID, let expected, let current) = error else {
                Issue.record("Unexpected QueueReportStoreError: \(error)")
                return
            }
            #expect(attemptID == QueueAttemptID(itemID: item.id, attempt: 0))
            #expect(expected == first)
            #expect(current == second)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        // Same-execution writes still succeed after the rejection.
        let committed = try store.commitReportMutation(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: second,
            mutation: QueueReportMutation(resultSummary: "current write"))
        #expect(committed.resultSummary == "current write")
    }

    @Test("Mutation from an earlier attempt is rejected with staleAttempt")
    func staleAttemptRejected() throws {
        let store = try makeStore()
        let item = try makeItem(store)
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: QueueExecutionID(rawValue: UUID()),
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))

        // A retry is valid only from a terminal state; cancel first.
        try store.markCancelled(id: item.id)
        try store.retryItem(id: item.id)

        do {
            _ = try store.commitReportMutation(
                attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
                executionID: QueueExecutionID(rawValue: UUID()),
                mutation: QueueReportMutation())
            Issue.record("Expected a staleAttempt rejection")
        } catch let error as QueueStoreError {
            guard case .staleAttempt(let rejected, let currentAttempt) = error else {
                Issue.record("Unexpected QueueStoreError: \(error)")
                return
            }
            #expect(rejected == QueueAttemptID(itemID: item.id, attempt: 0))
            #expect(currentAttempt == 1)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("requeue(id:) never touches the report (halt keeps observed outcomes)")
    func requeueDoesNotTouchReports() throws {
        let store = try makeStore()
        let item = try makeItem(store)
        let execution = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: execution,
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))
        try store.markRunning(id: item.id, providerID: ProviderID(rawValue: "p"))
        let before = try store.commitReportMutation(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: execution,
            mutation: QueueReportMutation(
                targetUpserts: [QueueReportTargetRecord(
                    target: .source(item.payload.sourceIDs[0]),
                    state: .submitted)]))

        try store.requeue(id: item.id)

        let after = try store.loadReport(itemID: item.id)
        #expect(after == before)
    }

    // MARK: Interrupted projection

    @Test("projectInterruptedReport keeps observed outcomes and interrupts unfinished targets")
    func projectInterruptedKeepsObservedOutcomes() throws {
        let store = try makeStore()
        let item = try makeItem(store, sourceIDs: [SourceID(rawValue: "s1"), SourceID(rawValue: "s2")])
        let execution = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: execution,
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))
        let before = try store.commitReportMutation(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: execution,
            mutation: QueueReportMutation(
                targetUpserts: [
                    QueueReportTargetRecord(
                        target: .source(SourceID(rawValue: "s1")),
                        displayName: "Kept",
                        state: .succeeded),
                ]))

        let projected = try store.projectInterruptedReport(itemID: item.id)
        guard let projected else {
            Issue.record("Expected a projected report")
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: projected.targets.map { ($0.target.id, $0) })
        #expect(byID["s1"]?.state == .succeeded)
        #expect(byID["s2"]?.state == .interrupted)
        #expect(projected.phase == .finished)
        #expect(projected.revision.rawValue > before.revision.rawValue)

        // Idempotent: re-projection does not move the revision again.
        let again = try store.projectInterruptedReport(itemID: item.id)
        #expect(again?.revision == projected.revision)
    }

    // MARK: Committed read consistency

    @Test("commitReportMutation returns the committed report read in the same transaction")
    func commitReturnsConsistentReport() throws {
        let store = try makeStore()
        let item = try makeItem(store)
        let execution = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: execution,
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))

        let committed = try store.commitReportMutation(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: execution,
            mutation: QueueReportMutation(
                phase: .staging,
                provider: ProviderID(rawValue: "claude-acp"),
                targetUpserts: [QueueReportTargetRecord(
                    target: .source(item.payload.sourceIDs[0]),
                    displayName: "Staged name",
                    state: .submitted)]))

        #expect(committed.phase == .staging)
        #expect(committed.provider == ProviderID(rawValue: "claude-acp"))
        #expect(committed.targets.first?.displayName == "Staged name")
        #expect(committed.targets.first?.state == .submitted)
        // Re-reading agrees with the committed value.
        #expect(try store.loadReport(itemID: item.id) == committed)
    }

    // MARK: Cascade pruning

    @Test("Pruning a terminal item removes its report (FK cascade)")
    func pruneHistoryCascadesReports() throws {
        let store = try makeStore()
        let item = try makeItem(store)
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: QueueExecutionID(rawValue: UUID()),
            operation: .ingest,
            scope: scope(item.payload.sourceIDs))

        try store.markRunning(id: item.id, providerID: ProviderID(rawValue: "p"))
        try store.markCompleted(id: item.id)
        try store.pruneHistory(maxPerQueue: 0)

        #expect(try store.loadReport(itemID: item.id) == nil)
        #expect(try store.loadReportSummaries(itemIDs: [item.id]).isEmpty)
    }

    // MARK: Summaries

    @Test("Summaries derive counts from target rows and fold bounded search text")
    func summariesDeriveCountsAndSearchText() throws {
        let store = try makeStore()
        let itemA = try makeItem(store, sourceIDs: [SourceID(rawValue: "alpha"), SourceID(rawValue: "beta")])
        let executionA = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: itemA.id, attempt: 0),
            executionID: executionA,
            operation: .ingest,
            scope: scope(itemA.payload.sourceIDs))
        _ = try store.commitReportMutation(
            attemptID: QueueAttemptID(itemID: itemA.id, attempt: 0),
            executionID: executionA,
            mutation: QueueReportMutation(
                phase: .staging,
                availability: .available,
                resultSummary: "8 of 12 submitted",
                targetUpserts: [
                    QueueReportTargetRecord(
                        target: .source(SourceID(rawValue: "alpha")),
                        displayName: "Alpha Paper",
                        state: .submitted),
                    QueueReportTargetRecord(
                        target: .source(SourceID(rawValue: "beta")),
                        state: .skipped(reason: "Source bytes unavailable")),
                ]))

        // An item with NO report is absent — not zero-counted.
        let itemB = try makeItem(store, sourceIDs: [SourceID(rawValue: "gamma")])

        let summaries = try store.loadReportSummaries(itemIDs: [itemA.id, itemB.id])
        #expect(summaries[itemB.id] == nil)

        guard let summary = summaries[itemA.id] else {
            Issue.record("Summary missing for reported item")
            return
        }
        #expect(summary.phaseCounts[.submitted] == 1)
        #expect(summary.phaseCounts[.skipped] == 1)
        #expect(summary.phaseCounts[.succeeded] == nil)  // unknown is absent, never zero
        #expect(summary.searchText.contains("Alpha Paper"))
        #expect(summary.searchText.contains("Source bytes unavailable"))
        #expect(summary.searchText.contains("8 of 12 submitted"))
        #expect(summary.availability == .available)
    }

    @Test("Summary search text is bounded for large batches")
    func summarySearchTextIsBounded() throws {
        let store = try makeStore()
        let sources = (0..<500).map { SourceID(rawValue: "bulk-\($0)") }
        let item = try makeItem(store, sourceIDs: sources)
        let execution = QueueExecutionID(rawValue: UUID())
        let namedScope = QueueReportScope.targets(sources.enumerated().map { index, sourceID in
            QueueReportTargetRecord(
                target: .source(sourceID),
                displayName: "Bulk Document \(index)",
                state: .planned)
        })
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: 0),
            executionID: execution,
            operation: .ingest,
            scope: namedScope)

        let summaries = try store.loadReportSummaries(itemIDs: [item.id])
        guard let summary = summaries[item.id] else {
            Issue.record("Summary missing")
            return
        }
        #expect(summary.searchText.count <= QueueReportSummaryLimits.maxTotalLength)
        // The tail is folded off: the LAST target's name is not guaranteed to
        // be present, but the first window is.
        #expect(summary.searchText.contains("Bulk Document 0"))
        #expect(summary.searchText.count < String(repeating: "x", count: 8000).count + 1)
    }

    @Test("Search target limit applies per item, not as one shared global LIMIT")
    func searchTargetLimitIsPerItem() throws {
        // Two reported items requested in one batch. The first item's ULID
        // sorts before the second's (ULIDs are time-ordered), so under the old
        // global `LIMIT itemIDs.count * maxSearchTargets` every search row in
        // the budget belonged to the large early item and the late item got
        // none. The bound is per item: each item keeps its own first window.
        let store = try makeStore()

        let hugeSources = (0..<200).map { SourceID(rawValue: "huge-\($0)") }
        let hugeItem = try makeItem(store, sourceIDs: hugeSources)
        let hugeExecution = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: hugeItem.id, attempt: 0),
            executionID: hugeExecution,
            operation: .ingest,
            scope: QueueReportScope.targets(hugeSources.enumerated().map { index, sourceID in
                QueueReportTargetRecord(
                    target: .source(sourceID),
                    displayName: "Huge Document \(index)",
                    state: .planned)
            }))

        // Enqueued after the huge item, so it sorts after it by item_id.
        let lateSources = [SourceID(rawValue: "late-a"), SourceID(rawValue: "late-b")]
        let lateItem = try makeItem(store, sourceIDs: lateSources)
        let lateExecution = QueueExecutionID(rawValue: UUID())
        _ = try store.beginReport(
            attemptID: QueueAttemptID(itemID: lateItem.id, attempt: 0),
            executionID: lateExecution,
            operation: .ingest,
            scope: QueueReportScope.targets([
                QueueReportTargetRecord(
                    target: .source(lateSources[0]),
                    displayName: "Late Alpha",
                    state: .planned),
                QueueReportTargetRecord(
                    target: .source(lateSources[1]),
                    displayName: "Late Beta",
                    state: .planned),
            ]))

        let summaries = try store.loadReportSummaries(itemIDs: [hugeItem.id, lateItem.id])

        guard let lateSummary = summaries[lateItem.id] else {
            Issue.record("Late item's summary missing — it was starved by the early item")
            return
        }
        #expect(lateSummary.searchText.contains("Late Alpha"))
        #expect(lateSummary.searchText.contains("Late Beta"))

        // The huge item is still bounded to its own per-item window.
        guard let hugeSummary = summaries[hugeItem.id] else {
            Issue.record("Huge item's summary missing")
            return
        }
        #expect(hugeSummary.searchText.contains("Huge Document 0"))
        #expect(!hugeSummary.searchText.contains("Huge Document \(QueueReportSummaryLimits.maxSearchTargets)"))
    }
}
