import Testing
import Foundation
@testable import WikiFSCore

/// Slice 2b: `changeToken()` is assembled from a registry of per-kind
/// ``ChangeTokenContributor``s. The byte-identical contract is already enforced
/// by the ~20 hardcoded-literal assertions in `SQLiteWikiStoreTests` /
/// `LogIndexTests` / `SystemPromptTests`; these tests guard the *registry's
/// structure* — the guarantee that a new `ResourceKind` can't be added without
/// its change-detection being wired up.
struct ChangeTokenContributorTests {

    /// Every `ResourceKind` either contributes a token fragment or is
    /// explicitly known to not (yet) move the token. Adding a new case to
    /// `ResourceKind` without registering a contributor OR listing it here
    /// fails this test — the structural guarantee that a new kind's
    /// change-detection isn't silently forgotten (the same discipline as
    /// `StoreEmissionExhaustivenessTests` for mutating methods).
    @Test func contributorsCoverAllResourceKinds() throws {
        let contributing = Set(SQLiteWikiStore.tokenContributors.map(\.kind))
        // Every ResourceKind now contributes a token fragment (Phase D added
        // the bookmark fold). Adding a new case to `ResourceKind` without
        // registering a contributor fails this test.
        #expect(contributing == Set(ResourceKind.allCases))
        // The registry is never empty (a deleted contributor would silently
        // shrink the token and break byte-identity).
        #expect(!SQLiteWikiStore.tokenContributors.isEmpty)
    }

    /// The registry order is the token layout — assert it is the documented
    /// historical sequence, so a careless reorder (which would stay byte-
    /// identical only by luck across the literal tests) is caught here directly.
    @Test func contributorOrderMatchesHistoricalLayout() throws {
        let kinds = SQLiteWikiStore.tokenContributors.map(\.kind)
        // pages | sources(table) | systemPrompt | log | wikiIndex |
        // source(derived) | source(graph folds) | bookmark | chat | connection
        #expect(kinds == [.page, .source, .systemPrompt, .log, .wikiIndex,
                          .source, .source, .bookmark, .chat, .connection])
    }
}
