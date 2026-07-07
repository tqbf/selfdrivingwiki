import Testing
import Foundation
@testable import WikiFSCore

/// AC.5 — the Core-side seam the change bridge feeds. The bridge (app target,
/// not reachable from this test target) emits one coarse `.external` event into
/// the active store's bus on a `wikictl` change; these tests verify the effect of
/// that event on the in-process model: an `.external` event drives a full reload,
/// while a `.local` event does NOT (the model keeps self-managing on its own
/// writes — slice 2a's lowest-risk cut). The "FP signals" half of AC.5 is covered
/// by `FPIfSubscriberDebounceTests` (the subscriber edge receives all events,
/// including `.external`).
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

    @MainActor @Test func localEventDoesNotReloadModel() async throws {
        let (store, _, model) = try makeModel()
        #expect(model.summaries.isEmpty)

        // A direct store write emits a `.local` event; the model ignores it
        // (it keeps self-managing — reload-on-self-write is deferred to 2b).
        _ = try store.createPage(title: "Local")
        try await Task.sleep(for: .milliseconds(60))   // drain the run loop
        #expect(model.summaries.map(\.title) == [], "a .local event must not reload the model")
    }

    @MainActor @Test func externalEventReloadsModel() async throws {
        let (store, bus, model) = try makeModel()
        // Simulate a wikictl write landing behind the model's back (no reload yet).
        _ = try store.createPage(title: "External")
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.summaries.isEmpty, "precondition: the local write did not reload the model")

        // The bridge's flush emits this coarse .external event for the active wiki.
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: nil, id: "", change: .updated, origin: .external))
        try await awaitTitles(model, expected: ["External"])

        let titles = Set(model.summaries.map(\.title))
        #expect(titles.contains("External"), "an .external event must drive a full model reload")
    }

    @MainActor @Test func externalEventThenAnotherExternalReloadsAgain() async throws {
        let (store, bus, model) = try makeModel()
        _ = try store.createPage(title: "First")
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: nil, id: "", change: .updated, origin: .external))
        try await awaitTitles(model, expected: ["First"])

        _ = try store.createPage(title: "Second")
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: nil, id: "", change: .updated, origin: .external))
        try await awaitTitles(model, expected: ["First", "Second"])

        #expect(Set(model.summaries.map(\.title)) == ["First", "Second"])
    }
}
