import Testing
import Foundation
@testable import WikiFSCore

/// Slice 2b: `changeToken()` is assembled from a registry of per-kind
/// ``ChangeTokenContributor``s. The byte-identical contract is now enforced by
/// the `rawStringMatchesHistoricalLayout` test below (a fresh-DB round-trip
/// against the well-known zero-state token); these tests guard the *registry's
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
        let contributing = Set(GRDBWikiStore.tokenContributors.map(\.kind))
        // Every ResourceKind now contributes a token fragment (Phase D added
        // the bookmark fold). Adding a new case to `ResourceKind` without
        // registering a contributor fails this test.
        #expect(contributing == Set(ResourceKind.allCases))
        // The registry is never empty (a deleted contributor would silently
        // shrink the token and break byte-identity).
        #expect(!GRDBWikiStore.tokenContributors.isEmpty)
    }

    /// The registry order is the token layout — assert it is the documented
    /// historical sequence, so a careless reorder (which would produce a
    /// different `rawString` only by luck) is caught here directly.
    @Test func contributorOrderMatchesHistoricalLayout() throws {
        let kinds = GRDBWikiStore.tokenContributors.map(\.kind)
        // pages | sources(table) | systemPrompt | log | wikiIndex |
        // source(derived) | source(graph folds) | bookmark | chat
        #expect(kinds == [.page, .source, .systemPrompt, .log, .wikiIndex,
                          .source, .source, .bookmark, .chat])
    }

    /// `ChangeToken.rawString` must reproduce the historical colon-joined
    /// positional token byte-for-byte. This is the single assertion that
    /// guards the `rawString` property (replacing the ~20 per-test literal
    /// assertions that previously enforced byte-identity). A fresh DB seeds
    /// `system_prompt` and `wiki_index` at version 1; everything else is 0.
    /// If a fold is added/removed/reordered and `rawString` is not updated in
    /// lockstep, this test fails.
    @Test func rawStringMatchesHistoricalLayout() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let token = try store.changeToken()
        // 14 fields: pages(c:0,s:0) sourceTable(c:0,s:0) systemPrompt(1)
        // log(0) wikiIndex(1) sourceMarkdownVersions(0)
        // sourceGraph(sv:0,refs:0,act:0) bookmarks(0) chat(c:0,m:0).
        #expect(token.rawString == "0:0:0:0:1:0:1:0:0:0:0:0:0:0")
    }

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-changetoken-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }
}
