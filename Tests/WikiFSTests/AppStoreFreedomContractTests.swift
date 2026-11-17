import Foundation
import Testing

/// App-side daemon-only freedom guard (plans/daemon-only-access.md Phase 0,
/// permitted-access table). Parses the app target (`Sources/WikiFS`) and the
/// app-reachable production composition files in `Sources/WikiFSEngine`,
/// asserting every forbidden storage-construction token is explicitly
/// waived. Waivers shrink phase by phase per the plan's permitted-access
/// table; the P5 column is store + read-pool + queue + index-build all
/// `none` for the APP, with the daemon/CLI/test-tier local compositions
/// explicitly waived (they own their files by design).
struct AppStoreFreedomContractTests {

    /// `Sources/WikiFS` (the whole app target) plus the app-reachable
    /// production composition files in `Sources/WikiFSEngine`. The search
    /// factory files joined this guarded set at Phase 5, when the app's
    /// local Tantivy assembly was removed. `SearchCompositionOwner.swift`
    /// and the app's `PerWikiSearchFactory` are DELETED (their absence is
    /// the compile-level guard); `SearchRuntimeCompositionFactory.swift`
    /// stays guarded because the CLI/fixture tiers legitimately own a
    /// local index runtime.
    private static let guardedFiles = [
        "Sources/WikiFSEngine/SessionsPlugin.swift",
        "Sources/WikiFSEngine/ProductionPluginCatalogs.swift",
        "Sources/WikiFSEngine/StorePlugin.swift",
        "Sources/WikiFSEngine/SearchRuntimeCompositionFactory.swift",
    ]

    /// The P5 waiver column. Each entry names what keeps it alive (for
    /// audit). The P0/P3/P4 waiver entries are REMOVED with their tokens:
    /// - P5 removed `WikiReadService(` everywhere (the type is deleted) and
    ///   the queue waivers died with their P4 files.
    /// - P5 deleted `SearchCompositionOwner.swift` — its `TantivyIndexer(`
    ///   assembly is gone; only the CLI/fixture-owned factory remains.
    static let waivers: [StoreFreedomGuardSupport.Waiver] = [
        // The `.local` production open in StorePlugin — the daemon/CLI/test
        // tiers' intentional local composition (the app never reaches it:
        // its catalog passes `.remote` unconditionally; the flag is deleted).
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFSEngine/StorePlugin.swift",
            token: "StoreBackend.current.makeStore",
            count: 1,
            clearedIn: "none (daemon/CLI/test .local composition)"),
        // The test-fixture session init's default factory — the unit-test
        // tier's permitted local composition (no daemon under test).
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFSEngine/SessionsPlugin.swift",
            token: "StoreBackend.current.makeStore",
            count: 1,
            clearedIn: "none (test-tier fixture composition)"),
        // The CLI/fixture-owned local index runtime (the app catalog no
        // longer mounts TantivySearchPlugin at all; wikictl-fixture keeps its
        // documented build-only carve-out).
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFSEngine/SearchRuntimeCompositionFactory.swift",
            token: "TantivyIndexer(",
            count: 2,
            clearedIn: "none (CLI/fixture local index runtime; app assembly removed at P5)"),
    ]

    @Test("app sources declare every local storage construction with an exact waiver")
    func appSourcesMatchWaiverColumn() throws {
        try StoreFreedomGuardSupport.assertForbiddenTokens(
            guardedDirectories: ["Sources/WikiFS"],
            guardedFiles: Self.guardedFiles,
            waivers: Self.waivers)
    }

    @Test("the deleted app search assembly stays deleted")
    func deletedSearchAssemblyStaysDeleted() throws {
        // P5 deleted `SearchCompositionOwner.swift` and the app's
        // `PerWikiSearchFactory` supply. The source guard pins the DELETION:
        // the files must not exist, and the app-reachable composition files
        // must not name the deleted types (reintroducing them is a compile
        // error in Sources and a guard failure here).
        for path in ["Sources/WikiFSEngine/SearchCompositionOwner.swift"] {
            #expect(!FileManager.default.fileExists(atPath: path), "\(path) must stay deleted")
        }
        for file in Self.guardedFiles {
            let source = try String(contentsOfFile: file, encoding: .utf8)
            #expect(!source.contains("SearchCompositionOwner"), "\(file) must not assemble a local search owner")
            #expect(!source.contains("PerWikiSearchFactory"), "\(file) must not supply a per-wiki search factory")
            // The app catalog builder must not mount the local Tantivy
            // plugin (P5). The token is scoped to the APP builder shape:
            // `CLIPluginCatalog` in the same file legitimately keeps its
            // local runtime for the CLI/fixture tier.
            #expect(!source.contains("definitions.append(TantivySearchPlugin"), "\(file) must not mount the local Tantivy plugin into the app catalog")
        }
        // The read-pool row of the table is `none`: no app-reachable file
        // constructs the deleted read service (the type itself is gone — a
        // reintroduction fails to compile in Sources; this catches comments
        // and string mentions that would suggest a live path).
        for file in Self.guardedFiles {
            let source = try String(contentsOfFile: file, encoding: .utf8)
            #expect(!source.contains("WikiReadService("), "\(file) must not construct the deleted read service")
        }
    }
}
