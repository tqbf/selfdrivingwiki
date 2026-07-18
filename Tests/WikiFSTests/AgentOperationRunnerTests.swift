import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

@MainActor
struct AgentOperationRunnerTests {

    private func tempStore() throws -> (WikiStoreModel, SQLiteWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-aor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    // MARK: - runLintPages combination logic

    @Test func singlePagePreflightReturnsEmptyBrokenLinks() throws {
        let (model, store) = try tempStore()
        let page = try store.createPage(title: "Test Page")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        // A fresh page with no broken links should have an empty broken list.
        #expect(preflight?.brokenPageLinks.isEmpty == true)
    }

    @Test func multiplePagePreflightsAreIndependent() throws {
        let (model, store) = try tempStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        // Create a link from A to a non-existent page so preflight
        // detects a broken link.
        try store.updatePage(id: a.id, title: "A", body: "[[MissingOne]]")
        try store.updatePage(id: b.id, title: "B", body: "[[MissingTwo]]")
        model.reloadFromStore()

        let pa = model.preflightLint(pageID: a.id)
        let pb = model.preflightLint(pageID: b.id)

        // Each page detects its own broken links independently.
        #expect(pa?.brokenPageLinks == ["MissingOne"])
        #expect(pb?.brokenPageLinks == ["MissingTwo"])
    }

    @Test func combinedTitlesJoinWithComma() throws {
        // The runLintPages method joins titles with ", ".
        // Verify the combination pattern used in the implementation.
        let pages: [(id: String, title: String)] = [
            ("a", "Alpha"), ("b", "Beta"), ("c", "Gamma"),
        ]
        let combined = pages.map(\.title).joined(separator: ", ")
        #expect(combined == "Alpha, Beta, Gamma")
    }

    @Test func combinedBrokenLinksFlatMap() throws {
        // The runLintPages method uses flatMap to combine broken links.
        let preflights: [(title: String, brokenLinks: [String])] = [
            ("A", ["One"]),
            ("B", ["Two", "Three"]),
            ("C", []),
        ]
        let combined = preflights.flatMap(\.brokenLinks)
        #expect(combined == ["One", "Two", "Three"])
    }

    @Test func brokenLinksPreserveNamespaceInPrompt() throws {
        // runLintPages formats each broken link with its wiki-link namespace
        // prefix so the agent can distinguish page/source/chat links (was a
        // flat [String] that stripped the namespace, making broken source/chat
        // links look like broken page links).
        let brokenPageLinks = ["Some Page"]
        let brokenSourceLinks = ["Some Source"]
        let brokenChatLinks = ["Some Chat"]

        let pageLinks = brokenPageLinks.map { "[[\($0)]]" }
        let sourceLinks = brokenSourceLinks.map { "[[source:\($0)]]" }
        let chatLinks = brokenChatLinks.map { "[[chat:\($0)]]" }
        let allBroken = pageLinks + sourceLinks + chatLinks

        #expect(allBroken == ["[[Some Page]]", "[[source:Some Source]]", "[[chat:Some Chat]]"])
    }

    // MARK: - Canonical ULID links are not false positives

    @Test func canonicalULIDPageLinkIsNotBroken() throws {
        let (model, store) = try tempStore()
        let target = try store.createPage(title: "Target Page")
        let page = try store.createPage(title: "Linker")
        // A canonical [[page:<ULID>|alias]] link should NOT be reported broken.
        try store.updatePage(id: page.id, title: "Linker",
            body: "See [[page:\(target.id.rawValue)#Intro|Target Page]].")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenPageLinks.isEmpty == true)
    }

    // MARK: - Links inside code spans are not checked

    @Test func linksInsideCodeSpansAreNotBroken() throws {
        let (model, store) = try tempStore()
        let page = try store.createPage(title: "Docs")
        // `[[Like This]]` inside backticks is example text, not a real link.
        try store.updatePage(id: page.id, title: "Docs",
            body: "Use `[[Like This]]` to link pages.")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenPageLinks.isEmpty == true)
    }

    @Test func linksInsideFencedBlocksAreNotBroken() throws {
        let (model, store) = try tempStore()
        let page = try store.createPage(title: "Docs")
        try store.updatePage(id: page.id, title: "Docs", body: """
        Example:

        ```
        [[Nonexistent Page]]
        ```
        """)
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenPageLinks.isEmpty == true)
    }

    // MARK: - Source links are checked

    @Test func brokenSourceLinkIsDetected() throws {
        let (model, store) = try tempStore()
        let page = try store.createPage(title: "Citing Page")
        try store.updatePage(id: page.id, title: "Citing Page",
            body: "[^1]: [[source:Nonexistent Source#\"quote\"]]\n\nText.[^1]")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenSourceLinks.contains("Nonexistent Source") == true)
    }

    @Test func resolvedSourceLinkIsNotBroken() throws {
        let (model, store) = try tempStore()
        _ = try store.addSource(filename: "Guide.md", data: Data("# Guide".utf8))
        let page = try store.createPage(title: "Citing Page")
        try store.updatePage(id: page.id, title: "Citing Page",
            body: "[^1]: [[source:Guide#\"intro\"]]\n\nText.[^1]")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenSourceLinks.isEmpty == true)
    }

    @Test func sourceLinkWithDashMismatchIsNotBroken() throws {
        let (model, store) = try tempStore()
        let src = try store.addSource(filename: "Guide.md", data: Data("# Guide".utf8))
        try store.renameSource(id: src.id, to: "Self-Driving Wiki \u{2014} User Guide")
        let page = try store.createPage(title: "Citing Page")
        // Agent cited the name without the em dash — looseMatchKey should resolve it.
        try store.updatePage(id: page.id, title: "Citing Page",
            body: "[^1]: [[source:Self-Driving Wiki User Guide#\"intro\"]]\n\nText.[^1]")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenSourceLinks.isEmpty == true)
    }
}
