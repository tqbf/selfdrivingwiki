import Foundation

// `ResourceKind` (and the `Resource` / `ChangeTokenContributor` abstractions)
// now live in `Resource.swift` (slice 2b) next to the access layer that owns
// them; the bus is a consumer of kinds, not their home.

/// How a resource changed.
public enum ChangeKind: String, Sendable {
    case created, updated, deleted
}

/// Where a change originated. `.local` = an in-app store write (the app's own
/// process). `.external` = a cross-process write (`wikictl`), surfaced by the
/// Darwin-notification change bridge as a coarse "reload everything" event.
///
/// `origin` is a **transitional field**: it exists only because slice 2a keeps
/// the model self-managing on its own writes (it subscribes `.external`→reload,
/// ignores `.local`; the File Provider subscribes to both). Once the model
/// becomes a pure reload subscriber on ALL events (slice 2b), `origin` is
/// removed and the event shape matches §3 decision 2's
/// `(wiki, seq, kind, id, change)` exactly.
public enum EventOrigin: String, Sendable {
    case local, external
}

/// A thin, serializable description of one resource change. Emitted by the
/// store at the method-atomic write seam (`mutate()`), and by the cross-process
/// bridge as a coarse `.external` event. Events are *hints*: subscribers (the
/// File Provider signaler, the model's external-reload path) react to them, but
/// the authoritative change-detection token is still `SQLiteWikiStore.changeToken()`.
///
/// `kind` is optional: a `nil` kind means a coarse, whole-wiki change (the
/// Darwin notification carries no per-resource detail), which only matches
/// all-events (nil-filtered) subscribers. A concrete kind matches its own
/// kind-filtered subscribers plus all-events subscribers.
///
/// `seq` is a bus-stamped, monotonically increasing sequence number owned by
/// `WikiEventBus.emit` (callers pass `0`; the bus overwrites it on delivery).
/// It is present but unconsumed in slice 2a (reserved for the future daemon
/// resync handshake — §3 decision 2).
public struct ResourceChangeEvent: Sendable, Equatable {
    public let wikiID: String
    public let kind: ResourceKind?
    public let id: String
    public let change: ChangeKind
    public let origin: EventOrigin
    public let seq: UInt64

    public init(
        wikiID: String,
        kind: ResourceKind?,
        id: String,
        change: ChangeKind,
        origin: EventOrigin,
        seq: UInt64 = 0
    ) {
        self.wikiID = wikiID
        self.kind = kind
        self.id = id
        self.change = change
        self.origin = origin
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
/// "one signal, four hosts"). `SQLiteWikiStore` emits one
/// ``ResourceChangeEvent`` per public mutating method (outside its recursive
/// lock, via the `mutate()` seam), and the cross-process `WikiChangeBridge`
/// emits a coarse `.external` event as a Darwin-notification adapter. The File
/// Provider signaler and the model both become **subscribers** on this one
/// mechanism.
///
/// **Threading.** `emit` is thread-safe: an internal `NSLock` guards the
/// subscriber registry and the monotone `seq`. `emit` snapshots the matching
/// handlers under the lock, releases it, then dispatches each `@MainActor`
/// handler via `Task { @MainActor in handler(event) }`. This is a single,
/// trap-free path — `emit` never assumes it is already on the main actor (no
/// `MainActor.assumeIsolated`), so it is robust to a future off-main store
/// writer without a strategy switch. Delivery is async-by-a-runloop-tick
/// (acceptable — both consumers are already deferred: the FP signal is
/// debounced; the model's `.external`→reload mirrors the bridge's existing
/// ~250 ms coalesce). Because handlers run only after `emit`, which fires after
/// the store's `mutate()` depth-0 unlock (post-commit), subscribers always read
/// **committed** state.
public final class WikiEventBus: @unchecked Sendable {
    /// The wiki this bus belongs to. Stamped onto every emitted event so a
    /// subscriber does not need to carry the id separately. The store reads it
    /// when building `.local` events.
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
    /// main actor. Callable from any thread.
    public func emit(_ event: ResourceChangeEvent) {
        lock.lock()
        seqCounter &+= 1
        let stamped = ResourceChangeEvent(
            wikiID: event.wikiID,
            kind: event.kind,
            id: event.id,
            change: event.change,
            origin: event.origin,
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
