import Foundation

// `ResourceKind` (and the `ChangeTokenContributor` abstraction)
// now live in `Resource.swift` (slice 2b) next to the access layer that owns
// them; the bus is a consumer of kinds, not their home.

/// How a resource changed.
public enum ChangeKind: String, Sendable {
    case created, updated, deleted
}

/// A thin, serializable description of one resource change. Emitted by the
/// store at the method-atomic write seam (`mutate()`), and by the cross-process
/// bridge as a coarse "reload everything" event. Events are *hints*:
/// subscribers (the File Provider signaler, the model's reload path) react to
/// them, but the authoritative change-detection token is still
/// `GRDBWikiStore.changeToken()`.
///
/// `kind` is optional: a `nil` kind means a coarse, whole-wiki change (the
/// Darwin notification carries no per-resource detail), which only matches
/// all-events (nil-filtered) subscribers. A concrete kind matches its own
/// kind-filtered subscribers plus all-events subscribers.
///
/// `seq` is a bus-stamped, monotonically increasing sequence number owned by
/// `WikiEventBus.emit` (callers pass `0`; the bus overwrites it on delivery).
/// It is present but unconsumed (reserved for the future daemon resync
/// handshake — §3 decision 2).
///
/// **Phase E:** the `origin` field (`.local` / `.external`) is removed. The
/// model now subscribes to ALL events and reloads through the bus for both
/// in-app writes and cross-process (`wikictl`) writes — one path, not two.
public struct ResourceChangeEvent: Sendable, Equatable {
    public let wikiID: String
    public let kind: ResourceKind?
    public let id: String
    public let change: ChangeKind
    public let seq: UInt64

    public init(
        wikiID: String,
        kind: ResourceKind?,
        id: String,
        change: ChangeKind,
        seq: UInt64 = 0
    ) {
        self.wikiID = wikiID
        self.kind = kind
        self.id = id
        self.change = change
        self.seq = seq
    }
}

/// Opaque handle returned by ``WikiEventBus/subscribe(_:_:)``; pass it to
/// ``WikiEventBus/unsubscribe(_:)`` to stop delivery. Unique per subscription.
public struct SubscriptionToken: Sendable, Hashable {
    let id: UUID
    /// Internal so tests can mint an unregistered token to assert that
    /// `unsubscribe` is a safe no-op for unknown ids.
    init() { self.id = UUID() }
}

/// A per-wiki resource-change event bus (`plans/architecture-roadmap.md` §3 —
/// "one signal, four hosts"). `GRDBWikiStore` emits one
/// ``ResourceChangeEvent`` per public mutating method (outside its recursive
/// lock, via the `mutate()` seam), and the cross-process `WikiChangeBridge`
/// emits a coarse event as a Darwin-notification adapter. The File Provider
/// signaler and the model are both **subscribers** on this one mechanism —
/// the model reloads on every event (Phase E), whether the write originated
/// in-app or cross-process.
///
/// **Threading.** `emit` is thread-safe: an internal `NSLock` guards the
/// subscriber registry and the monotone `seq`. `emit` snapshots the matching
/// handlers under the lock, releases it, then dispatches each `@MainActor`
/// handler via `Task { @MainActor in handler(event) }`. This is a single,
/// trap-free path — `emit` never assumes it is already on the main actor (no
/// `MainActor.assumeIsolated`), so it is robust to a future off-main store
/// writer without a strategy switch. Delivery is async-by-a-runloop-tick
/// (acceptable — both consumers are already deferred: the FP signal is
/// debounced; the model's reload is a list-projection refresh that never
/// touches the editor draft). Because handlers run only after `emit`, which
/// fires after the store's `mutate()` depth-0 unlock (post-commit),
/// subscribers always read **committed** state.
public final class WikiEventBus: @unchecked Sendable {
    /// The wiki this bus belongs to. Stamped onto every emitted event so a
    /// subscriber does not need to carry the id separately. The store reads it
    /// when building events.
    public let wikiID: String

    private typealias Handler = @MainActor @Sendable (ResourceChangeEvent) -> Void

    private let lock = NSLock()
    /// Subscriber registry: `id → (kindFilter, handler)`. A `nil` kindFilter
    /// means "all kinds" (also the only subscribers that receive coarse,
    /// `kind == nil` events). Guarded by `lock`.
    private var subscribers: [UUID: (ResourceKind?, Handler)] = [:]
    /// Monotone per-emit counter, stamped onto each delivered event's `seq`.
    /// Guarded by `lock`.
    private var seqCounter: UInt64 = 0

    public init(wikiID: String) {
        self.wikiID = wikiID
    }

    /// Register `handler` for events matching `kind` (`nil` = all kinds).
    /// Returns a token to pass to ``unsubscribe(_:)``. The handler always runs
    /// on the main actor (dispatched via `Task`).
    @discardableResult
    public func subscribe(
        _ kind: ResourceKind?,
        _ handler: @escaping @MainActor (ResourceChangeEvent) -> Void
    ) -> SubscriptionToken {
        lock.lock()
        defer { lock.unlock() }
        let token = SubscriptionToken()
        subscribers[token.id] = (kind, handler)
        return token
    }

    /// Stop delivery for a previously-returned token. Safe to call with an
    /// already-removed/unknown token (no-op).
    public func unsubscribe(_ token: SubscriptionToken) {
        lock.lock()
        defer { lock.unlock() }
        subscribers[token.id] = nil
    }

    /// Stamp `seq`, snapshot the matching handlers, then dispatch each to the
    /// main actor via `Task { @MainActor }`. The async hop is load-bearing: it
    /// guarantees handlers never run inside the store's write closure (emit
    /// fires post-commit, and the Task can only land after the write returns),
    /// so a subscriber's read always sees committed state without re-entering
    /// the serial queue. This also matches the behavior #596/#591 validated.
    public func emit(_ event: ResourceChangeEvent) {
        lock.lock()
        seqCounter &+= 1
        let stamped = ResourceChangeEvent(
            wikiID: event.wikiID,
            kind: event.kind,
            id: event.id,
            change: event.change,
            seq: seqCounter
        )
        let snapshot = Array(subscribers.values)
        lock.unlock()

        for (kindFilter, handler) in snapshot {
            // A nil filter matches everything. A concrete filter matches only
            // its own kind — so a coarse (`kind == nil`) event reaches only
            // nil-filter (all-events) subscribers.
            if let kindFilter, kindFilter != stamped.kind { continue }
            Task { @MainActor in handler(stamped) }
        }
    }
}
