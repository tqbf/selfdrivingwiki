#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

// Phase 2c (plans/daemon-only-access.md): the daemon-side coordinator for the
// store EVENT CONTRACT. One instance per WikiDaemon (created in both inits
// with the daemon's claimed epoch), it owns the per-(epoch, wiki) delivery
// state machine that turns the store's local `WikiEventBus` emissions into
// acknowledged, sequence-stamped `deliverEvent` envelopes:
//
// - Attach: every PREPARED wiki's bus is subscribed exactly once, at the
//   mandatory-bus choke point (`WikiDaemon.wireEventBus` — the same seam the
//   DarwinNotifier bridge rides), so a wiki prepared AFTER a sink registered
//   starts flowing the moment it prepares. Detach mirrors the six
//   `openStores` removal sites (close vs delete — see ``closeWikiDelivery`` /
//   ``forgetWikiDelivery``).
// - Stamp: each emitted `ResourceChangeEvent` batch carries
//   `{epoch, sequence, changeToken, batch}`. `sequence` is the wiki's
//   DELIVERY counter for this epoch — monotonic per wiki, shared across
//   sinks, surviving store close/reopen, resetting only when the epoch
//   changes (daemon restart). The changeToken is read by the caller at
//   delivery time (a cheap bounded fold outside any write — never inside the
//   store's `mutate()`).
// - Deliver: live (handshaken) sinks receive every event. Events stamped
//   while NO sink is live stay in a bounded per-wiki replay ring
//   (``DaemonStoreLimits/sinkEventBufferCapacity``, oldest dropped with a
//   log); a sink's `sinkHandshake` replays the survivors with
//   `sequence >` the handshake's `lastSequence` and flips it live. A sink
//   that registers while another sink is already live receives nothing
//   replayed — those commits were delivered (they raised the watermark) —
//   and reconciles the difference through its handshake `changeToken`.
//
// Concurrency: one NSLock guards all state AND delivery. Delivering under
// the lock is deliberate: bus handlers dispatch on the main actor while
// handshakes run on the executor path, and per-sink sequence order across
// the flush/live boundary must not depend on which thread wins the race.
// `deliverEvent` is a fire-and-forget XPC proxy send (never re-enters this
// lock); callers pass the sink proxies IN so no code path under the lock
// touches the daemon queue (the daemon queue → coordinator lock ordering is
// the only nesting that exists).
//
// Sendable invariant: all mutable fields are NSLock-guarded; the sink
// proxies crossing the API are `@objc` XPC proxies (the daemon already holds
// them strongly and calls them from arbitrary threads).
// swiftlint:disable:next unchecked_sendable
final class DaemonStoreEventCoordinator: @unchecked Sendable {

    /// The epoch this coordinator stamps envelopes with — the owning
    /// daemon's claimed value. A restarted daemon creates a fresh
    /// coordinator (and epoch), which is what makes a lower restart
    /// sequence unambiguous.
    let epoch: UInt64

    private enum SinkPhase {
        /// Registered, handshake not yet completed: events buffer in the
        /// per-wiki ring for this sink's post-handshake replay.
        case awaitingHandshake
        /// Handshake completed: every event is delivered as it stamps.
        case live
    }

    private struct WikiDeliveryState {
        weak var bus: WikiEventBus?
        var subscription: SubscriptionToken?
        /// The per-(epoch, wiki) delivery counter: incremented per stamped
        /// envelope. Starts at 0; the first stamp is sequence 1.
        var stampCounter: UInt64 = 0
        /// The highest sequence delivered to some live sink on this wiki.
        /// The handshake reply reports this value per wiki.
        var deliveredWatermark: UInt64 = 0
        /// Bounded replay ring in sequence order (oldest first).
        var ring: [DaemonStoreEvent] = []
    }

    private let lock = NSLock()
    private var sinkPhases: [UUID: SinkPhase] = [:]
    private var wikis: [String: WikiDeliveryState] = [:]

    init(epoch: UInt64) {
        self.epoch = epoch
    }

    // MARK: - Sink lifecycle (forwarded from WikiDaemon's registry)

    /// A sink proxy registered on some connection. It buffers until its
    /// handshake completes.
    func sinkRegistered(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        sinkPhases[id] = .awaitingHandshake
    }

    /// A sink's connection invalidated. Its phase disappears; the ring is
    /// intentionally kept — it is the wiki's recent-event history, bounded,
    /// and serves the NEXT sink's handshake.
    func sinkUnregistered(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        sinkPhases[id] = nil
    }

