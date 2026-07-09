import Testing
import Foundation
@testable import WikiFSCore

/// AC.5 — the Core-side seam the change bridge feeds. The bridge (app target,
/// not reachable from this test target) emits one coarse event into the active
/// store's bus on a `wikictl` change; these tests verify the effect of that
/// event on the in-process model. Phase E: the model reloads on **all** events
/// — both local (in-app writes) and coarse (bridge/`wikictl`). The "FP signals"
/// half of AC.5 is covered by `FPIfSubscriberDebounceTests`.
struct WikiChangeBridgeBusTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-bus-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// A model over a bus-backed store. Writes are made DIRECTLY to the store
    /// (bypassing the model), so the model's `summaries` only update via a bus
    /// event — exactly the situation an external `wikictl` write creates.
    @MainActor
    private func makeModel() throws -> (SQLiteWikiStore, WikiEventBus, WikiStoreModel) {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let bus = WikiEventBus(wikiID: "W")
        store.eventBus = bus
        let model = WikiStoreModel(store: store)
        return (store, bus, model)
    }

    /// Poll the model's summary titles on the main actor until `expected` holds
    /// (bounded), mirroring the async delivery of bus events.
    @MainActor
    private func awaitTitles(_ model: WikiStoreModel, expected: Set<String>, timeoutMs: Int = 800) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            let titles = Set(model.summaries.map(\.title))
            if expected.isSubset(of: titles) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor @Test func localEventReloadsModel() async throws {
        let (store, _, model) = try makeModel()
        #expect(model.summaries.isEmpty)

        // A direct store write emits a local event; Phase E: the model
        // reloads on ALL events, including its own writes.
        _ = try store.createPage(title: "Local")
        try await awaitTitles(model, expected: ["Local"])

        let titles = Set(model.summaries.map(\.title))
        #expect(titles.contains("Local"), "a local event must reload the model (Phase E)")
    }

    @MainActor @Test func coarseBusEventReloadsModel() async throws {
        let (store, bus, model) = try makeModel()
        // A direct store write already reloads the model (Phase E).
        _ = try store.createPage(title: "External")
        try await awaitTitles(model, expected: ["External"])

        // The bridge's flush emits this coarse event for the active wiki.
        _ = try store.createPage(title: "Second")
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: nil, id: "", change: .updated))
        try await awaitTitles(model, expected: ["External", "Second"])

        let titles = Set(model.summaries.map(\.title))
        #expect(titles.contains("External"))
        #expect(titles.contains("Second"))
    }

    @MainActor @Test func externalEventThenAnotherExternalReloadsAgain() async throws {
        let (store, bus, model) = try makeModel()
        _ = try store.createPage(title: "First")
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: nil, id: "", change: .updated))
        try await awaitTitles(model, expected: ["First"])

        _ = try store.createPage(title: "Second")
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: nil, id: "", change: .updated))
        try await awaitTitles(model, expected: ["First", "Second"])

        #expect(Set(model.summaries.map(\.title)) == ["First", "Second"])
    }

    // MARK: - Issue #303: cross-process (wikictl) writes surfaced by the bridge

    /// Simulates the exact #303 scenario: `wikictl` writes through its own
    /// `SQLiteWikiStore` (no event bus — `bus?.emit` is a silent no-op in the
    /// subprocess), and the running app's model only learns about the change via
    /// the coarse bus event that `WikiChangeBridge.flush` emits after the Darwin
    /// notification. Verifies the model picks up the page purely from the coarse
    /// event, with no preceding local write.
    @MainActor @Test func crossProcessWriteSurfacedByCoarseEvent() async throws {
        let url = tempDatabaseURL()
        // Store A = the app's store (has the bus + model).
        let storeA = try SQLiteWikiStore(databaseURL: url)
        let bus = WikiEventBus(wikiID: "W")
        storeA.eventBus = bus
        let model = WikiStoreModel(store: storeA)
        #expect(model.summaries.isEmpty)

        // Store B = wikictl's store (same DB file, no bus).
        let storeB = try SQLiteWikiStore(databaseURL: url)
        _ = try storeB.createPage(title: "Chat-Created Page")

        // No bus event has fired yet → model is stale.
        #expect(model.summaries.isEmpty, "no bus event yet → model must be stale")

        // The bridge's coalesced flush emits the coarse event.
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: nil, id: "", change: .updated))
        try await awaitTitles(model, expected: ["Chat-Created Page"])

        #expect(Set(model.summaries.map(\.title)).contains("Chat-Created Page"),
                "coarse event must surface cross-process writes (#303)")
    }

    /// A burst of `wikictl` writes (multiple pages) collapsed into a SINGLE
    /// coarse event (the coalesce window) must surface ALL pages, not just the
    /// last one. This verifies the full-model reload semantics — the Darwin
    /// notification carries no per-resource detail, so the reload reads
    /// everything fresh.
    @MainActor @Test func burstOfWritesOneCoarseEventSurfacesAll() async throws {
        let url = tempDatabaseURL()
        let storeA = try SQLiteWikiStore(databaseURL: url)
        let bus = WikiEventBus(wikiID: "W")
        storeA.eventBus = bus
        let model = WikiStoreModel(store: storeA)

        // wikictl creates several pages in quick succession (one subprocess call
        // per page, but the bridge collapses them into one flush).
        let storeB = try SQLiteWikiStore(databaseURL: url)
        for title in ["Alpha", "Beta", "Gamma"] {
            _ = try storeB.createPage(title: title)
        }

        // One coarse event after the burst settles.
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: nil, id: "", change: .updated))
        try await awaitTitles(model, expected: ["Alpha", "Beta", "Gamma"])

        #expect(Set(model.summaries.map(\.title)) == ["Alpha", "Beta", "Gamma"],
                "one coarse event must surface the entire burst (#303)")
    }
}
