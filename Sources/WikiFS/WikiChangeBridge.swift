import Foundation
import WikiFSCore

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

    private let manager: WikiManager
    private let fileProvider: FileProviderSpike
    private var coalescer: ChangeCoalescer?

    /// The wiki ids we currently observe, so `refreshObservations()` is
    /// idempotent — it only adds newly-registered wikis and drops removed ones.
    private var observedWikiIDs: Set<String> = []

    init(manager: WikiManager, fileProvider: FileProviderSpike) {
        self.manager = manager
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
        let current = Set(manager.wikis.map(\.id))

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

    /// One coalesced flush for `wikiID`. For the active wiki, emit a coarse
    /// `.external` event into the active store's bus — the model's `.external`
    /// subscription rebuilds its projections (replacing the old direct
    /// `reloadFromStore()`) and the File Provider subscriber signals, both on the
    /// same bus. For a non-active wiki there is no in-memory store/bus, so signal
    /// the FP directly (unchanged). The Darwin notification carries no per-
    /// resource detail, so the reload stays full-model exactly as before.
    private func flush(wikiID: String) {
        if manager.activeWikiID == wikiID, let bus = manager.activeStore?.eventBus {
            bus.emit(ResourceChangeEvent(
                wikiID: wikiID, kind: nil, id: "", change: .updated))
        } else {
            Task { await fileProvider.signalChange(forWikiID: wikiID) }
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