    // MARK: - Bus attach/detach (the WikiDaemon prepare/evict seams)

    /// Record the subscription created for a prepared wiki's bus. Called
    /// from `wireEventBus` (the mandatory-bus choke point) right after the
    /// handler is installed. Re-attach overwrites the previous bus/token
    /// references (one store per wiki at a time) while KEEPING the counters
    /// — sequences survive a close/reopen within one daemon by contract.
    func attach(wikiID: WikiID, bus: WikiEventBus, token: SubscriptionToken) {
        lock.lock()
        defer { lock.unlock() }
        var state = wikis[wikiID.rawValue] ?? WikiDeliveryState()
        state.bus = bus
        state.subscription = token
        wikis[wikiID.rawValue] = state
    }

    /// Close-only detach (client `closeStore`, idle close): stop delivery
    /// and drop the bus/token references, but keep the counters and ring —
    /// a re-prepared wiki continues this epoch's sequence, never a restart.
    func closeWikiDelivery(_ wikiID: WikiID) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = wikis[wikiID.rawValue] else { return }
        if let bus = state.bus, let token = state.subscription {
            bus.unsubscribe(token)
        }
        state.bus = nil
        state.subscription = nil
        wikis[wikiID.rawValue] = state
    }

    /// Deletion detach (wiki removed from the registry + disk): additionally
    /// drop the whole per-wiki state. Wiki ids are ULIDs, so a recreated
    /// wiki is a fresh id with fresh state either way.
    func forgetWikiDelivery(_ wikiID: WikiID) {
        lock.lock()
        defer { lock.unlock() }
        if let state = wikis[wikiID.rawValue] {
            if let bus = state.bus, let token = state.subscription {
                bus.unsubscribe(token)
            }
        }
        wikis[wikiID.rawValue] = nil
    }

    // MARK: - Bus ingest (main actor, from the wireEventBus handler)

    /// Stamp one emitted `ResourceChangeEvent`, retain it in the wiki's
    /// ring, and deliver the envelope to every LIVE sink. The caller read
    /// the change token at delivery time; a failed read passes the sentinel
    /// (``WikiDaemon/errorTokenSentinel``) — the envelope still carries the
    /// event, and the sentinel never matches a cached anchor, so the client
    /// treats it as changed.
    ///
    /// Returns the number of live deliveries made (diagnostics/tests).
    @discardableResult
    func ingest(
        event: ResourceChangeEvent,
        changeToken: String?,
        proxies: [(id: UUID, sink: WikiDaemonEventSink)]
    ) -> Int {
        let mirror = DaemonStoreCommandExecutor.mirrorEvent(event)
        lock.lock()
        defer { lock.unlock() }
        let key = event.wikiID.rawValue
        var state = wikis[key] ?? WikiDeliveryState()
        state.stampCounter &+= 1
        let envelope = DaemonStoreEventEnvelope(event: DaemonStoreEvent(
            epoch: epoch,
            wikiID: key,
            sequence: state.stampCounter,
            changeToken: changeToken ?? "",
            batch: [mirror]))
        state.ring.append(envelope.event)
        if state.ring.count > DaemonStoreLimits.sinkEventBufferCapacity {
            state.ring.removeFirst(state.ring.count
                - DaemonStoreLimits.sinkEventBufferCapacity)
            DebugLog.store(
                "wikid: store event ring overflow for wiki \(key) — "
                    + "dropped the oldest entry (bounded replay buffer)")
        }
        var delivered = 0
        for proxy in proxies where sinkPhases[proxy.id] == .live {
            deliver(envelope, to: proxy.sink)
            delivered += 1
        }
        if delivered > 0 {
            state.deliveredWatermark = state.stampCounter
        }
        wikis[key] = state
        return delivered
    }

    /// Test-support: the ingested stamp counter for one wiki (0 when the
    /// wiki has no delivery state yet). Ingest rides the bus's async
    /// handler tasks, so a commit returning does NOT mean its stamp landed;
    /// tests asserting exact ring contents wait on this counter.
    func ingestedSequenceCount(wikiID: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return wikis[wikiID]?.stampCounter ?? 0
    }

    // MARK: - Registry events (Phase 3 slice 2)

    /// Deliver one registry-event envelope to every LIVE sink. Registry
    /// events carry no watermark machinery: they are self-validating — the
    /// client answers one by re-reading the whole `wikis.json` (its cache
    /// refresh) — so a dropped or duplicated envelope costs one missed or
    /// idempotent reload, never stale-writes. Registry changes that land
    /// before a sink's handshake are NOT replayed: the client's bootstrap
    /// read plus the reload after every lifecycle reply reconcile them.
    ///
    /// Callers pass the sink proxies IN (same discipline as ``ingest``: no
    /// code path under the lock touches the daemon queue).
    ///
    /// Returns the number of live deliveries made (diagnostics/tests).
    @discardableResult
    func deliverRegistryEvent(
        _ event: DaemonRegistryEvent,
        proxies: [(id: UUID, sink: WikiDaemonEventSink)]
    ) -> Int {
        let envelope = DaemonRegistryEventEnvelope(event: event)
        lock.lock()
        defer { lock.unlock() }
        var delivered = 0
        for proxy in proxies where sinkPhases[proxy.id] == .live {
            deliverRegistry(envelope, to: proxy.sink)
            delivered += 1
        }
        return delivered
    }

    /// Fire-and-forget registry delivery. MUST hold `lock` (same rationale as
    /// ``deliver`` — the XPC proxy send never re-enters this lock).
    private func deliverRegistry(
        _ envelope: DaemonRegistryEventEnvelope, to sink: WikiDaemonEventSink
    ) {
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            // Encode of this fixed-shape value cannot fail; a failure would
            // lose exactly one refresh signal, which the client's next reload
            // covers — but it must be visible.
            DebugLog.store(
                "wikid: registry event envelope encode failed: \(error)")
            return
        }
        sink.deliverEvent(data)
    }

    // MARK: - Handshake (executor path)

    /// Complete one sink's handshake: snapshot every prepared wiki's
    /// `lastSequence` (the delivery watermark at handshake time), replay the
    /// surviving ring entries with `sequence > lastSequence` to THIS sink,
    /// and flip it live. The caller supplies the prepared wiki ids (from the
    /// daemon's store cache) and the registered sink proxies.
    ///
    /// Returns the per-wiki `lastSequence` map for the reply (a wiki with no
    /// state answers 0). Without a registered sink id (e.g. a socket-path
    /// handshake, where no reverse-push channel exists yet) the watermarks
    /// are still answered but nothing flips and nothing replays.
    func completeHandshake(
        sinkID: UUID?,
        preparedWikiIDs: [String],
        proxies: [(id: UUID, sink: WikiDaemonEventSink)]
    ) -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }

        // Watermarks for the reply: the delivery counter at handshake time.
        var lastSequence: [String: UInt64] = [:]
        for wikiID in preparedWikiIDs {
            lastSequence[wikiID] = wikis[wikiID]?.deliveredWatermark ?? 0
        }

        guard let sinkID,
              let proxy = proxies.first(where: { $0.id == sinkID }),
              sinkPhases[sinkID] != nil else {
            return lastSequence
        }
        // Replay THIS sink's gap from the bounded ring, in sequence order,
        // then flip live — all under the same lock as live delivery, so a
        // concurrent commit cannot interleave between the replay and the
        // live stream (per-sink ordering is total).
        for wikiID in preparedWikiIDs.sorted() {
            guard var state = wikis[wikiID] else { continue }
            let replay = state.ring.filter {
                $0.sequence > (lastSequence[wikiID] ?? 0)
            }
            for stamped in replay {
                deliver(
                    DaemonStoreEventEnvelope(event: stamped), to: proxy.sink)
            }
            if let highest = replay.last?.sequence,
               highest > state.deliveredWatermark {
                state.deliveredWatermark = highest
            }
            wikis[wikiID] = state
        }
        sinkPhases[sinkID] = .live
        return lastSequence
    }

    // MARK: - Internals

    /// Fire-and-forget delivery. MUST hold `lock`. The XPC proxy send is
    /// async under the hood and never re-enters this lock; test doubles are
    /// synchronous bookkeeping.
    private func deliver(
        _ envelope: DaemonStoreEventEnvelope, to sink: WikiDaemonEventSink
    ) {
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            // Encode of this fixed-shape value cannot fail; a failure would
            // lose exactly one event, which the client's change-token
            // reconciliation covers — but it must be visible.
            DebugLog.store(
                "wikid: store event envelope encode failed: \(error)")
            return
        }
        sink.deliverEvent(data)
    }
}
#endif
