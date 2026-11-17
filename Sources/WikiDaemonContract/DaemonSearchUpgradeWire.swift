#if os(macOS)
import Foundation

// Phase 5 (plans/daemon-only-access.md 5.2): the search-upgrade PROGRESS
// contract the daemon pushes through `WikiDaemonEventSink.deliverEvent` while
// the daemon-side embedding backfill runs, plus the start operation's
// request/reply payloads (`upgradeSearchIndex`, the `.events` family tier
// beside `sinkHandshake` — a daemon-scoped workload, not a `WikiStore`
// requirement; the app's `RemoteWikiStore` carries the typed client seam).
//
// MARK: Envelope discrimination (the 2c envelope pattern)
//
// `deliverEvent` payloads are JSON. The established firehose grammars are
// pairwise two-way disjoint:
//
// - `QueueEventEnvelope` (WikiFSEngine): required top-level `kind` key.
// - `DaemonStoreEventEnvelope`: `wire` marker `wikid.store-event.v1`, no
//   `kind` key.
// - `DaemonRegistryEventEnvelope`: `wire` marker `wikid.registry-event.v1`.
// - THIS envelope: `wire` marker ``DaemonSearchUpgradeEventWire/marker``
//   (`wikid.search-upgrade-event.v1`), no `kind` key. The marker VALUE is
//   the discriminator — a client checking `wire` decodes the matching
//   envelope type and ignores every other grammar deterministically.
//
// Progress is DELIVERY-ONLY: the upgrade is a daemon workload, not a store
// commit, so envelopes carry NO epoch/sequence watermark and take no part in
// the store handshake's replay ring. A sink that misses events (registered
// mid-run) sees only the later ones; the run's `complete`/`failed` terminal
// state is what the client's sheet state machine resolves on, and a
// re-trigger (`upgradeSearchIndex`) re-reports the current totals.

public enum DaemonSearchUpgradeEventWire {
    /// The top-level discriminator value carried on the envelope's `wire`
    /// key. Versioned: a future wire revision mints a new marker so decoders
    /// can reject unknown revisions explicitly.
    public static let marker = "wikid.search-upgrade-event.v1"
}

/// One search-upgrade progress step (or its terminal state) for one wiki.
/// `total`/`phase`/`done` mirror the app's `SearchUpgradeState` fields so the
/// sheet state machine is a direct projection.
public struct DaemonSearchUpgradeEvent: Codable, Equatable, Sendable {
    /// The wiki the backfill runs against (raw WikiID ULID string).
    public let wikiID: String
    /// Which work tier the current progress is inside. Matches
    /// `SearchUpgradeState.Phase` (`pages` → `sources` → `chats`).
    public enum Phase: String, Codable, Sendable {
        case pages, sources, chats
    }
    /// The run's terminal state: `running` while work remains, then exactly
    /// one of `complete` / `failed`.
    public enum State: String, Codable, Sendable {
        case running, complete, failed
    }
    public let phase: Phase
    /// Items finished so far in the whole run (monotone across phases).
    public let done: Int
    /// Total items the run's missing-work scan found (fixed per run).
    public let total: Int
    public let state: State

    public init(
        wikiID: String, phase: Phase, done: Int, total: Int, state: State
    ) {
        self.wikiID = wikiID
        self.phase = phase
        self.done = done
        self.total = total
        self.state = state
    }
}

/// The discriminated envelope for search-upgrade progress on the
/// `deliverEvent` firehose. See the module header for the discrimination
/// contract against the other firehose grammars.
public struct DaemonSearchUpgradeEventEnvelope: Codable, Equatable, Sendable {
    /// Always ``DaemonSearchUpgradeEventWire/marker``; the discriminator.
    public let wire: String
    public let event: DaemonSearchUpgradeEvent

    public init(event: DaemonSearchUpgradeEvent) {
        self.wire = DaemonSearchUpgradeEventWire.marker
        self.event = event
    }
}

// MARK: - `upgradeSearchIndex` start operation (`.events` family tier)

/// The `upgradeSearchIndex` request payload. Deliberately EMPTY: the wiki id
/// rides the store request envelope (like every store-family op), so a
/// wiki-filtered payload would be a second way to be wrong.
public struct DaemonSearchUpgradeStartRequest: Codable, Equatable, Sendable {
    public init() {}
}

/// What the daemon did with a start request.
public enum DaemonSearchUpgradeStartOutcome: String, Codable, Equatable,
    Sendable {
    /// The backfill started (or was already running — the reply reports the
    /// current run). Progress events follow on the firehose.
    case started
    /// The embedder is available but the missing-work scan found nothing.
    /// No events are emitted for this wiki.
    case notNeeded
    /// No embedder is loaded in the daemon (no bundled model). No events.
    case embedderUnavailable
}

public struct DaemonSearchUpgradeStartReply: Codable, Equatable, Sendable {
    public let outcome: DaemonSearchUpgradeStartOutcome
    /// The run's scanned total when `started` (a re-trigger reports the
    /// current run's total); the missing-work count when `notNeeded`; 0 for
    /// `embedderUnavailable`.
    public let total: Int

    public init(outcome: DaemonSearchUpgradeStartOutcome, total: Int) {
        self.outcome = outcome
        self.total = total
    }
}
#endif
