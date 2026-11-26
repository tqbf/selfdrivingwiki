#if os(macOS)
import Foundation

// Phase 3 slice 2 (plans/daemon-only-access.md 3.2): the REGISTRY EVENT
// CONTRACT the daemon pushes through `WikiDaemonEventSink.deliverEvent` on
// the SAME firehose channel as queue/chat/store envelopes, one envelope per
// daemon-side `wikis.json` mutation (create / rename / delete + the legacy
// v0 import landing). The payload carries `{kind, wikiID, displayName?}`.
//
// MARK: Envelope discrimination (how the app's decoder distinguishes)
//
// The firehose now carries three JSON grammars, pairwise two-way disjoint by
// REQUIRED keys (a decoder may dispatch by marker check or by try-decode
// order — both deterministic):
//
// - `QueueEventEnvelope` (WikiFSEngine): requires a top-level `kind` key.
// - `DaemonStoreEventEnvelope` (DaemonStoreEventsWire): requires top-level
//   `wire` + `event`, and the inner `DaemonStoreEvent` requires
//   `epoch`/`sequence`/`changeToken`/`batch`.
// - `DaemonRegistryEventEnvelope` (this file): requires top-level `wire` +
//   `event`, and the inner `DaemonRegistryEvent` requires `kind` NESTED
//   inside `event` (no top-level `kind`) and has no `epoch` field.
//
// Concretely: a registry envelope fails the queue decode (no top-level
// `kind`) and the store decode (`event.kind` is not a `DaemonStoreEvent`
// field — `epoch` is required and missing). A store envelope fails the
// registry decode (`kind` required, missing). A queue envelope fails both
// (no `wire`). The marker VALUE differs from the store marker, so a marker
// check alone routes correctly too. Old clients (the app's workload sink)
// fail every non-queue payload decode and drop them harmlessly — the
// introduction is backward-compatible, exactly like the store envelope was.
//
// No watermark machinery: a registry event is self-validating — the client
// answers it by re-reading the whole `wikis.json` (its cache refresh), so a
// dropped or duplicated envelope costs one missed or idempotent reload, and
// reconciliation needs no sequence. Registry changes landing before a sink's
// handshake are covered by the client's bootstrap read (and the reload after
// every lifecycle reply), not by replay.

public enum DaemonRegistryEventWire {
    /// The top-level discriminator value carried on the registry envelope's
    /// `wire` key. Versioned: a future wire revision mints a new marker so
    /// decoders can reject unknown revisions explicitly.
    public static let marker = "wikid.registry-event.v1"
}

// MARK: - Registry change event (one envelope per registry mutation)

/// What happened to the registry row. `created` and `renamed` carry the
/// display name; `deleted` does not (the row is gone).
public enum DaemonRegistryEventKind: String, Codable, Sendable {
    /// A wiki row was added (daemon create, legacy v0 import landing).
    case created
    /// A wiki row's display name changed. Identity (the ULID) never changes.
    case renamed
    /// A wiki row was removed (daemon delete).
    case deleted
}

/// The daemon-stamped registry change payload.
public struct DaemonRegistryEvent: Codable, Equatable, Sendable {
    public let kind: DaemonRegistryEventKind
    /// The wiki the mutation touched (raw WikiID ULID string).
    public let wikiID: String
    /// The display name after the mutation (`created`/`renamed`); `nil` for
    /// `deleted`. Informational — the authoritative name is the file the
    /// client re-reads.
    public let displayName: String?

    public init(
        kind: DaemonRegistryEventKind, wikiID: String, displayName: String?
    ) {
        self.kind = kind
        self.wikiID = wikiID
        self.displayName = displayName
    }
}

/// The discriminated envelope for registry change events on the
/// `deliverEvent` firehose. See the module header for the exact
/// discrimination contract against `QueueEventEnvelope` and
/// `DaemonStoreEventEnvelope`.
public struct DaemonRegistryEventEnvelope: Codable, Equatable, Sendable {
    /// Always ``DaemonRegistryEventWire/marker``; the discriminator.
    public let wire: String
    public let event: DaemonRegistryEvent

    public init(event: DaemonRegistryEvent) {
        self.wire = DaemonRegistryEventWire.marker
        self.event = event
    }
}
#endif
