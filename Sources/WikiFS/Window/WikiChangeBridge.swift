import Foundation
import WikiFSCore
import WikiFSEngine

/// The Phase A change bridge (`plans/llm-wiki.md` — "Change bridge in the app").
///
/// `wikictl` and the `wikid` daemon write straight to a wiki's `<ulid>.sqlite` and
/// post ONE stable, payload-free Darwin notification
/// (`WikiChangeNotification.baseName`) after a committing write. This bridge
/// OBSERVES that single name — subscribed once at launch — and, after a per-wiki
/// ~250 ms coalesce, for every wiki the registry lists: (a) rebuilds the active
/// store's `summaries` if that wiki is on screen, so the sidebar updates live,
/// and (b) calls `signalChange(forWikiID:)` so that wiki's mount refreshes (~5 s).
///
/// ## Why one name and not one per wiki (#1374)
///
/// The previous design encoded the wiki id in the notification NAME and
/// subscribed to one name per registered wiki. A wiki created while the app was
/// running was absent from that subscription set, so its writes were neither
/// heard nor resolvable — pages a chat agent authored into a freshly-created
/// wiki landed in SQLite and never appeared in the UI. There is now no
/// per-wiki subscription set, so no set can go stale: the wake is
/// wiki-agnostic and the wiki set is re-read from the registry at receipt.
///
/// The wake cannot say WHICH wiki changed (Darwin notifications carry no
/// payload), so `WikiChangeWakeRouting` fans out to every wiki the registry
/// lists. See that type for the full rationale.
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
    /// Whether the ONE wiki-change observer is registered. Guarded so
    /// `start()` is idempotent — the launch path may run more than once.
    private var hasStarted = false

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

    /// Subscribe to the ONE wiki-change Darwin notification. Call at launch.
    ///
    /// Idempotent: a second call is a no-op, so the launch path can run more than
    /// once without double-registering (which would double every flush).
    /// There is nothing wiki-specific to refresh here — the wiki set is re-read
    /// at receipt — so a newly-created wiki needs no call at all (#1374).
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        addChangeObserver()
        // Observability: the receive path is otherwise silent, and a bridge
        // that never observed anything looks exactly like "writers stopped
        // posting". One line at subscription time.
        DebugLog.store(
            "WikiChangeBridge: observing \(WikiChangeNotification.baseName) for Darwin change notifications")
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

    /// The wiki-change observer — ONE registration, for the whole app lifetime.
    private func addChangeObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(WikiChangeNotification.baseName as CFString)
        // The observer pointer is `self` (unretained — we remove on teardown). The
        // callback is a C function, so it can capture nothing; it recovers `self`
        // and the posted name and hops to the main actor.
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
    ///
    /// Unlike the Darwin wake, this path KNOWS the wiki id, so it feeds the
    /// per-wiki coalescer directly instead of fanning out.
    func noteSuspectedExternalWrite(forWikiID wikiID: WikiID) {
        DebugLog.store(
            "WikiChangeBridge: chat tool activity → wiki \(wikiID.rawValue.prefix(8)) (coalesced reload)")
        coalescer?.noteChange(forWikiID: wikiID)
    }

    /// Handle a posted Darwin name: route a renderer-machine wake to its handler,
    /// or fan a wiki-change wake out to every wiki the CURRENT registry lists.
    ///
    /// The registry is re-read from disk HERE, at receipt — not captured at
    /// launch — so a wiki created while the app is running (by `wikictl` or the
    /// daemon, either of which writes `wikis.json` directly) is refreshed by the
    /// next wake with no explicit refresh call anywhere (#1374).
    ///
    /// The name is resolved BEFORE the registry read, on purpose: rejecting a
    /// name from another namespace needs no wiki set, and this callback is shared
    /// with the renderer-machine namespace. Reloading first made a foreign wake
    /// (a renderer-machine notification) pay a main-actor disk read it never
    /// uses.
    ///
    /// Marked `internal` (not `private`) so `WikiChangeBridgeTests` can drive the
    /// receive path directly via `@testable import WikiFS` — same precedent as
    /// `flush(wikiID:)`. Posting a real Darwin notification from a test would
    /// exercise the same code but through an in-process broadcast that is not
    /// reliably ordered with the test's assertions.
    func didReceiveDarwinNotification(named posted: String) {
        if let scope = RendererMachineWakeRouting.scope(forNotificationName: posted, observedScopes: observedRendererMachineScopes) {
            rendererMachineWakeHandler(scope)
            return
        }
        // The wiki set is only needed to resolve an ACCEPTED wiki-change name, so
        // a foreign name returns before any registry read. This is the same
        // predicate `WikiChangeWakeRouting.wikiIDs` applies; it is stated here as
        // well because rejecting early is the whole point — routing cannot reject
        // without being handed a wiki set, and building that set costs a disk read.
        guard posted == WikiChangeNotification.baseName else { return }
        // Re-read the authoritative registry before resolving: the wake is
        // wiki-agnostic, so the current wiki set is the only thing that can say
        // which wikis to refresh.
        registry.reloadFromDisk()
        let knownWikiIDs = registry.wikis.map(\.id)
        guard let wikiIDs = WikiChangeWakeRouting.wikiIDs(
            forNotificationName: posted, knownWikiIDs: knownWikiIDs
        ) else { return }
        // Observability: one line per received post, naming how many wikis the
        // fan-out covers. A wikictl/daemon write burst logs a handful of these;
        // silence here means the post never arrived or the bridge was never
        // observing.
        DebugLog.store(
            "WikiChangeBridge: Darwin change notification → refreshing \(wikiIDs.count) wiki(s)")
        // `noteChangeIfNotPending`, NOT `noteChange`: this loop visits every
        // registry wiki on every wake, so re-arming would reschedule each wiki's
        // timer for a change that may not be that wiki's — a burst of writes to
        // one wiki would then keep pushing every OTHER wiki's flush deadline out.
        // A wiki with a flush already in flight keeps it.
        for wikiID in wikiIDs {
            coalescer?.noteChangeIfNotPending(forWikiID: wikiID)
        }
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
    /// The wiki-agnostic wake calls this once per registry wiki; each call is
    /// idempotent. A stale registry entry still costs the full File Provider
    /// signal, not a cheap lookup: `signalChange(forWikiID:)` iterates 13
    /// containers and awaits `signalEnumerator` on each with a 3 s timeout, and
    /// `NSFileProviderManager(for:)` returns a manager for any identifier whether
    /// the domain is registered or not, so nothing short-circuits. The bus poke
    /// for a wiki with no live session is the only part that returns nothing.
    ///
    /// Marked `internal` (not `private`) so `WikiChangeBridgeTests` can call it
    /// directly via `@testable import WikiFS`.
    func flush(wikiID: WikiID) {
        // Always refresh the File Provider — direct, not via the bus subscriber,
        // so the mount is consistent for every wiki the bridge refreshes.
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
