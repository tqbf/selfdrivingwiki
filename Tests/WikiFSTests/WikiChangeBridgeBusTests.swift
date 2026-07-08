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
}
