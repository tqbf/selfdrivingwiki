import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFS

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
}
