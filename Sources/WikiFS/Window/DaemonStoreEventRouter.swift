#if os(macOS)
import Foundation
import WikiCtlCore
import WikiDaemonContract
import WikiFSCore

// Phase 3 slice 3 (plans/daemon-only-access.md 3.2 + 2c): the app's
// store-connection event sink. The remote store connection's daemon-side
// exporter holds ONE sink per XPC connection and pushes the whole firehose
// to it — store-commit envelopes (`wikid.store-event.v1`) AND registry
// envelopes (`wikid.registry-event.v1`). This router is the app-side demux:
//
// - Every open wiki session's `RemoteWikiStore` registers here when the
//   session factory constructs it; each delivered payload is handed to
//   every live store, whose own envelope decode (two-way disjoint
//   grammars) drops what is not a store event. The stores are held WEAKLY:
//   the sessions own them; a closed session's store drops out lazily.
// - Registry envelopes hop to the main actor and route through
//   ``DaemonRegistryEventFeed`` into the `WikiRegistryClient` read cache
//   (`reloadFromDisk`). A store payload fails that decode (no-op), and a
//   registry payload fails the stores' decode (no-op) — the dispatch is
//   deterministic in both directions.
//
// Registered on the store connection immediately after it opens (see
// `WikiDaemonConnection.registerEventSink`): same-connection messages
// deliver in issue order, so the sink is in the exporter's table before the
// first store handshake correlates it and flips it live.
//
// Sendable: `deliverEvent` arrives on an XPC-internal queue; the store set
// is NSLock-guarded, each store's `deliverEvent` is internally lock-guarded,
// and the registry leg hops to the main actor (the client is `@MainActor`).
final class DaemonStoreEventRouter: NSObject, WikiDaemonEventSink,
    // swiftlint:disable:next unchecked_sendable
    @unchecked Sendable {
    /// Weak boxes for the per-wiki session stores (the sessions own them).
    private struct StoreBox {
        weak var store: RemoteWikiStore?
    }

    private let lock = NSLock()
    private var stores: [ObjectIdentifier: StoreBox] = [:]
    private let registry: WikiRegistryClient

    init(registryClient: WikiRegistryClient) {
        self.registry = registryClient
    }

    /// Called by the session factory when it constructs a wiki's
    /// `RemoteWikiStore`, so this connection's single sink fans every
    /// delivery out to it. Closed sessions drop out lazily on the next
    /// delivery (weak boxes nil out — no explicit unregister hook exists on
    /// the factory seam).
    func register(store: RemoteWikiStore) {
        lock.withLock { stores[ObjectIdentifier(store)] = StoreBox(store: store) }
    }

    func deliverEvent(_ payload: Data) {
        // Store leg: synchronous, thread-safe, decode-miss = no-op per
        // store (each store only consumes its own grammar, and within it,
        // its own wiki + watermarks).
        let liveStores = lock.withLock {
            stores.values.compactMap(\.store)
        }
        for store in liveStores {
            store.deliverEvent(payload)
        }
        // Registry leg: the client is `@MainActor`, so this hops. Registry
        // events are self-validating (each one answers with a full cache
        // re-read), so delivery ordering and duplication cost nothing.
        let registry = self.registry
        Task { @MainActor in
            DaemonRegistryEventFeed.route(payload, into: registry)
        }
    }
}
#endif
