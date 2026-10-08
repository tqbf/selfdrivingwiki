import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the pure per-wiki coalescing state machine (`ChangeCoalescer`) that
/// the app's change bridge uses to collapse one ingest's burst of `wikictl`
/// Darwin notifications into a single sidebar rebuild + FP signal per wiki.
///
/// A manual scheduler stands in for the real `Task.sleep` window: scheduled work
/// is captured (not run) until the test explicitly fires it, so coalescing is
/// asserted deterministically with no timing flake.
struct ChangeCoalescerTests {

    /// Captures scheduled work so the test can fire or cancel it on demand. A
    /// scheduled item supersedes nothing on its own; the coalescer cancels the
    /// prior item's handle before scheduling a new one.
    private final class ManualScheduler {
        private var pending: [Int: () -> Void] = [:]
        private var nextID = 0
        private(set) var cancelledIDs: [Int] = []

        func schedule(_ work: @escaping () -> Void) -> ChangeCoalescer.Handle {
            let id = nextID
            nextID += 1
            pending[id] = work
            return ChangeCoalescer.Handle { [weak self] in
                self?.pending[id] = nil
                self?.cancelledIDs.append(id)
            }
        }

        /// Fire every still-pending scheduled item (in scheduling order).
        func fireAll() {
            let items = pending.sorted { $0.key < $1.key }.map(\.value)
            pending.removeAll()
            for work in items { work() }
        }

        var pendingCount: Int { pending.count }
    }

    @Test func burstForOneWikiCoalescesToSingleFlush() {
        let scheduler = ManualScheduler()
        var flushes: [WikiID] = []
        let coalescer = ChangeCoalescer(
            schedule: { scheduler.schedule($0) },
            flush: { flushes.append($0) }
        )

        // 15 notifications in a burst (one ingest), like the doc describes.
        for _ in 0..<15 { coalescer.noteChange(forWikiID: WikiID(rawValue: "WIKI_A")) }
        // Only one timer is live — the prior 14 were cancelled on reschedule.
        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.cancelledIDs.count == 14)

