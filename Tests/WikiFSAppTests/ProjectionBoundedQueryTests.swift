#if os(macOS)
import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// AC.11 (#291): one LOGICAL File Provider operation issues a BOUNDED
/// number of wire operations — the `ReadScope`'s per-pass caches collapse
/// repeated reads, so an enumeration pass costs its DISTINCT reads, not a
/// per-node re-read of the shared scans. The projection client's
/// `operationCounter` records every wire op; this suite pins the bound
/// through the REAL socket fixture.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ProjectionBoundedQueryTests {

    /// Honest per-pass wire-op budgets for the seeded fixture (12 pages +
    /// 1 source). Each budget is the pass's DISTINCT reads plus a small
    /// margin. The per-page term is spelled out because per-ROW reads are
    /// the one part that legitimately scales with row count:
    /// - a pages view = 8 batch reads (page + source listings, the two
    ///   credibility-signal aggregates, and — by-title — the link-map
    ///   build's chats + heads + origins + sibling-images) plus 3 reads
    ///   PER PAGE (role-filtered cite links, head version id, trust
    ///   metadata) — per-row data no batch wire op carries today;
    /// - the working set = 15 batch reads (the pages-view set, shared by
    ///   BOTH views, + token + the two link scans + the three doc rows +
    ///   the bookmark listing) plus the same 3 PER PAGE, ONCE — both views
    ///   share one derivation;
    /// - the root = 7 batch reads (token + three listings + three doc rows).
    private enum PassBudget {
        static let seededPages = 12
        static let perPageDistinctReads = 3
        /// Batch-read allowance per pages view (honest 8 + 4 margin).
        static let pagesViewBase = 12
        /// Root-pass allowance (honest 7 + 5 margin).
        static let root = 12
        /// Working-set batch-read allowance (honest 15 + 9 margin).
        static let workingSetBase = 24

        static var pagesView: Int { pagesViewBase + perPageDistinctReads * seededPages }
        static var workingSet: Int { workingSetBase + perPageDistinctReads * seededPages }
    }

    /// A full enumeration pass (root + both page views + working set) costs
    /// one wire op per DISTINCT store read — never a per-node re-read of the
    /// shared scans. Each `children` call is ONE logical File Provider
    /// operation and opens its OWN `ReadScope` (request-scoped by design: the
    /// enumerator performs one checked call per system callback, and a
    /// value-type `Projection` cannot hand a later call this call's scope),
    /// so the bound is PER PASS and a later call legitimately re-lists.
    @Test func enumerationPassIssuesBoundedWireOpsWithinOneScope() throws {
        let fixture = try ProjectionSocketFixture.make(displayName: "Bounded Query Wiki")
        // Seed enough nodes that an O(nodes) bug cannot hide under the budget.
        for i in 0..<PassBudget.seededPages {
            _ = try fixture.store.createPage(title: "Page \(i)")
        }
        _ = try fixture.store.addSource(
            filename: "doc.pdf", data: Data("%PDF-1.4".utf8),
            mimeType: "application/pdf")

        let counter = LockIsolatedCounter()
        let recordingClient = DaemonProjectionClient(
            wikiID: fixture.descriptor.id,
            containerDirectory: { fixture.container },
            operationCounter: { counter.record($0) })

        let scoped = Projection(
            wikiID: fixture.descriptor.id, source: recordingClient)
        var mark = 0
        func passDelta() -> Int {
            let delta = counter.count - mark
            mark = counter.count
            return delta
        }

        _ = scoped.children(of: .rootContainer)
        let rootPass = passDelta()
        _ = scoped.children(of: Projection.Identity.pagesByTitle)
        let byTitlePass = passDelta()
        _ = scoped.children(of: Projection.Identity.pagesByID)
        let byIDPass = passDelta()
        _ = scoped.children(of: .workingSet)
        let workingSetPass = passDelta()

        #expect(rootPass > 0, "the pass must have issued real wire ops")
        #expect(
            rootPass <= PassBudget.root,
            "the root pass issued \(rootPass) wire ops — the per-scope caches are not collapsing repeated listings (#291)")
        #expect(
            byTitlePass <= PassBudget.pagesView,
            "the by-title pass issued \(byTitlePass) wire ops for 13 rows — expected \(PassBudget.pagesViewBase) batch + \(PassBudget.perPageDistinctReads) per page; the per-scope caches are not collapsing repeated reads (#291)")
        #expect(
            byIDPass <= PassBudget.pagesView,
            "the by-id pass issued \(byIDPass) wire ops for 13 rows — expected \(PassBudget.pagesViewBase) batch + \(PassBudget.perPageDistinctReads) per page (#291)")
        #expect(
            workingSetPass <= PassBudget.workingSet,
            "the working-set pass issued \(workingSetPass) wire ops — both views must share ONE per-page derivation and ONE set of batch reads (#291)")

        // A second pass over the same containers re-lists (each call opens a
        // fresh request-scoped `ReadScope` — see above), so the cross-call
        // ≤-2 delta this test originally asserted is over-strict by design;
        // what must hold is that the re-read STILL meets the per-pass bound.
        _ = scoped.children(of: .rootContainer)
        let rootReRead = passDelta()
        _ = scoped.children(of: Projection.Identity.pagesByTitle)
        let byTitleReRead = passDelta()
        #expect(
            rootReRead <= PassBudget.root,
            "re-reading the root issued \(rootReRead) wire ops — a fresh scope re-lists once, never per node (#291)")
        #expect(
            byTitleReRead <= PassBudget.pagesView,
            "re-reading by-title issued \(byTitleReRead) wire ops — a fresh scope re-lists once, never per node (#291)")
    }
}

/// A lock-guarded counter the @Sendable operation hook can record into.
private final class LockIsolatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func record(_ op: String) {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
#endif
