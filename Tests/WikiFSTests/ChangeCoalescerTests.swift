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
}
