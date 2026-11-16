#if os(macOS)
import Foundation

// Phase 2c (plans/daemon-only-access.md): the store EVENT CONTRACT the daemon
// pushes through `WikiDaemonEventSink.deliverEvent`. One JSON envelope per
// store COMMIT carrying `{epoch, wikiID, sequence, changeToken, batch}` plus
// the acknowledged `sinkHandshake` request/repair pair.
//
// MARK: Envelope discrimination (how the app's decoder distinguishes)
//
// `deliverEvent` payloads are JSON. The EXISTING workload payloads are
// `QueueEventEnvelope` objects (WikiFSEngine): every one carries a required
// `kind` key whose value is one of that enum's closed queue/chat raw strings.
// Store change payloads carry the marker key `wire` (value
// ``DaemonStoreEventWire/marker``) and NEVER a `kind` key, so the two JSON
// grammars are disjoint in BOTH directions:
//
// - A store envelope fails `QueueEventEnvelope` decode (`keyNotFound: kind`),
//   which is exactly what today's app sink does — it decodes
//   `QueueEventEnvelope`, logs, and drops. Old clients therefore ignore store
//   events harmlessly: the introduction is backward-compatible.
// - A queue envelope fails `DaemonStoreEventEnvelope` decode (missing
//   `wire` / `event`), so a 2d client may dispatch by try-decode order
//   (queue envelope first, store envelope second) or check the `wire`
//   marker first — both are deterministic; neither can misroute.
//
// The discriminator is deliberately store-only: extending
// `QueueEventEnvelope` with a store kind would have made the queue envelope
// grammar depend on the store slice and touched a file outside the events
// slice's contract surface.

public enum DaemonStoreEventWire {
    /// The top-level discriminator value carried on the store envelope's
    /// `wire` key. Versioned: a future wire revision mints a new marker so
    /// decoders can reject unknown revisions explicitly.
    public static let marker = "wikid.store-event.v1"
}

// MARK: - Store change event (one envelope per commit)

/// The daemon-stamped store change payload: one commit's events with the
/// watermark the client reconciles against (plan 2c epoch-keyed watermarks).
public struct DaemonStoreEvent: Codable, Equatable, Sendable {
    /// The serving daemon's epoch (``WikiDaemonProtocol``-scoped: each daemon
    /// instance claims a globally monotonic value at init). A daemon restart
    /// produces a NEW epoch, so its per-wiki sequence restart is never
    /// mistaken for a duplicate: watermarks are keyed by `(epoch, wikiID)`.
    public let epoch: UInt64
    /// The wiki the commit landed on (raw WikiID ULID string).
    public let wikiID: String
    /// The daemon's per-`(epoch, wikiID)` delivery counter value stamped at
    /// emit time. Monotonic with no gaps per live-delivered event; survives
    /// sinks and store close/reopen within one daemon; resets only when the
    /// epoch changes. Clients drop events with `sequence <=` the epoch's
    /// watermark (idempotent duplicates) and reconcile via `changeToken` when
    /// they observe a sequence gap (bounded-buffer drop, missed delivery).
    public let sequence: UInt64
    /// The wiki's whole-store change token read from the store at DELIVERY
    /// time (cheap bounded fold, never inside the write). The handshake
    /// carries the same shape, so a client reconciles one reload per wiki
    /// when the token advanced past its cached anchor.
    public let changeToken: String
    /// That commit's events in emission order. Today the store emits exactly
    /// one `ResourceChangeEvent` per public mutating method (one commit = one
    /// bus emission), so every delivered batch has one element; the array
    /// keeps the wire shape batch-ready for a future multi-event commit
    /// without a migration.
    public let batch: [DaemonResourceChangeEvent]

    public init(
        epoch: UInt64, wikiID: String, sequence: UInt64,
        changeToken: String, batch: [DaemonResourceChangeEvent]
    ) {
        self.epoch = epoch
        self.wikiID = wikiID
        self.sequence = sequence
        self.changeToken = changeToken
        self.batch = batch
    }
}

/// The discriminated envelope for store change events on the
/// `deliverEvent` firehose. See the module header for the exact
/// discrimination contract against `QueueEventEnvelope`.
public struct DaemonStoreEventEnvelope: Codable, Equatable, Sendable {
    /// Always ``DaemonStoreEventWire/marker``; the discriminator.
    public let wire: String
    public let event: DaemonStoreEvent

    public init(event: DaemonStoreEvent) {
        self.wire = DaemonStoreEventWire.marker
        self.event = event
    }
}

// MARK: - Acknowledged sink handshake (the `sinkHandshake` operation)

/// The `sinkHandshake` request payload. Deliberately EMPTY: the handshake is
/// daemon-scoped (it never resolves a per-wiki store), and the reply already
/// carries every PREPARED wiki, so the client filters locally. A wiki-filtered
/// request would be a second way to be wrong about which wikis a sink covers;
/// the client-side filter over the full reply is strictly more capable.
/// Adding optional fields later is backward-compatible (old clients encode
/// `{}`).
public struct DaemonSinkHandshakeRequest: Codable, Equatable, Sendable {
    public init() {}
}

/// One prepared wiki's reconciliation watermark in a handshake reply.
public struct DaemonSinkHandshakeWatermark: Codable, Equatable, Sendable {
    public let wikiID: String
    /// The wiki's change token at handshake time (the daemon's existing
    /// changeToken fold — the same anchor the File Provider syncs against).
    /// A client compares this against its cached anchor and runs ONE
    /// reconciliation reload if it advanced.
    public let changeToken: String
    /// The daemon's per-`(epoch, wikiID)` DELIVERY counter value at handshake
    /// time: the highest sequence already delivered to some live sink on this
    /// epoch. Events the client has not seen but that were never delivered to
    /// any live sink (because every sink was awaiting this handshake) sit in
    /// the daemon's bounded replay ring and are delivered after the reply
    /// with `sequence > lastSequence` — so nothing is silently lost across
    /// the barrier. Older gaps (ring overflow, pre-registration commits) are
    /// NOT replayed: the client reconciles them through `changeToken`.
    public let lastSequence: UInt64

    public init(wikiID: String, changeToken: String, lastSequence: UInt64) {
        self.wikiID = wikiID
        self.changeToken = changeToken
        self.lastSequence = lastSequence
    }
}

/// The `sinkHandshake` reply: the epoch to stamp mutations against (plan 2a
/// `DaemonMutationStamp.expectedEpoch`) plus one watermark per PREPARED wiki.
/// Wikis not prepared at handshake time are absent — their events flow once
/// the daemon prepares them and the (by then live) sink receives them.
public struct DaemonSinkHandshakeReply: Codable, Equatable, Sendable {
    public let daemonEpoch: UInt64
    /// Sorted by `wikiID` for reply stability.
    public let perWiki: [DaemonSinkHandshakeWatermark]

    public init(daemonEpoch: UInt64, perWiki: [DaemonSinkHandshakeWatermark]) {
        self.daemonEpoch = daemonEpoch
        self.perWiki = perWiki
    }
}
#endif