        scheduler.fireAll()
        #expect(flushes == [WikiID(rawValue: "WIKI_A")])
    }

    @Test func distinctWikisFlushIndependently() {
        let scheduler = ManualScheduler()
        var flushes: [WikiID] = []
        let coalescer = ChangeCoalescer(
            schedule: { scheduler.schedule($0) },
            flush: { flushes.append($0) }
        )

        coalescer.noteChange(forWikiID: WikiID(rawValue: "A"))
        coalescer.noteChange(forWikiID: WikiID(rawValue: "B"))
        coalescer.noteChange(forWikiID: WikiID(rawValue: "A"))    // coalesces with A only

        // Two live timers (one per wiki); A's first was cancelled.
        #expect(scheduler.pendingCount == 2)
        #expect(scheduler.cancelledIDs.count == 1)

        scheduler.fireAll()
        #expect(flushes.sorted { $0.rawValue < $1.rawValue } == [WikiID(rawValue: "A"), WikiID(rawValue: "B")])
    }

    @Test func aSecondBurstAfterFlushSchedulesAgain() {
        let scheduler = ManualScheduler()
        var flushes: [WikiID] = []
        let coalescer = ChangeCoalescer(
            schedule: { scheduler.schedule($0) },
            flush: { flushes.append($0) }
        )

        coalescer.noteChange(forWikiID: WikiID(rawValue: "A"))
        scheduler.fireAll()
        #expect(flushes == [WikiID(rawValue: "A")])

        // A later, separate burst re-arms a fresh flush (the pending slot was
        // cleared on the first flush).
        coalescer.noteChange(forWikiID: WikiID(rawValue: "A"))
        #expect(scheduler.pendingCount == 1)
        scheduler.fireAll()
        #expect(flushes == [WikiID(rawValue: "A"), WikiID(rawValue: "A")])
    }

    // MARK: - noteChangeIfNotPending (the wiki-agnostic wake path)

    /// A second `noteChangeIfNotPending` for the SAME wiki does not extend the
    /// deadline: the first call armed the flush, the second leaves it alone. This
    /// is what stops a fan-out wake from re-arming every wiki's timer.
    @Test func noteChangeIfNotPendingDoesNotRearmAPendingFlush() {
        let scheduler = ManualScheduler()
        var flushes: [WikiID] = []
        let coalescer = ChangeCoalescer(
            schedule: { scheduler.schedule($0) },
            flush: { flushes.append($0) }
        )

        coalescer.noteChangeIfNotPending(forWikiID: WikiID(rawValue: "A"))
        coalescer.noteChangeIfNotPending(forWikiID: WikiID(rawValue: "A"))
        coalescer.noteChangeIfNotPending(forWikiID: WikiID(rawValue: "A"))

        // One timer, and NONE was cancelled — the pending flush was never
        // superseded, so its original deadline stands.
        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.cancelledIDs.isEmpty)

        scheduler.fireAll()
        #expect(flushes == [WikiID(rawValue: "A")])
    }

    /// `noteChange` DOES still re-arm: the contrast that makes the previous test
    /// meaningful (same call count, different cancellation).
    @Test func noteChangeStillRearmsAPendingFlush() {
        let scheduler = ManualScheduler()
        var flushes: [WikiID] = []
        let coalescer = ChangeCoalescer(
            schedule: { scheduler.schedule($0) },
            flush: { flushes.append($0) }
        )

        coalescer.noteChange(forWikiID: WikiID(rawValue: "A"))
        coalescer.noteChange(forWikiID: WikiID(rawValue: "A"))
        coalescer.noteChange(forWikiID: WikiID(rawValue: "A"))

        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.cancelledIDs.count == 2)

        scheduler.fireAll()
        #expect(flushes == [WikiID(rawValue: "A")])
    }

    /// A burst on wiki A does not defer wiki B's flush — the invariant the
    /// coalescer documents. A wiki-agnostic wake visits every wiki, so if the
    /// fan-out re-armed each visit, every A visit would push B's deadline out and
    /// B's refresh would wait for A's burst to go quiet.
    @Test func burstOnOneWikiDoesNotDeferAnotherWikisFlush() {
        let scheduler = ManualScheduler()
        var flushes: [WikiID] = []
        let coalescer = ChangeCoalescer(
            schedule: { scheduler.schedule($0) },
            flush: { flushes.append($0) }
        )

        let wikiA = WikiID(rawValue: "A")
        let wikiB = WikiID(rawValue: "B")

        // Wiki B's own write arms its flush.
        coalescer.noteChange(forWikiID: wikiB)
        // Wiki A's write burst arrives; each wake fans out over BOTH wikis.
        for _ in 0..<15 {
            coalescer.noteChangeIfNotPending(forWikiID: wikiA)
            coalescer.noteChangeIfNotPending(forWikiID: wikiB)
        }

        // One live timer per wiki. B's original timer survived the whole burst —
        // the only cancellation is A's own re-arm, which `noteChangeIfNotPending`
        // never performs, so nothing was cancelled at all.
        #expect(scheduler.pendingCount == 2)
        #expect(scheduler.cancelledIDs.isEmpty)

        scheduler.fireAll()
        #expect(flushes.sorted { $0.rawValue < $1.rawValue } == [wikiA, wikiB])
    }

    /// A wiki whose flush already landed is armed again by the next
    /// `noteChangeIfNotPending` — the variant suppresses only a PENDING flush, so
    /// the wake path still refreshes each wiki once per burst.
    @Test func noteChangeIfNotPendingArmsAgainAfterAFlushLands() {
        let scheduler = ManualScheduler()
        var flushes: [WikiID] = []
        let coalescer = ChangeCoalescer(
            schedule: { scheduler.schedule($0) },
            flush: { flushes.append($0) }
        )

        coalescer.noteChangeIfNotPending(forWikiID: WikiID(rawValue: "A"))
        scheduler.fireAll()
        #expect(flushes == [WikiID(rawValue: "A")])

        // The pending slot was cleared by the flush, so the next wake re-arms.
        coalescer.noteChangeIfNotPending(forWikiID: WikiID(rawValue: "A"))
        #expect(scheduler.pendingCount == 1)
        scheduler.fireAll()
        #expect(flushes == [WikiID(rawValue: "A"), WikiID(rawValue: "A")])
    }
}
