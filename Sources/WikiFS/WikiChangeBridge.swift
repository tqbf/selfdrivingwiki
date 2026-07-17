import Foundation
import WikiFSCore
import WikiFSEngine

/// The Phase A change bridge (`plans/llm-wiki.md` — "Change bridge in the app").
///
/// `wikictl` writes straight to a wiki's `<ulid>.sqlite` and posts a per-wiki
/// Darwin notification (`WikiChangeNotification.name(forWikiID:)`). This bridge
/// OBSERVES those notifications — one per registered wiki — and, after a per-wiki
/// ~250 ms coalesce, for the changed wiki: (a) rebuilds the active store's
/// `summaries` if that wiki is on screen, so the sidebar updates live, and (b)
/// calls `signalChange(forWikiID:)` so that wiki's mount refreshes (~5 s).
///
/// Threading: Darwin notifications fire on a CFRunLoop callback (a background-safe
/// source). The CF observer hops onto the main actor before touching the
/// coalescer, the `@MainActor` model, or the File Provider — all main-actor work.
///
/// The coalescing itself lives in the pure `ChangeCoalescer` (unit-tested with a
/// fake clock); this type only supplies a real `Task.sleep`-based scheduler and
/// the main-actor flush.
@MainActor
final class WikiChangeBridge {
    /// The ~250 ms quiet window that collapses one ingest's burst of `wikictl`
    /// calls into a single sidebar rebuild + FP signal per wiki.
    static let coalesceWindow: Duration = .milliseconds(250)

    private let registry: WikiRegistryClient
    private let fileProvider: FileProviderFacade
    /// Returns all live sessions whose `wikiID` matches — injected from the
    /// app via `SessionManager`. Replaces the former `weak var session`
    /// (which held a single session). In multi-window, a `wikictl` write to
    /// wiki A must update every window showing wiki A — the lookup closure
    /// returns all matching sessions so `flush(wikiID:)` can poke each one's
    /// bus. The app sets this to `{ wikiID in sessionManager.allSessions.filter
    /// { $0.wikiID == wikiID } }`.
    var sessionLookup: @MainActor @Sendable (String) -> [WikiSession] = { _ in [] }
    private var coalescer: ChangeCoalescer?

    /// The wiki ids we currently observe, so `refreshObservations()` is
    /// idempotent — it only adds newly-registered wikis and drops removed ones.
    private var observedWikiIDs: Set<String> = []

    init(registry: WikiRegistryClient, fileProvider: FileProviderFacade) {
        self.registry = registry
        self.fileProvider = fileProvider
        self.coalescer = ChangeCoalescer(
            schedule: { [weak self] work in self?.schedule(work) ?? Self.noopHandle() },
            flush: { [weak self] wikiID in self?.flush(wikiID: wikiID) }
        )
    }

    /// Subscribe to the Darwin notification of every wiki in the registry, and
    /// stop observing wikis that no longer exist. Call after `bootstrap` and again
    /// whenever the wiki set changes (create / delete), so a freshly-created
    /// wiki's CLI writes are heard and a deleted wiki's name is released.
    func refreshObservations() {
        let current = Set(registry.wikis.map(\.id))

        for added in current.subtracting(observedWikiIDs) {
            addObserver(forWikiID: added)
        }
        for removed in observedWikiIDs.subtracting(current) {
            removeObserver(forWikiID: removed)
        }
        observedWikiIDs = current
    }

    // MARK: - Darwin observation

    private func addObserver(forWikiID id: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(WikiChangeNotification.name(forWikiID: id) as CFString)
        // The observer pointer is `self` (unretained — we remove on teardown). The
        // callback is a C function, so it can capture nothing; it recovers `self`
        // and the wiki id from the notification name and hops to the main actor.
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let bridge = Unmanaged<WikiChangeBridge>.fromOpaque(observer).takeUnretainedValue()
                let posted = name.rawValue as String
                Task { @MainActor in bridge.didReceiveDarwinNotification(named: posted) }
            },
            name.rawValue,
            nil,
            .deliverImmediately
        )
    }

    private func removeObserver(forWikiID id: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(WikiChangeNotification.name(forWikiID: id) as CFString)
        CFNotificationCenterRemoveObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            name,
            nil
        )
    }

    /// Map a posted Darwin name back to its wiki id and feed the coalescer. The
    /// id is the suffix after the base name; we match against the wikis we observe
    /// rather than string-splitting, so a malformed name is simply ignored.
    private func didReceiveDarwinNotification(named posted: String) {
        guard let wikiID = observedWikiIDs.first(where: {
            posted == WikiChangeNotification.name(forWikiID: $0)
        }) else { return }
        coalescer?.noteChange(forWikiID: wikiID)
    }

    // MARK: - Coalescer plumbing

    /// Real scheduler: sleep the coalesce window on the main actor, then run the
    /// flush unless cancelled. The returned handle cancels the `Task`.
    private func schedule(_ work: @escaping () -> Void) -> ChangeCoalescer.Handle {
        let task = Task { @MainActor in
            try? await Task.sleep(for: Self.coalesceWindow)
            guard !Task.isCancelled else { return }
            work()
        }
        return ChangeCoalescer.Handle { task.cancel() }
    }

    private static func noopHandle() -> ChangeCoalescer.Handle {
        ChangeCoalescer.Handle(cancel: {})
    }

    /// One coalesced flush for `wikiID`. Always signals the File Provider for
    /// the changed wiki — a `wikictl` write can land in any wiki's DB, and that
    /// wiki's filesystem projection must refresh regardless of which wiki is on
    /// screen. Additionally, pokes the bus of EVERY live session whose wikiID
    /// matches — in multi-window, multiple windows may be showing the changed
    /// wiki, and each window's on-screen model must reload its projections
    /// (sidebar, sources, chats, draft). Two windows over the SAME wiki share
    /// ONE session (one store + one bus), so the lookup typically returns
    /// exactly one session.
    ///
    /// Issue #303: the previous either/or structure (bus-OR-FP) meant the
    /// active wiki's FP was refreshed only transitively via the bus subscriber
    /// (which adds a second debounce), and in the edge case where the active
    /// wiki id changed during the coalesce window the model reload was
    /// skipped entirely. Now both paths fire unconditionally for their
    /// respective targets.
    ///
    /// Marked `internal` (not `private`) so `WikiChangeBridgeTests` can call it
    /// directly via `@testable import WikiFS`.
    func flush(wikiID: String) {
        // Always refresh the File Provider — direct, not via the bus subscriber,
        // so the mount is consistent for every wiki the bridge observes.
        Task { await fileProvider.signalChange(forWikiID: wikiID) }

        // Poke ALL sessions whose wikiID matches — a wikictl write to wiki A
        // must update every window showing wiki A.
        for session in sessionLookup(wikiID) {
            session.store.eventBus?.emit(ResourceChangeEvent(
                wikiID: wikiID, kind: nil, id: "", change: .updated))
        }
    }

    deinit {
        // Drop every Darwin observer this bridge registered. `CFNotification…`
        // observers are keyed by the observer pointer; removing with a nil name
        // unregisters them all for this observer.
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
