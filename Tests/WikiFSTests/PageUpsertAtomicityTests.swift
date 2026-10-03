import Foundation
import SQLite3
import Testing
@testable import WikiFSCore

/// Atomicity guarantees of the composed page upsert
/// (`GRDBWikiStore.upsertPage(id:title:rawBody:expectation:author:provenance:)`,
/// cumulative ingestion plan phase 4 §9). Every test here runs against the
/// REAL GRDB store — never the protocol-extension sequential fallback, which
/// is documented non-atomic.
///
/// Covers:
/// - Exactly ONE `ResourceChangeEvent` per changed commit (`.created` /
///   `.updated`), none on CAS conflict, create-only conflict, or rollback.
/// - `linkFailureRollsBackVersion`: a real SQLite `RAISE(ABORT)` trigger on
///   `page_links` makes the link write fail AFTER the content write, INSIDE
///   the transaction — head, body, provenance, and links stay unchanged, no
///   event, and the same upsert succeeds once the trigger is removed.
/// - `competingUpdatesLeaveHeadLinksConsistent`: TWO GRDB store connections
///   (separate `DatabasePool`s) on ONE disposable WAL database — a committed
///   CAS write on one connection is visible to and conflicts a stale-head
///   write on the other, with exact subscriber event counts; then a
///   concurrent 8-way CAS hammer leaves exactly one winner.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PageUpsertAtomicityTests {

    // MARK: - Fixtures

    private func makeBus(_ name: String) -> (bus: WikiEventBus, recorder: SignalRecorder) {
        let bus = WikiEventBus(wikiID: WikiID(rawValue: name))
        let recorder = SignalRecorder()
        bus.subscribe(nil) { recorder.append($0) }
        return (bus, recorder)
    }

    /// Poll-bounded wait until the recorders have delivered at least
    /// `expected` events in total, then return. Throws on timeout so a
    /// missing delivery is a diagnosed failure, not a hang.
    private func awaitDeliveredTotal(
        _ recorders: [SignalRecorder], expected: Int, timeoutMs: Int = 2000
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while recorders.reduce(0, { $0 + $1.count }) < expected {
            guard Date() < deadline else {
                throw EventBusDeliveryWaitError.timedOut(
                    expectedCount: expected,
                    actualCount: recorders.reduce(0, { $0 + $1.count }),
                    timeoutMs: timeoutMs)
            }
            await flushBusDeliveries()
            await Task.yield()
        }
    }

    /// Flush the async bus deliveries (main-actor hops) a few times so a
    /// zero-assertion cannot race a delivery that is merely in flight.
    private func settleDeliveries() async {
        for _ in 0..<3 { await flushBusDeliveries() }
        await Task.yield()
    }

    /// Execute raw SQL on a separate connection to the store's database
    /// (used to install/remove the `RAISE(ABORT)` trigger — schema-only DDL,
    /// no store seam bypassed for content).
    private func executeRaw(_ sql: String, on databaseURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw WikiStoreError.open("sqlite3_open failed for \(databaseURL.path)")
        }
        defer { sqlite3_close(db) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown sqlite3_exec error"
            sqlite3_free(errorPointer)
            throw WikiStoreError.open("sqlite3_exec failed: \(message)")
        }
    }

    /// A disposable file-backed WAL store under the PROJECT's gitignored
    /// `tmp/` directory — the plan's Test Strategy requires fixtures under
    /// project tmp, not the system temp folder (`TestStoreFactory`'s
    /// `temporaryDirectory` default) and never live App Group wiki data.
    /// The repo root resolves from `#filePath` (this file lives at
    /// `<repo>/Tests/WikiFSTests/`), so it works from any checkout. Each
    /// call creates a fresh uniquely-named directory; nothing is shared.
    private func disposableTmpStore(
        prefix: String
    ) throws -> (store: GRDBWikiStore, url: URL) {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/WikiFSTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // repo root
        let directory = repoRoot
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("WikiFS.sqlite")
        return (try GRDBWikiStore(databaseURL: url), url)
    }

    private func outgoingPageLinks(from store: GRDBWikiStore, pageID: PageID) throws -> [IndexGenerators.LinkRow] {
        try store.listAllLinks().filter { $0.from == pageID.rawValue }
    }

    // MARK: - One event per changed commit

    /// A changed create emits exactly one `.created`; a changed update (by a
    /// distinct author, so amend-coalescing cannot absorb it) emits exactly
    /// one `.updated`. Both carry the page id.
    @Test func changedWriteEmitsExactlyOneEvent() async throws {
        let store = try TestStoreFactory.inMemory()
        let (bus, recorder) = makeBus("upsert-atomicity-events")
        store.eventBus = bus

        let created = try PageUpsert.upsert(
            in: store, id: nil, title: "Evented Page", body: "first body",
            expectation: .unrestricted, author: "user")
        try await awaitDeliveredTotal([recorder], expected: 1)
        #expect(recorder.count == 1)
        #expect(recorder.snapshot[0].kind == .page)
        #expect(recorder.snapshot[0].id == created.id.rawValue)
        #expect(recorder.snapshot[0].change == .created)

        _ = try PageUpsert.upsert(
            in: store, id: nil, title: "Evented Page", body: "second body",
            expectation: .unrestricted, author: "agent:editor-b")
        try await awaitDeliveredTotal([recorder], expected: 2)
        #expect(recorder.count == 2)
        #expect(recorder.snapshot[1].kind == .page)
        #expect(recorder.snapshot[1].id == created.id.rawValue)
        #expect(recorder.snapshot[1].change == .updated)
    }

    // MARK: - Create-only store contract

    /// `.expectedAbsence` creates an absent title and `.created`s; on an
    /// existing title it throws `PageCreateConflictError` carrying the
    /// existing page's head, writes nothing, and emits nothing; with an
    /// explicit id it is rejected as contradictory.
    @Test func createOnlyExpectationStoreContract() async throws {
        let store = try TestStoreFactory.inMemory()
        let (bus, recorder) = makeBus("upsert-atomicity-create-only")
        store.eventBus = bus

        // Absent title → create.
        let created = try PageUpsert.upsert(
            in: store, id: nil, title: "Claimed Title", body: "content",
            expectation: .expectedAbsence, author: "agent:creator")
        #expect(created.didCreate)
        try await awaitDeliveredTotal([recorder], expected: 1)
        #expect(recorder.count == 1)
        #expect(recorder.snapshot[0].change == .created)

        // Same title again → conflict, nothing written, no event.
        let head = try store.pageHeadVersionID(pageID: created.id)
        do {
            _ = try PageUpsert.upsert(
                in: store, id: nil, title: "Claimed Title", body: "intruder",
                expectation: .expectedAbsence, author: "agent:intruder")
            Issue.record("expected PageCreateConflictError")
        } catch let error as PageCreateConflictError {
            #expect(error.pageID == created.id)
            #expect(error.actualVersionID == head)
        }
        #expect(try store.getPage(id: created.id).bodyMarkdown == "content")
        #expect(try store.pageHeadVersionID(pageID: created.id) == head)
        #expect(try store.pageVersionHistory(pageID: created.id).count == 1)
        await settleDeliveries()
        #expect(recorder.count == 1)

        // Explicit id + expectedAbsence is contradictory at the store seam too.
        do {
            _ = try PageUpsert.upsert(
                in: store, id: created.id, title: "Claimed Title", body: "x",
                expectation: .expectedAbsence, author: "agent:misconfigured")
            Issue.record("expected WikiStoreError.unexpected for expectedAbsence + explicit id")
        } catch let error as WikiStoreError {
            guard case .unexpected = error else {
                Issue.record("expected WikiStoreError.unexpected, got \(error)")
                return
            }
        }
    }

    // MARK: - Link failure rolls the version back (real trigger)

    /// A real `RAISE(ABORT, …)` trigger on `page_links` insertion makes the
    /// composed write fail AFTER its content write, inside the transaction.
    /// The savepoint must roll back the version/body/provenance work, emit
    /// NO event, and the same upsert must succeed once the trigger is gone.
    @Test func linkFailureRollsBackVersion() async throws {
        let (store, url) = try disposableTmpStore(prefix: "page-upsert-atomicity-link")
        let (bus, recorder) = makeBus("upsert-atomicity-link-failure")
        store.eventBus = bus

        let target = try store.createPage(title: "Target", createdBy: "user")
        let evidence = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let provenance = [PageVersionSourceInput(sourceID: evidence.id, role: .primary)]
        let linker = try store.createPage(
            title: "Linker", createdBy: "user", provenance: provenance)
        // The target page, source, and linker each emit one setup event.
        try await awaitDeliveredTotal([recorder], expected: 3)
        let baselineEvents = recorder.count
        let headBefore = try store.pageHeadVersionID(pageID: linker.id)
        let historyBefore = try store.pageVersionHistory(pageID: linker.id)
        let provenanceBefore = try store.pageHeadSources(pageID: linker.id)
        #expect(provenanceBefore.map(\.sourceID) == [evidence.id])

        // Install the abort trigger on a separate raw connection.
        try executeRaw(
            """
            CREATE TRIGGER block_page_links_insert
            BEFORE INSERT ON page_links
            BEGIN
                SELECT RAISE(ABORT, 'link insert blocked by test trigger');
            END;
            """,
            on: url)

        // The composed upsert: the body's `[[Target]]` resolves (a real link
        // row must be inserted), so the link write fails after the content
        // write — inside the same transaction.
        do {
            _ = try PageUpsert.upsert(
                in: store, id: nil, title: "Linker", body: "updated body see [[Target]]",
                expectation: .unrestricted, author: "agent:writer", provenance: provenance)
            Issue.record("expected the link-insert trigger to abort the upsert")
        } catch {
            // Any error shape is fine (raw SQLite RAISE); the assertions below
            // are the contract.
        }

        // Everything content-bearing is unchanged…
        #expect(try store.getPage(id: linker.id).bodyMarkdown == "")
        #expect(try store.pageHeadVersionID(pageID: linker.id) == headBefore)
        #expect(try store.pageVersionHistory(pageID: linker.id) == historyBefore)
        #expect(try store.pageHeadSources(pageID: linker.id) == provenanceBefore)
        // …no link rows appeared…
        #expect(try outgoingPageLinks(from: store, pageID: linker.id).isEmpty)
        // …and no event was emitted for the rolled-back write.
        await settleDeliveries()
        #expect(recorder.count == baselineEvents)

        // Remove the trigger; the SAME upsert succeeds, appends exactly one
        // version, writes the resolved link row, and emits exactly one event.
        try executeRaw("DROP TRIGGER block_page_links_insert;", on: url)
        _ = try PageUpsert.upsert(
            in: store, id: nil, title: "Linker", body: "updated body see [[Target]]",
            expectation: .unrestricted, author: "agent:writer", provenance: provenance)
        try await awaitDeliveredTotal([recorder], expected: baselineEvents + 1)
        #expect(recorder.count == baselineEvents + 1)
        #expect(recorder.snapshot.last?.change == .updated)

        let page = try store.getPage(id: linker.id)
        #expect(page.bodyMarkdown.contains(target.id.rawValue)) // canonicalized `[[page:ULID|Target]]`
        #expect(try store.pageVersionHistory(pageID: linker.id).count == historyBefore.count + 1)
        let links = try outgoingPageLinks(from: store, pageID: linker.id)
        #expect(links.count == 1)
        #expect(links[0].to == target.id.rawValue)
    }

    // MARK: - Two connections, one WAL database

    /// Two `GRDBWikiStore` instances (independent `DatabasePool`s) on one
    /// disposable WAL file: a committed CAS write on B is visible to A's
    /// fresh transaction, A's stale-head write conflicts with nothing
    /// written and no event; then 8 concurrent CAS writes against one head
    /// leave exactly ONE winner and ONE event across both buses.
    @Test func competingUpdatesLeaveHeadLinksConsistent() async throws {
        let (storeA, url) = try disposableTmpStore(prefix: "page-upsert-atomicity-competing")
        let storeB = try GRDBWikiStore(databaseURL: url)
        let (busA, recorderA) = makeBus("upsert-atomicity-competing-a")
        let (busB, recorderB) = makeBus("upsert-atomicity-competing-b")
        storeA.eventBus = busA
        storeB.eventBus = busB

        // Two pages on A: an anchor to link to, and the contended page.
        let anchor = try storeA.createPage(title: "Anchor", createdBy: "user")
        let shared = try storeA.createPage(title: "Shared", body: "v0", createdBy: "user")
        try await awaitDeliveredTotal([recorderA], expected: 2)
        #expect(recorderA.count == 2)

        // B reads the head cross-connection, then commits a CAS write.
        let head0 = try #require(try storeB.pageHeadVersionID(pageID: shared.id))
        _ = try PageUpsert.upsert(
            in: storeB, id: nil, title: "Shared", body: "v1 see [[Anchor]]",
            expectation: .expectedHead(head0), author: "agent:writer-b")
        try await awaitDeliveredTotal([recorderB], expected: 1)
        #expect(recorderB.count == 1)
        #expect(recorderB.snapshot[0].change == .updated)

        // A now writes against the STALE head. A's transaction resolves the
        // CURRENT (B-committed) head, so the CAS fails — nothing written, no
        // event on A's bus (rollback suppression across connections).
        let head1 = try #require(try storeA.pageHeadVersionID(pageID: shared.id))
        #expect(head1 != head0)
        do {
            _ = try PageUpsert.upsert(
                in: storeA, id: nil, title: "Shared", body: "stale see [[Anchor]]",
                expectation: .expectedHead(head0), author: "agent:writer-a")
            Issue.record("expected PageConflictError for the stale head")
        } catch let error as PageConflictError {
            #expect(error.pageID == shared.id)
            #expect(error.actualVersionID == head1)
        }
        await settleDeliveries()
        #expect(recorderA.count == 2) // only the two .created events — conflict emitted nothing

        // Final state: B's version is the head, body canonicalized, exactly
        // one link row to the anchor, two versions total (root + v1).
        let page = try storeB.getPage(id: shared.id)
        #expect(page.bodyMarkdown.contains("v1"))
        #expect(page.bodyMarkdown.contains(anchor.id.rawValue))
        #expect(try storeB.pageHeadVersionID(pageID: shared.id) == head1)
        #expect(try storeB.pageVersionHistory(pageID: shared.id).count == 2)
        let links = try storeB.listAllLinks().filter { $0.from == shared.id.rawValue }
        #expect(links.count == 1)
        #expect(links[0].to == anchor.id.rawValue)

        // 8-way concurrent hammer: every writer expects head1; SQLite's
        // write serialization means the first commit moves the head and the
        // other seven CAS checks see the moved head — exactly one winner.
        let hammerCount = 8
        let wins = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
            for i in 0..<hammerCount {
                group.addTask {
                    let store = i.isMultiple(of: 2) ? storeA : storeB
                    do {
                        _ = try PageUpsert.upsert(
                            in: store, id: nil, title: "Shared", body: "hammer \(i) see [[Anchor]]",
                            expectation: .expectedHead(head1), author: "agent:hammer-\(i)")
                        return 1
                    } catch is PageConflictError {
                        return 0
                    }
                }
            }
            var total = 0
            for try await won in group { total += won }
            return total
        }
        #expect(wins == 1)

        // Exactly one more event across BOTH buses, and the surviving state
        // is the single winner's write with a consistent link graph.
        try await awaitDeliveredTotal([recorderA, recorderB], expected: 4)
        await settleDeliveries()
        #expect(recorderA.count + recorderB.count == 4)
        let finalPage = try storeA.getPage(id: shared.id)
        #expect(finalPage.bodyMarkdown.contains("hammer"))
        #expect(try storeA.pageVersionHistory(pageID: shared.id).count == 3)
        let finalLinks = try storeA.listAllLinks().filter { $0.from == shared.id.rawValue }
        #expect(finalLinks.count == 1)
        #expect(finalLinks[0].to == anchor.id.rawValue)
    }

    // MARK: - Expected head, missing target

    /// An `.expectedHead` write whose target vanished since the read —
    /// deleted (title no longer resolves) or pinned by an id that no longer
    /// exists — is a CONFLICT, never a silent create: no page, no version,
    /// no event. Only `.unrestricted` keeps the legacy create-if-missing.
    @Test func expectedHeadMissingTargetConflicts() async throws {
        let store = try TestStoreFactory.inMemory()
        let (bus, recorder) = makeBus("upsert-atomicity-missing-target")
        store.eventBus = bus

        let doomed = try store.createPage(title: "Doomed", createdBy: "user")
        let head = try #require(try store.pageHeadVersionID(pageID: doomed.id))
        try store.deletePage(id: doomed.id)
        // Await BOTH delivered events (create's `.created` + delete's
        // `.deleted`) before taking the baseline, so the later "no event"
        // assertion cannot race the delete's in-flight delivery.
        try await awaitDeliveredTotal([recorder], expected: 2)
        let baseline = recorder.count
        #expect(try store.resolveTitleToID("Doomed") == nil)

        // Title-selected: nothing resolves anymore.
        do {
            _ = try PageUpsert.upsert(
                in: store, id: nil, title: "Doomed", body: "resurrected",
                expectation: .expectedHead(head), author: "agent:late-writer")
            Issue.record("expected PageExpectedTargetMissingError (title path)")
        } catch let error as PageExpectedTargetMissingError {
            #expect(error.pageID == nil)
            #expect(error.expectedHead == head)
            #expect(error.title == "Doomed")
        }
        // No page was silently created, no version rows anywhere new.
        #expect(try store.resolveTitleToID("Doomed") == nil)

        // Id-selected: the pinned id no longer exists.
        do {
            _ = try PageUpsert.upsert(
                in: store, id: doomed.id, title: "Doomed", body: "resurrected",
                expectation: .expectedHead(head), author: "agent:late-writer")
            Issue.record("expected PageExpectedTargetMissingError (id path)")
        } catch let error as PageExpectedTargetMissingError {
            #expect(error.pageID == doomed.id)
            #expect(error.expectedHead == head)
        }

        // Neither attempt emitted anything.
        await settleDeliveries()
        #expect(recorder.count == baseline)

        // Control: unrestricted on the same missing title still creates
        // (legacy behavior preserved for flag-less callers).
        let revived = try PageUpsert.upsert(
            in: store, id: nil, title: "Doomed", body: "fresh start",
            expectation: .unrestricted, author: "agent:legacy")
        #expect(revived.didCreate)
        try await awaitDeliveredTotal([recorder], expected: baseline + 1)
    }

    // MARK: - Link-only change emits

    /// A composed upsert whose version write is a NO-OP (same canonical body,
    /// same title) but whose link rows CHANGE must still emit exactly one
    /// event — the graph change is real and the File Provider must not go
    /// stale. The stale row is seeded through a raw connection (schema/data
    /// seam, like the trigger test) because a body change would append a
    /// version and emit anyway.
    @Test func linkOnlyChangeEmitsWithoutNewVersion() async throws {
        let (store, url) = try disposableTmpStore(prefix: "page-upsert-atomicity-link-only")
        let (bus, recorder) = makeBus("upsert-atomicity-link-only")
        store.eventBus = bus

        let anchor = try store.createPage(title: "Anchor", createdBy: "user")
        let host = try store.createPage(title: "Host", body: "plain body, no links", createdBy: "agent:sweeper")
        try await awaitDeliveredTotal([recorder], expected: 2)
        let baseline = recorder.count
        let historyBefore = try store.pageVersionHistory(pageID: host.id)
        #expect(try outgoingPageLinks(from: store, pageID: host.id).isEmpty)

        // Seed a stale link row the body does not contain (valid FK target).
        try executeRaw(
            "INSERT INTO page_links (from_page_id, to_page_id, link_text) "
            + "VALUES ('\(host.id.rawValue)', '\(anchor.id.rawValue)', 'stale');",
            on: url)
        #expect(try outgoingPageLinks(from: store, pageID: host.id).count == 1)

        // Same body, same title, distinct author (no amend): the version
        // write no-ops, the stale link row is swept — one event, no version.
        _ = try PageUpsert.upsert(
            in: store, id: nil, title: "Host", body: "plain body, no links",
            expectation: .unrestricted, author: "agent:sweeper")
        try await awaitDeliveredTotal([recorder], expected: baseline + 1)
        #expect(recorder.count == baseline + 1)
        #expect(recorder.snapshot.last?.change == .updated)
        #expect(recorder.snapshot.last?.id == host.id.rawValue)
        #expect(try store.pageVersionHistory(pageID: host.id) == historyBefore)
        #expect(try outgoingPageLinks(from: store, pageID: host.id).isEmpty)

        // And a fully identical follow-up (nothing stale left) emits nothing.
        _ = try PageUpsert.upsert(
            in: store, id: nil, title: "Host", body: "plain body, no links",
            expectation: .unrestricted, author: "agent:sweeper")
        await settleDeliveries()
        #expect(recorder.count == baseline + 1)
    }
}
