import Foundation
import Testing
@testable import WikiFSCore

/// Phase 1 persistence tests for the per-wiki strategy document (AC.1):
/// wiki-isolated, migration-safe, CAS-protected, bounded, and
/// revision/event-correct (`plans/wiki-strategies-and-cumulative-ingestion.md`
/// §Phase 1).
///
/// Event assertions use the same lock-guarded-recorder pattern as
/// `StoreEmissionTests`: bus delivery hops to the main actor, so tests await
/// a bounded flush instead of sleeping; "no event" checks flush several times
/// so a queued delivery cannot hide.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WikiStrategyStoreTests {

    /// Creates a uniquely named disposable database under the project scratch directory.
    private func makeFileBackedFixture(prefix: String) throws -> (store: GRDBWikiStore, url: URL) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tmp/wiki-strategy-tests", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("WikiFS.sqlite")
        return (try GRDBWikiStore(databaseURL: url), url)
    }

    private func cleanupFileBackedFixture(_ store: GRDBWikiStore, url: URL) {
        store.close()
        do {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } catch {
            DebugLog.store("Wiki strategy test fixture cleanup failed: \(error)")
        }
    }

    /// Lock-guarded collector for bus events (mirrors StoreEmissionTests).
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []
        func append(_ e: ResourceChangeEvent) { lock.lock(); events.append(e); lock.unlock() }
        var snapshot: [ResourceChangeEvent] { lock.lock(); defer { lock.unlock() }; return events }
        func clear() { lock.lock(); events.removeAll(); lock.unlock() }
    }

    /// Fresh in-memory store + per-wiki bus + recorder.
    private func makeHarness() throws -> (store: GRDBWikiStore, recorder: Recorder) {
        let store = try TestStoreFactory.inMemory()
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "W"))
        store.eventBus = bus
        let recorder = Recorder()
        bus.subscribe(nil) { recorder.append($0) }
        return (store, recorder)
    }

    /// Bounded wait until `recorder` holds `expected` events.
    private func awaitEvents(_ recorder: Recorder, expected: Int, timeoutMs: Int = 800) async throws -> [ResourceChangeEvent] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if recorder.snapshot.count >= expected { return recorder.snapshot }
            await flushBusDeliveries()
            await Task.yield()
        }
        return recorder.snapshot
    }

    /// Flush the main actor repeatedly so a queued (but unwanted) delivery
    /// surfaces. A real emit queues `Task { @MainActor in … }` at save time,
    /// so flushes after the save are sufficient — no fixed delay.
    private func assertNoEventsDelivered(_ recorder: Recorder) async {
        for _ in 0..<3 {
            await flushBusDeliveries()
            await Task.yield()
        }
        #expect(recorder.snapshot.isEmpty)
    }

    // MARK: - AC.1 named tests

    /// A v55 database (no `wiki_strategy` table) migrates to v56 and reads as
    /// Default; a fresh v56 database has the table with no row (fresh-schema
    /// parity) and also reads as Default. Absence is Default — nothing seeds.
    @Test func migrationDefaults() throws {
        // Fresh schema: the table exists, unseeded, reads Default.
        let fresh = try TestStoreFactory.inMemory()
        #expect(fresh.pragmaValue("user_version") == "56")
        #expect(fresh.scalarText(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='wiki_strategy';") == "1")
        #expect(try fresh.getWikiStrategy() == nil)
        #expect(try fresh.wikiStrategyRevision() == nil)

        // A pre-v56 file: rewind to 55 without the table, reopen, migrate.
        let pair = try makeFileBackedFixture(prefix: "strategy-v56")
        defer { cleanupFileBackedFixture(pair.store, url: pair.url) }
        pair.store.close()
        try MetadataSQLiteFixtureSupport.execute("""
        DROP TABLE IF EXISTS wiki_strategy;
        PRAGMA user_version = 55;
        """, at: pair.url)
        let migrated = try GRDBWikiStore(databaseURL: pair.url)
        #expect(migrated.pragmaValue("user_version") == "56")
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='wiki_strategy';") == "1")
        #expect(try migrated.getWikiStrategy() == nil)
        #expect(try migrated.wikiStrategyRevision() == nil)
        migrated.close()
    }

    /// A saved strategy round-trips (name trimmed, instructions verbatim,
    /// revision 1), survives reopen, and never leaks into another wiki's
    /// database file.
    @Test func roundTripAndIsolation() throws {
        let wikiA = try makeFileBackedFixture(prefix: "strategy-a")
        let wikiB = try makeFileBackedFixture(prefix: "strategy-b")
        defer {
            cleanupFileBackedFixture(wikiA.store, url: wikiA.url)
            cleanupFileBackedFixture(wikiB.store, url: wikiB.url)
        }
        let instructions = """
        # Story Analysis

        Describe characters and relationships. Track revelation order
        separately from event chronology.
        """

        let outcome = try wikiA.store.saveWikiStrategy(
            name: "  Story Wiki  ", instructions: instructions, expectedRevision: nil)
        guard case let .saved(revision, saved) = outcome else {
            Issue.record("expected .saved, got \(outcome)")
            return
        }
        #expect(revision == WikiStrategyRevision(rawValue: 1))
        #expect(saved?.name == "Story Wiki")
        #expect(saved?.instructions == instructions)

        // In-memory read-back is a copied value equal to the save's payload.
        let readBack = try wikiA.store.getWikiStrategy()
        #expect(readBack == saved)
        #expect(try wikiA.store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 1))

        // Persists across reopen.
        wikiA.store.close()
        let reopened = try GRDBWikiStore(databaseURL: wikiA.url)
        #expect(try reopened.getWikiStrategy() == saved)
        reopened.close()

        // Per-wiki isolation: wiki B's own database knows nothing of wiki A.
        #expect(try wikiB.store.getWikiStrategy() == nil)
        #expect(try wikiB.store.wikiStrategyRevision() == nil)
    }

    /// The save compares the editor's expected revision — including absence —
    /// in the same transaction as the write. A stale expectation throws
    /// `WikiStrategyConflictError` carrying the committed winner and leaves
    /// no trace; the matching expectation then succeeds.
    @Test func staleSaveRejected() throws {
        let (store, _) = try makeHarness()

        // Expecting a revision on a never-written wiki conflicts.
        #expect(throws: WikiStrategyConflictError(
            expectedRevision: WikiStrategyRevision(rawValue: 1),
            currentRevision: nil,
            currentStrategy: nil
        )) {
            try store.saveWikiStrategy(
                name: "A", instructions: "first", expectedRevision: WikiStrategyRevision(rawValue: 1))
        }

        // First save from true absence.
        let first = try store.saveWikiStrategy(
            name: "A", instructions: "first", expectedRevision: nil)
        #expect(first == .saved(
            revision: WikiStrategyRevision(rawValue: 1),
            strategy: WikiStrategy(name: "A", instructions: "first",
                                   revision: WikiStrategyRevision(rawValue: 1),
                                   updatedAt: try store.getWikiStrategy()!.updatedAt)))

        // A second editor still believing in absence must not overwrite.
        do {
            _ = try store.saveWikiStrategy(
                name: "B", instructions: "hijack", expectedRevision: nil)
            Issue.record("stale absence save unexpectedly succeeded")
        } catch let error as WikiStrategyConflictError {
            #expect(error.expectedRevision == nil)
            #expect(error.currentRevision == WikiStrategyRevision(rawValue: 1))
            #expect(error.currentStrategy?.name == "A")
            #expect(error.currentStrategy?.instructions == "first")
        }
        // The conflict left no trace.
        #expect(try store.getWikiStrategy()?.instructions == "first")
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 1))

        // The up-to-date editor's save succeeds on top of revision 1.
        let second = try store.saveWikiStrategy(
            name: "A2", instructions: "second", expectedRevision: WikiStrategyRevision(rawValue: 1))
        #expect(second == .saved(revision: WikiStrategyRevision(rawValue: 2), strategy: try store.getWikiStrategy()))
    }

    /// A whitespace-only save resets to Default, retains a tombstone so the
    /// revision stays monotonic, and a repeat reset of an already-Default
    /// wiki is a no-op. Reading a tombstone wiki is indistinguishable from a
    /// never-written wiki for the strategy value, but not for the revision.
    @Test func resetKeepsRevision() throws {
        let (store, _) = try makeHarness()
        _ = try store.saveWikiStrategy(
            name: "A", instructions: "custom", expectedRevision: nil)

        let reset = try store.saveWikiStrategy(
            name: "A", instructions: "   \n\t ", expectedRevision: WikiStrategyRevision(rawValue: 1))
        #expect(reset == .saved(revision: WikiStrategyRevision(rawValue: 2), strategy: nil))
        #expect(try store.getWikiStrategy() == nil)
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 2))

        // Resetting an already-Default wiki changes nothing.
        let repeatReset = try store.saveWikiStrategy(
            name: "", instructions: "\t", expectedRevision: WikiStrategyRevision(rawValue: 2))
        #expect(repeatReset == .unchanged)
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 2))

        // The counter never rewinds: the next save continues from the tombstone.
        let afterReset = try store.saveWikiStrategy(
            name: "B", instructions: "next", expectedRevision: WikiStrategyRevision(rawValue: 2))
        #expect(afterReset == .saved(revision: WikiStrategyRevision(rawValue: 3), strategy: try store.getWikiStrategy()))
    }

    /// A changed save emits exactly one `.strategy` event with the
    /// transition's change kind; an unchanged save emits nothing and does not
    /// advance the revision.
    @Test func unchangedSaveDoesNotEmit() async throws {
        let (store, recorder) = try makeHarness()

        // Default → custom: one .created.
        _ = try store.saveWikiStrategy(name: "A", instructions: "first", expectedRevision: nil)
        var events = try await awaitEvents(recorder, expected: 1)
        #expect(events.count == 1)
        #expect(events[0].kind == .strategy)
        #expect(events[0].id == "wiki_strategy")
        #expect(events[0].change == .created)
        recorder.clear()

        // Same normalized content, same expectation: no event, no write.
        let unchanged = try store.saveWikiStrategy(
            name: " A ", instructions: "first", expectedRevision: WikiStrategyRevision(rawValue: 1))
        #expect(unchanged == .unchanged)
        await assertNoEventsDelivered(recorder)
        #expect(try store.wikiStrategyRevision() == WikiStrategyRevision(rawValue: 1))

        // Changed content: one .updated, revision advances.
        _ = try store.saveWikiStrategy(
            name: "A", instructions: "second", expectedRevision: WikiStrategyRevision(rawValue: 1))
        events = try await awaitEvents(recorder, expected: 1)
        #expect(events.count == 1)
        #expect(events[0].change == .updated)
        recorder.clear()

        // Reset to Default: one .deleted.
        _ = try store.saveWikiStrategy(
            name: "A", instructions: " ", expectedRevision: WikiStrategyRevision(rawValue: 2))
        events = try await awaitEvents(recorder, expected: 1)
        #expect(events.count == 1)
        #expect(events[0].change == .deleted)
    }

    /// `getWikiStrategyState()` returns the body and the revision from one
    /// committed row, and its `saveExpectation` is the exact CAS token for
    /// each Default/tombstone/live shape — the read an editor must load
    /// instead of pairing two separate reads (which can straddle a write).
    @Test func combinedStateReadDrivesExpectation() throws {
        let (store, _) = try makeHarness()

        // Never written: absence, expectation nil.
        var state = try store.getWikiStrategyState()
        #expect(state == WikiStrategyState(strategy: nil, revision: nil))
        #expect(state.saveExpectation == nil)

        // Live strategy: revision equals the strategy's own revision.
        _ = try store.saveWikiStrategy(
            name: "A", instructions: "one", expectedRevision: state.saveExpectation)
        state = try store.getWikiStrategyState()
        #expect(state.strategy?.instructions == "one")
        #expect(state.revision == WikiStrategyRevision(rawValue: 1))
        #expect(state.saveExpectation == state.strategy?.revision)

        // Tombstone Default: nil body, retained revision — the expectation is
        // the tombstone revision, NOT nil.
        _ = try store.saveWikiStrategy(
            name: "A", instructions: " ", expectedRevision: state.saveExpectation)
        state = try store.getWikiStrategyState()
        #expect(state.strategy == nil)
        #expect(state.revision == WikiStrategyRevision(rawValue: 2))
        #expect(state.saveExpectation == WikiStrategyRevision(rawValue: 2))

        // The derived expectation carries the next save through the tombstone.
        let outcome = try store.saveWikiStrategy(
            name: "B", instructions: "two", expectedRevision: state.saveExpectation)
        #expect(outcome == .saved(revision: WikiStrategyRevision(rawValue: 3), strategy: try store.getWikiStrategy()))
    }

    /// Oversized names and instructions are rejected at the write boundary
    /// with a visible error — never truncated — and leave no state and no
    /// event. Inputs at the exact limits are accepted.
    @Test func invalidTextRejected() async throws {
        let (store, recorder) = try makeHarness()

        let longName = String(repeating: "n", count: WikiStrategy.nameCharacterLimit + 1)
        #expect(throws: WikiStrategyTextError.nameTooLong(
            characterCount: WikiStrategy.nameCharacterLimit + 1,
            limit: WikiStrategy.nameCharacterLimit
        )) {
            try store.saveWikiStrategy(name: longName, instructions: "ok", expectedRevision: nil)
        }

        // 32 KiB + 1 byte of ASCII — one byte over the limit.
        let oversized = String(
            repeating: "a",
            count: WikiStrategy.instructionsUTF8ByteLimit) + "!"
        #expect(oversized.utf8.count == WikiStrategy.instructionsUTF8ByteLimit + 1)
        #expect(throws: WikiStrategyTextError.instructionsTooLarge(
            byteCount: WikiStrategy.instructionsUTF8ByteLimit + 1,
            limit: WikiStrategy.instructionsUTF8ByteLimit
        )) {
            try store.saveWikiStrategy(name: "ok", instructions: oversized, expectedRevision: nil)
        }

        await assertNoEventsDelivered(recorder)
        #expect(try store.getWikiStrategy() == nil)
        #expect(try store.wikiStrategyRevision() == nil)

        // Boundary values are accepted: a name at exactly the limit (counted
        // after trimming) and instructions at exactly 32 KiB.
        let boundaryName = String(repeating: "n", count: WikiStrategy.nameCharacterLimit - 2) + "  "
        let boundaryInstructions = String(
            repeating: "b", count: WikiStrategy.instructionsUTF8ByteLimit)
        let outcome = try store.saveWikiStrategy(
            name: boundaryName, instructions: boundaryInstructions, expectedRevision: nil)
        guard case let .saved(revision, strategy) = outcome else {
            Issue.record("expected boundary save to succeed, got \(outcome)")
            return
        }
        #expect(revision == WikiStrategyRevision(rawValue: 1))
        #expect(strategy?.name.count == WikiStrategy.nameCharacterLimit - 2)
        #expect(strategy?.instructions.utf8.count == WikiStrategy.instructionsUTF8ByteLimit)
        _ = try await awaitEvents(recorder, expected: 1)
    }
}
