#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

// Phase 3 slice 2 (plans/daemon-only-access.md 3.2): the daemon-mediated
// registry plumbing. Two pieces:
//
// - ``DaemonWikiRegistryInvoker`` — the production ``WikiRegistryDaemonInvoker``
//   conformer: it routes `WikiRegistryClient`'s lifecycle ops over the app's
//   XPC connection (``WikiDaemonConnection``), onto the daemon's EXISTING
//   wiki family (`WikiDaemonProtocol.createWiki` / `.renameWiki` /
//   `.deleteWiki`). The app composition injects it (plus
//   `accessMode: .remote` from `StoreModeConfiguration.resolvedMode`) when it
//   constructs the registry client — the same live-object injection pattern
//   as `makeDaemonTransport`.
// - ``DaemonRegistryEventFeed`` — the registry slice of the daemon's event
//   firehose: it decodes ONLY `wikid.registry-event.v1` payloads and answers
//   each with ``WikiRegistryClient/reloadFromDisk()`` (the read cache's
//   refresh). Queue, chat, and store envelopes fail the decode — the three
//   grammars are pairwise two-way disjoint (see
//   `DaemonRegistryEventsWire.swift`) — so the feed can sit alongside the
//   workload sink and the store sink on the same channel without misrouting.

/// The XPC adapter between ``WikiRegistryClient`` and the daemon's wiki
/// lifecycle family. All three ops map one-to-one onto
/// ``WikiDaemonConnection``'s existing async methods.
public struct DaemonWikiRegistryInvoker: WikiRegistryDaemonInvoker {
    /// The app's daemon connection. `WikiDaemonConnection` is `@unchecked
    /// Sendable` (thread-safe XPC proxy access), so holding it here keeps the
    /// invoker `Sendable` for the client's `@MainActor` call sites.
    private let connection: WikiDaemonConnection

    public init(connection: WikiDaemonConnection) {
        self.connection = connection
    }

    public func createWiki(name: String) async throws -> WikiDescriptor {
        try await connection.createWiki(name: name)
    }

    public func renameWiki(id: WikiID, to name: String) async throws -> Bool {
        try await connection.renameWiki(id: id, name: name)
    }

    public func deleteWiki(id: WikiID) async throws -> Bool {
        try await connection.deleteWiki(id: id)
    }
}

/// Routes daemon firehose payloads into the registry client's read cache.
/// Stateless: one call per delivered payload, safe from any actor that hops
/// to the main actor for the client.
public enum DaemonRegistryEventFeed {

    /// Decode one firehose payload; a registry event refreshes the client's
    /// cache via ``WikiRegistryClient/reloadFromDisk()``. Returns the decoded
    /// event, or `nil` when the payload is not a registry envelope (a queue,
    /// chat, or store payload — the disjoint grammars make the miss
    /// deterministic, and the caller's own decoder owns those).
    ///
    /// Main-actor because ``WikiRegistryClient`` is `@MainActor`; a firehose
    /// delivery arrives on an XPC-internal queue, so the app wiring hops.
    @MainActor
    @discardableResult
    public static func route(
        _ payload: Data, into registry: WikiRegistryClient
    ) -> DaemonRegistryEvent? {
        // The decode MISS is the discrimination contract: a non-registry
        // payload is a no-op, not an error to surface.
        // swiftlint:disable:next silent_try_optional
        guard let envelope = try? JSONDecoder().decode(
            DaemonRegistryEventEnvelope.self, from: payload),
            envelope.wire == DaemonRegistryEventWire.marker
        else {
            return nil
        }
        registry.reloadFromDisk()
        return envelope.event
    }
}
#endif
