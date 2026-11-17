#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSEngine

// Phase 2 item 2e, slice A3 (plans/daemon-only-access.md): the SESSION
// WIRING SEAM for the remote-store composition. Phase 2 development keeps
// the app on the LOCAL store; this seam exists so the REMOTE path composes
// end to end (proven by tests) without flipping any app default.
//
// When the session's underlying store is a ``RemoteWikiStore``:
// 1. The session barrier is forced open NOW (`warmSession`) — the
//    acknowledged handshake + the 2e `sessionBootstrap` round trip apply
//    the daemon-authoritative values into the client's properties before
//    anything reads them.
// 2. The model's registered-inputs / renderer-types are set FROM the
//    client's bootstrap-applied values (never from local services — the
//    daemon is the authority for what ITS workload execution recognizes;
//    the renderer catalog is machine config, intersected with the daemon's
//    mirror by `applyBootstrap`).
// 3. ONE coalesced reload hook is installed: the store fires
//    `onReloadSignal` at most once per staleness detection, and
//    `WikiStoreModel.reloadFromStore()` coalesces overlapping reloads —
//    so a burst of sink events collapses into at most one reload.
//
// When the store is local (today's default), nothing here runs: the
// caller's guarded branch skips this composition and SessionsPlugin's local
// bootstrap keeps setting the model from local services, unchanged.
public enum RemoteStoreSessionComposition {

    /// The seam switch, driven by the launch-fixed `allowLocalStore` mode
    /// (plans/daemon-only-access.md Phase 3 item 1). `.remote` sessions
    /// compose from the daemon's bootstrap payload + one coalesced reload
    /// hook; `.local` (the DEBUG app override / test fixtures) keeps the
    /// local bootstrap everywhere. Like the flag itself this is fixed at
    /// process launch and NEVER a response to daemon failure — a down
    /// daemon never selects the local path.
    public static let enabled = StoreModeConfiguration.resolvedMode == .remote

    /// Compose a booted session for a REMOTE store, when the seam is
    /// enabled and the session's underlying store is a `RemoteWikiStore`.
    /// Local sessions return immediately. A failed session establishment
    /// (daemon unreachable) THROWS — the session open fails explicitly,
    /// never silently degrading to local state.
    @MainActor
    public static func composeIfRemote(_ session: ProfileWikiSession) async throws {
        guard enabled else { return }
        guard let remote = session.store.internalStore as? RemoteWikiStore
        else { return }
        try await compose(model: session.store, remote: remote)
    }

    /// The remote-branch body, callable directly (tests drive it against a
    /// fixture daemon without flipping the app-wide switch).
    @MainActor
    public static func compose(
        model: WikiStoreModel, remote: RemoteWikiStore
    ) async throws {
        // 1. Force the barrier: handshake + bootstrap apply before the
        //    model's reads below. A failure here is the session's failure.
        try await remote.warmSession()
        // 2. Model FROM the client's bootstrap-applied values. The model's
        //    `didSet` observers write straight back into the store's own
        //    properties (same values — an idempotent round trip).
        model.registeredExtractionInputs = remote.registeredExtractionInputs
        model.registeredRendererSourceTypes =
            remote.registeredRendererSourceTypes
        // 3. ONE coalesced reload signal (the store fires it at most once
        //    per staleness detection; `reloadFromStore` coalesces bursts).
        //    The model is main-actor isolated, so the signal hops.
        remote.onReloadSignal = { [weak model] in
            Task { @MainActor in
                model?.reloadFromStore()
            }
        }
    }
}
#endif
