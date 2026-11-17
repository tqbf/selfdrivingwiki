#if os(macOS)
import Foundation
import WikiFSEngine

// The store-mode resolution — ONE definition (plans/daemon-only-access.md).
// P5 deleted the `allowLocalStore` flag and its `WIKI_ALLOW_LOCAL_STORE`
// DEBUG override: the app is REMOTE-ONLY, unconditionally. The resolved mode
// is a compile-time constant, never a response to daemon failure (a
// daemon-down session stays remote and surfaces typed errors — there is no
// local fallback to select). `StoreAccessMode` itself remains a live value
// domain for the daemon/CLI/test tiers (their compositions own local files;
// `StorePlugin.definition(mode:)` and the catalog builders keep branching on
// it), but the APP never branches: it passes `.remote` everywhere.
public enum StoreModeConfiguration {
    /// The mode every app composition consumes. Always `.remote` — the
    /// override mechanics were deleted at the P5 sole-writer milestone
    /// (store, read-pool, queue, index-build rows all `none`).
    public static let resolvedMode: StoreAccessMode = .remote
}
#endif
