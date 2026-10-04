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
    var sessionLookup: @MainActor @Sendable (WikiID) -> [any WikiSessionProtocol] = { _ in [] }
    private var coalescer: ChangeCoalescer?

    /// The wiki ids we currently observe, so `refreshObservations()` is
    /// idempotent — it only adds newly-registered wikis and drops removed ones.
    private var observedWikiIDs: Set<WikiID> = []
    /// Renderer machine wakes use a different Darwin namespace and are routed
    /// to the durable renderer reader. They never enter the generic resource
    /// coalescer below, which is the only path that signals File Provider.
    private var observedRendererMachineScopes: Set<RendererMachineScopeID> = []
    var rendererMachineWakeHandler: @MainActor @Sendable (RendererMachineScopeID) -> Void = { _ in }

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
        // Observability: the receive path is otherwise silent, and a bridge
        // that never observed anything looks exactly like "writers stopped
        // posting". One line per observation-set change.
        DebugLog.store(
            "WikiChangeBridge: observing \(current.count) wiki(s) for Darwin change notifications")
    }

    /// Update the explicitly observed machine scopes. App wiring owns the
    /// reader subscription; this bridge only maps the payload-free notification
    /// name back to that scope identity.
    func refreshRendererMachineObservations(_ scopes: Set<RendererMachineScopeID>) {
        for added in scopes.subtracting(observedRendererMachineScopes) {
            addRendererMachineObserver(for: added)
        }
        for removed in observedRendererMachineScopes.subtracting(scopes) {
            removeRendererMachineObserver(for: removed)
        }
        observedRendererMachineScopes = scopes
    }

    // MARK: - Darwin observation

    private func addObserver(forWikiID id: WikiID) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(WikiChangeNotification.name(forWikiID: id.rawValue) as CFString)
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
                Task { @MainActor in
                    // Observability: raw CF-level receipt, BEFORE any name
                    // matching. If a post never produces this line, the
                    // observer itself is dead (bridge deallocated and its
                    // deinit removed every registration, or the registration
                    // landed on a run loop that never runs) — silence here is
                    // a delivery failure, not a filtering failure.
                    DebugLog.store(
                        "WikiChangeBridge: CF callback fired — name=\(posted)")
                    bridge.didReceiveDarwinNotification(named: posted)
                }
            },
            name.rawValue,
            nil,
            .deliverImmediately
        )
    }

    private func removeObserver(forWikiID id: WikiID) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(WikiChangeNotification.name(forWikiID: id.rawValue) as CFString)
        CFNotificationCenterRemoveObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            name,
            nil
        )
    }

    private func addRendererMachineObserver(for scope: RendererMachineScopeID) {
        let name = CFNotificationName(RendererChangeNotification.machineName(for: scope) as CFString)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let bridge = Unmanaged<WikiChangeBridge>.fromOpaque(observer).takeUnretainedValue()
                let posted = name.rawValue as String
                Task { @MainActor in bridge.didReceiveDarwinNotification(named: posted) }
            },
            name.rawValue, nil, .deliverImmediately
        )
    }

    private func removeRendererMachineObserver(for scope: RendererMachineScopeID) {
        let name = CFNotificationName(RendererChangeNotification.machineName(for: scope) as CFString)
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), name, nil
        )
    }

    /// Feed an in-process hint about a suspected external write — e.g. an
    /// agent chat tool call that just stopped, and whose shell command may
    /// have committed to the wiki database (a CLI run) — through the SAME
    /// coalesced path a cross-process change notification takes: reload the
    /// on-screen session(s) + signal the File Provider after the ~250 ms
    /// quiet window.
    ///
    /// This is the deterministic in-process companion to the Darwin
    /// notification channel: when that channel delivers, both paths collapse
    /// into the same coalesced reload; when it does not, this hint still
    /// refreshes after chat-driven writes. The hint is heuristic (a tool call
    /// MIGHT have written), so it costs at most one idempotent reload.
    func noteSuspectedExternalWrite(forWikiID wikiID: WikiID) {
        DebugLog.store(
            "WikiChangeBridge: chat tool activity → wiki \(wikiID.rawValue.prefix(8)) (coalesced reload)")
        coalescer?.noteChange(forWikiID: wikiID)
    }

    /// Map a posted Darwin name back to its wiki id and feed the coalescer. The
    /// id is the suffix after the base name; we match against the wikis we observe
    /// rather than string-splitting, so a malformed name is simply ignored.
    private func didReceiveDarwinNotification(named posted: String) {
        if let scope = RendererMachineWakeRouting.scope(forNotificationName: posted, observedScopes: observedRendererMachineScopes) {
            rendererMachineWakeHandler(scope)
            return
        }
        guard let wikiID = observedWikiIDs.first(where: {
            posted == WikiChangeNotification.name(forWikiID: $0.rawValue)
        }) else { return }
        // Observability: one line per received post. A wikictl/daemon write
        // burst logs a handful of these; silence here means the post never
        // arrived or the bridge was never observing.
        DebugLog.store(
            "WikiChangeBridge: Darwin change notification → wiki \(wikiID.rawValue.prefix(8))")
        coalescer?.noteChange(forWikiID: wikiID)
    }

    // MARK: - Coalescer plumbing

    /// Real scheduler: sleep the coalesce window on the main actor, then run the
    /// flush unless cancelled. The returned handle cancels the `Task`.
    private func schedule(_ work: @escaping () -> Void) -> ChangeCoalescer.Handle {
        let task = Task { @MainActor in
            // Task.sleep only throws CancellationError — expected, not actionable.
            // swiftlint:disable:next silent_try_optional
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
    func flush(wikiID: WikiID) {
        // Always refresh the File Provider — direct, not via the bus subscriber,
        // so the mount is consistent for every wiki the bridge observes.
        Task { await fileProvider.signalChange(forWikiID: wikiID) }

        // Poke ALL sessions whose wikiID matches — a wikictl write to wiki A
        // must update every window showing wiki A.
        let sessions = sessionLookup(wikiID)
        // Observability: "poked 0 session(s)" is the smoking-gun signature of
        // a post that arrived but matched no live session (window closed
        // before the write, or a session-manager wiring regression).
        DebugLog.store(
            "WikiChangeBridge: flush wiki \(wikiID.rawValue.prefix(8)) — poked \(sessions.count) session(s)")
        for session in sessions {
            session.store.eventBus?.emit(ResourceChangeEvent(
                wikiID: wikiID, kind: nil, id: "", change: .updated))
        }
    }

    deinit {
        // Observability: a deallocated bridge silently unregisters every
        // Darwin observer (below), and from the outside that looks exactly
        // like "writers stopped posting" — the app never reloads again. This
        // line makes the death visible in Console.app. (No property reads
        // here: deinit is nonisolated and the bridge is @MainActor.)
        DebugLog.store(
            "WikiChangeBridge: deinit — dropping all Darwin wiki observers")
        // Drop every Darwin observer this bridge registered. `CFNotification…`
        // observers are keyed by the observer pointer; removing with a nil name
        // unregisters them all for this observer.
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
