import Foundation

/// The resolved store-access mode for one composition (plans/daemon-only-access.md,
/// "Flag name and polarity" — the value domain of the `allowLocalStore` flag).
///
/// Polarity is defined ONCE, here: the flag `true` selects `.local`, `false`
/// selects `.remote`. The app resolves the launch-fixed flag
/// (`StoreModeConfiguration` in WikiCtlCore) and hands the resolved mode down
/// into engine composition (`AppPluginCatalogFactories.storeAccessMode` →
/// `StorePlugin.definition(mode:openFactories:)`); the engine never reads the
/// environment itself.
public enum StoreAccessMode: String, Sendable, Equatable {
    /// The daemon owns the wiki database file and executes every operation;
    /// the session's `WikiStore` is the daemon-backed client and NO local
    /// `GRDBWikiStore` is opened. The shipping default from Phase 3 onward.
    case remote
    /// The process opens the wiki database locally. The daemon and CLI
    /// compositions are always `.local` (they own the file); the app boots
    /// `.local` only under the DEBUG `allowLocalStore` override — and after
    /// the Phase 5 close the override (and this app path) is deleted.
    case local
}

/// Composition-level failures of the mode gate (plans/daemon-only-access.md,
/// Placement: "After cutover, a missing app remote injection FAILS EXPLICITLY
/// — it never falls back to opening a local store").
public enum StoreModeError: Error, Equatable {
    /// An app catalog was built for `.remote` without an injected store
    /// factory: nothing could provision the daemon-backed store, and the
    /// fallback (a local open) is forbidden.
    case remoteModeRequiresInjectedStoreFactory
    /// `StorePlugin` was asked to provision a store in `.remote` mode with
    /// no injected factory. Opening the local database here would silently
    /// revive a second writer, so the session boot fails instead.
    case remoteModeRefusesLocalStoreOpen(wikiID: String)
}
