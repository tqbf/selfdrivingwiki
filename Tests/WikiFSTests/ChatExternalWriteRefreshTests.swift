import Foundation
import Testing
@testable import WikiFSCore

/// Regression for a live failure class: an agent chat's CLI commits landed in
/// the wiki database, but the running app never reloaded its cached
/// projections — the sources sidebar and the chat link resolver stayed stale
/// for the rest of the session because the cross-process change channel never
/// delivered.
///
/// The refresh seam is the per-wiki event bus: `WikiChangeBridge.flush` (and
/// the chat-tool-call hint that now feeds it through
/// `noteSuspectedExternalWrite(forWikiID:)`) emits onto that bus, the model's
/// subscription calls `reloadFromStore()`, and the rebuilt render context
/// resolves the `[[source:…]]` citation the chat wrote.
@MainActor
struct ChatExternalWriteRefreshTests {

    /// The citation spelling an assistant writes for a fetched page whose
    /// sanitized display name keeps its extension: pipe replaced with " - ",
    /// extension dropped.
    private static let chapterCitation = "002- Chapter Two (𒐀) - Sample Book - Site"

    @Test func busPokeAfterExternalWriteReloadsSourcesAndHealsCitation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-chat-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wikiID = WikiID(rawValue: "refresh-test-wiki")
        let databaseURL = dir.appendingPathComponent("\(wikiID.rawValue).sqlite")

        // The app side: one store + bus + on-screen model.
        let store = try GRDBWikiStore(databaseURL: databaseURL)
        let bus = WikiEventBus(wikiID: wikiID)
        store.eventBus = bus
        let model = WikiStoreModel(store: store)

        // One pre-existing source the model already knows about. The app-side
        // write emits on the bus and the model reloads — settle that first so
        // the staleness assertion below is deterministic (the bus flush is
        // deferred by a Task; racing it is what made this test flaky).
        _ = try store.addSource(
            filename: "000- Prologue - Sample Book | Site.html",
            data: Data("<html><body><p>prologue</p></body></html>".utf8))
        for _ in 0..<200 {
            if model.sources.count == 1 { break }
            await Task.yield()
        }
        #expect(model.sources.count == 1)

        let citation = Self.chapterCitation
        #expect(!model.renderContext().sourceNames.contains(citation.lowercased()))

        // The CLI stand-in: a SECOND connection adds a source. Its commits
        // emit nothing into the app-side bus (separate process in production,
        // separate store instance here) — this reproduces the bug.
        let cliStore = try GRDBWikiStore(databaseURL: databaseURL)
        let added = try cliStore.addSource(
            filename: "002- Chapter Two (𒐀) - Sample Book | Site.html",
            data: Data("<html><body><p>chapter text</p></body></html>".utf8))

        // Stale before the poke — the model still sees only the first source.
        #expect(!model.sources.contains { $0.id == added.id })

        // The fix's seam: the change bridge pokes the bus for the changed wiki
        // (`WikiChangeBridge.flush` performs exactly this emit).
        bus.emit(ResourceChangeEvent(wikiID: wikiID, kind: nil, id: "", change: .updated))

        // The subscription's reload lands asynchronously — yield until it does.
        for _ in 0..<200 {
            if model.sources.contains(where: { $0.id == added.id }) { break }
            await Task.yield()
        }

        // The sidebar projection now carries the source…
        #expect(model.sources.contains { $0.id == added.id })
        // …and the rebuilt render context resolves the chat's citation, so the
        // transcript's `[[source:…]]` link linkifies (no ghost styling).
        #expect(model.renderContext().sourceNames.contains(citation.lowercased()))
        // Click-time navigation agrees (extension-stripped pass 2).
        #expect(try store.resolveSourceByName(citation) == added.id)
    }
}
