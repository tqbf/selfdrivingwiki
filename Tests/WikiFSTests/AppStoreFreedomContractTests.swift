import Foundation
import Testing

/// App-side daemon-only freedom guard (plans/daemon-only-access.md Phase 0,
/// permitted-access table). Parses the app target (`Sources/WikiFS`) and the
/// app-reachable production composition files in `Sources/WikiFSEngine`,
/// asserting every forbidden storage-construction token is explicitly
/// waived. The P0 column of the table waives all of them; each waiver names
/// the phase that removes it, and the counts pin the current occurrences so
/// new direct opens fail immediately.
struct AppStoreFreedomContractTests {
    /// `Sources/WikiFS` (the whole app target) plus the app-reachable
    /// production composition files in `Sources/WikiFSEngine`. The search
    /// factory files join this guarded set in Phase 5, when the app's local
    /// Tantivy assembly is removed.
    static let guardedFiles = [
        "Sources/WikiFSEngine/SessionsPlugin.swift",
        "Sources/WikiFSEngine/ProductionPluginCatalogs.swift",
        "Sources/WikiFSEngine/StorePlugin.swift",
        "Sources/WikiFSEngine/QueueRuntimeFactory.swift",
    ]

    /// The P0 waiver column. Each entry names the phase that clears it:
    /// - P3 store cutover removes the app's local store construction and the
    ///   `StoreBackend` defaults in `StorePlugin` / `SessionsPlugin`, and the
    ///   read-only comment in `TransclusionEmbedder` is updated.
    /// - P4 removes the app-local queue assembly (the provider wiring and the
    ///   local runtime factory's queue store).
    /// - P5 removes `WikiReadService` from app composition.
    static let waivers: [StoreFreedomGuardSupport.Waiver] = [
        // Comment-only mention of the read-only store view (cleared with the
        // P3 store cutover doc pass).
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFS/Reader/TransclusionEmbedder.swift",
            token: "GRDBWikiStore(readOnlyURL:",
            count: 1,
            clearedIn: "P3"),
        // The app-local queue assembly: follow-on queue-database opens.
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFS/Queue/AppQueueExtractionProvider.swift",
            token: "QueueStore(",
            count: 2,
            clearedIn: "P4"),
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFS/Queue/QueueClosedWikiNameLoader.swift",
            token: "WikiReadService(",
            count: 1,
            clearedIn: "P5"),
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFSEngine/QueueRuntimeFactory.swift",
            token: "QueueStore(",
            count: 1,
            clearedIn: "P4"),
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFSEngine/SessionsPlugin.swift",
            token: "WikiReadService(",
            count: 1,
            clearedIn: "P5"),
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFSEngine/SessionsPlugin.swift",
            token: "StoreBackend.current.makeStore",
            count: 1,
            clearedIn: "P3"),
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFSEngine/StorePlugin.swift",
            token: "WikiReadService(",
            count: 1,
            clearedIn: "P5"),
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFSEngine/StorePlugin.swift",
            token: "StoreBackend.current.makeStore",
            count: 1,
            clearedIn: "P3"),
    ]

    @Test("app sources declare every local storage construction with an exact waiver")
    func appSourcesMatchWaiverColumn() throws {
        try StoreFreedomGuardSupport.assertForbiddenTokens(
            guardedDirectories: ["Sources/WikiFS"],
            guardedFiles: Self.guardedFiles,
            waivers: Self.waivers)
    }
}
