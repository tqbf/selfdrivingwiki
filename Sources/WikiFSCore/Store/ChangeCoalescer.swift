import Foundation

/// Per-wiki coalescing of change notifications (`plans/llm-wiki.md` — Change
/// bridge "Debounce per wiki (~250 ms coalesce)").
///
/// A single ingest fires ~15 `wikictl` calls in a burst; each posts a Darwin
/// notification. Without coalescing the app would do ~15 sidebar rebuilds + ~15
/// File Provider signals for one logical change. This type collapses a burst per
/// wiki into a single deferred "flush" after a quiet window.
///
/// It is a PURE state machine over an injected scheduler and an injected flush
/// callback — it touches no Darwin/Foundation timer of its own — so the
/// coalescing behavior is unit-testable deterministically (a test drives a fake
/// clock and asserts exactly one flush per burst). The app layer
/// (`WikiChangeBridge`) supplies a real `Task.sleep`-based scheduler and hops the
/// flush to the main actor.
///
/// Not thread-safe on its own; the owner confines all calls to one actor/queue
/// (the app uses the main actor).
public final class ChangeCoalescer {
    /// Cancellable handle for one scheduled flush — the scheduler returns one and
    /// the coalescer calls `cancel()` to drop a superseded timer.
    public final class Handle {
        let cancel: () -> Void
        public init(cancel: @escaping () -> Void) {
            self.cancel = cancel
        }
    }

    /// Schedule `work` to run after the coalescing window, returning a handle the
    /// coalescer keeps so a later notification in the same window can cancel and
    /// reschedule it. The app injects a `Task.sleep`-based implementation.
    private let schedule: (_ work: @escaping () -> Void) -> Handle

    /// Invoked once per coalesced burst, with the wiki id that changed.
    private let flush: (_ wikiID: String) -> Void

    /// Pending flush handles, keyed by wiki id — at most one per wiki in flight.
    private var pending: [String: Handle] = [:]

    public init(
        schedule: @escaping (_ work: @escaping () -> Void) -> Handle,
        flush: @escaping (_ wikiID: String) -> Void
    ) {
        self.schedule = schedule
        self.flush = flush
    }

    /// Record a change for `wikiID`. Cancels any in-flight flush for that wiki and
    /// schedules a fresh one, so a burst collapses to a single flush after the
    /// window goes quiet. Other wikis' pending flushes are untouched (the
    /// coalescing is strictly per wiki, so one wiki's burst can't delay another's
    /// refresh).
    public func noteChange(forWikiID wikiID: String) {
        pending[wikiID]?.cancel()
        pending[wikiID] = schedule { [weak self] in
            guard let self else { return }
            pending[wikiID] = nil
            flush(wikiID)
        }
    }
}
