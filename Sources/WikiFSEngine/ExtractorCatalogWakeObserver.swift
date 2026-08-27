import Foundation
import WikiFSCore

/// Collapses duplicate catalog wakes into ordered reconciliation passes.
///
/// A wake is only an invitation to reread the authoritative catalog. Duplicate
/// or concurrent wakes set one bit; the active pass observes it after it
/// finishes, so one process never reconciles the same context concurrently and
/// never loses a wake that arrived mid-pass.
actor ExtractorCatalogWakeCoalescer {
    private let reconcile: @Sendable () async -> Void
    private var isDraining = false
    private var hasPendingWake = false
    private var isCancelled = false
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainFinishedWaiters: [CheckedContinuation<Void, Never>] = []

    init(reconcile: @escaping @Sendable () async -> Void) {
        self.reconcile = reconcile
    }

    /// - Parameter waitForQuiescence: when true, a wake that arrives during an
    ///   active pass suspends until the drain that observes its pending bit
    ///   finishes. Notification-driven wakes pass false because they are
    ///   fire-and-forget hints; a caller that needs to read the applied
    ///   generation passes true so it cannot observe a half-applied pass.
    func receiveWake(waitForQuiescence: Bool = true) async {
        guard isCancelled == false else { return }
        guard isDraining == false else {
            hasPendingWake = true
            guard waitForQuiescence else { return }
            await withCheckedContinuation { quiescenceWaiters.append($0) }
            return
        }
        isDraining = true

        repeat {
            hasPendingWake = false
            await reconcile()
        } while hasPendingWake && isCancelled == false

        isDraining = false
        resumeQuiescenceWaiters()
        resumeDrainFinishedWaiters()
    }

    /// Stops future passes and waits for any in-flight pass to finish. The
    /// caller can then dispose the graph the pass was reconciling: no
    /// reconciliation can still be running when this returns.
    func cancel() async {
        isCancelled = true
        hasPendingWake = false
        resumeQuiescenceWaiters()
        while isDraining {
            await withCheckedContinuation { drainFinishedWaiters.append($0) }
        }
    }

    /// Every suspended caller is resumed by the drain owner or by cancellation,
    /// so no continuation can be abandoned.
    private func resumeQuiescenceWaiters() {
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Resumed only by the drain owner, which always reaches this after
    /// clearing `isDraining`.
    private func resumeDrainFinishedWaiters() {
        let waiters = drainFinishedWaiters
        drainFinishedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Process-lifetime bridge from local and cross-process catalog wakes to one
/// coalescer. It carries no generation and no package payload: the durable
/// catalog remains the only authority for what this process applies.
// Sendability invariant: the coalescer is an actor, and the only other mutable
// state is `localToken` and `darwinRegistration`, both claimed solely under
// `tokenLock`. Darwin observer registration and removal are keyed by this
// object's address and are safe to call from any thread.
// swiftlint:disable:next unchecked_sendable
final class ExtractorCatalogWakeObserver: @unchecked Sendable {
    private let coalescer: ExtractorCatalogWakeCoalescer
    private let scopeRoot: URL?
    private let tokenLock = NSLock()
    private var localToken: NSObjectProtocol?
    private var darwinRegistration: Unmanaged<ExtractorCatalogWakeObserver>?
    private var acceptedWakes = 0

    /// - Parameter scopeRoot: the store this context reads. An in-process
    ///   notification for a different store is ignored, so two contexts over
    ///   two stores in one process never wake each other. A nil root accepts
    ///   every notification.
    init(scopeRoot: URL?, reconcile: @escaping @Sendable () async -> Void) {
        self.scopeRoot = scopeRoot?.standardizedFileURL
        coalescer = ExtractorCatalogWakeCoalescer(reconcile: reconcile)
        // Assigned before the object escapes, so no other thread can observe it.
        localToken = NotificationCenter.default.addObserver(
            forName: .extractorPackageCatalogDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, self.accepts(notification) else { return }
            self.noteAcceptedWake()
            self.scheduleWake()
        }
        #if os(macOS)
        // Retained, not unretained: the Darwin center holds a raw pointer it
        // cannot keep alive, so an owner that drops this observer without
        // calling stop() would otherwise leave a dangling callback target. The
        // matching release happens exactly once in removeDarwinObserver().
        let registration = Unmanaged.passRetained(self)
        darwinRegistration = registration
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            registration.toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<ExtractorCatalogWakeObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                    .scheduleWake()
            },
            ExtractorCatalogChangeNotification.darwinName as CFString,
            nil,
            .deliverImmediately)
        #endif
    }

    /// Counts notifications this observer accepted for its own store.
    /// Notification delivery is synchronous, so a test can assert the scoping
    /// decision without waiting on the pass it schedules.
    var acceptedWakeCount: Int { tokenLock.withLock { acceptedWakes } }

    private func noteAcceptedWake() {
        tokenLock.withLock { acceptedWakes += 1 }
    }

    /// A posted store root that is not this observer's store is another
    /// context's publication. An unscoped notification is always accepted.
    private func accepts(_ notification: Notification) -> Bool {
        guard let scopeRoot else { return true }
        guard let posted = notification.object as? URL else { return true }
        return posted.standardizedFileURL == scopeRoot
    }

    /// Fire-and-forget delivery for notification callbacks. It never blocks the
    /// poster, and a hint that lands mid-pass is preserved as a pending bit.
    func scheduleWake() {
        Task { [coalescer] in await coalescer.receiveWake(waitForQuiescence: false) }
    }

    /// Awaits one reconciliation pass. Production wakes are fire-and-forget;
    /// callers that must observe the applied generation use this instead.
    func receiveWake() async {
        await coalescer.receiveWake()
    }

    func stop() async {
        removeLocalObserver()
        removeDarwinObserver()
        await coalescer.cancel()
    }

    deinit {
        removeLocalObserver()
        removeDarwinObserver()
    }

    /// Idempotent: whichever of `stop()` or `deinit` runs first claims the
    /// token, so the observer is never removed twice.
    private func removeLocalObserver() {
        let token = tokenLock.withLock { () -> NSObjectProtocol? in
            let claimed = localToken
            localToken = nil
            return claimed
        }
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
    }

    /// Idempotent: the registration is claimed under the lock, so the retain
    /// taken at init is balanced exactly once no matter how often this runs.
    private func removeDarwinObserver() {
        #if os(macOS)
        let claimed = tokenLock.withLock { () -> Unmanaged<ExtractorCatalogWakeObserver>? in
            let registration = darwinRegistration
            darwinRegistration = nil
            return registration
        }
        guard let claimed else { return }
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            claimed.toOpaque())
        claimed.release()
        #endif
    }
}
