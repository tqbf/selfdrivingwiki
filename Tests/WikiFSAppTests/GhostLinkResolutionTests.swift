#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

/// Ghost-link live resolution: a `wiki://missing?title=…` link baked before
/// its target existed resolves through `WikiLinkMenuNSItems.selection` once
/// the store has the target (the link menu's item gating, open-in-background,
/// and the click router all consult it). Also pins the invalidation chain the
/// transcript heal depends on: an external write → `reloadFromStore()` →
/// `renderContext().generation` advances.
@MainActor
@Suite("Ghost link resolution")
struct GhostLinkResolutionTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ghost-\(UUID().uuidString).sqlite")
    }

    private func makeModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        return (WikiStoreModel(store: store), store)
    }

    /// The ghost form the renderer bakes for an unresolvable
    /// `[[source:Name]]`: `wiki://missing?title=<target>`.
    private func ghostURL(_ title: String) -> URL {
        var components = URLComponents()
        components.scheme = "wiki"
        components.host = "missing"
        components.queryItems = [URLQueryItem(name: "title", value: title)]
        return components.url!
    }

    // MARK: - selection(for:store:)

    @Test func ghostSourceLinkResolvesOnceTheSourceExists() throws {
        let (model, store) = try makeModel()
        let summary = try store.addSource(
            filename: "The higher order approach",
            data: Data("# Paper".utf8))

        let selection = WikiLinkMenuNSItems.selection(
            for: ghostURL("The higher order approach"), store: model)
        #expect(selection == .source(summary.id))
    }

    @Test func ghostPageLinkResolvesOnceThePageExists() throws {
        let (model, store) = try makeModel()
        let page = try store.createPage(title: "Signal Detection Theory")

        let selection = WikiLinkMenuNSItems.selection(
            for: ghostURL("Signal Detection Theory"), store: model)
        #expect(selection == .page(page.id))
    }

    @Test func deadGhostStaysUnresolved() throws {
        let (model, _) = try makeModel()
        let selection = WikiLinkMenuNSItems.selection(
            for: ghostURL("No Such Target Anywhere"), store: model)
        #expect(selection == nil)
    }

    @Test func nonWikiURLsNeverTakeTheGhostPath() throws {
        let (model, store) = try makeModel()
        _ = try store.addSource(filename: "A Paper", data: Data("x".utf8))
        // An external http(s) link (and anything else non-wiki) must not be
        // title-resolved against wiki content.
        #expect(
            WikiLinkMenuNSItems.selection(
                for: URL(string: "https://example.com/A%20Paper")!, store: model)
                == nil)
    }

    // MARK: - The invalidation chain the heal pass depends on

    @Test func renderContextGenerationAdvancesAfterExternalWrite() throws {
        let (model, store) = try makeModel()
        let before = model.renderContext().generation

        // Simulate the wikictl subprocess write: mutate the store directly,
        // bypassing the model's local mutators, then run the external-write
        // reload path (what the Darwin-notification bridge triggers).
        _ = try store.addSource(
            filename: "External Import", data: Data("x".utf8))
        model.reloadFromStore()

        let after = model.renderContext().generation
        #expect(after != before)
    }
}
#endif
