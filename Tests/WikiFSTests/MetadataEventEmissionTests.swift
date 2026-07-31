import Foundation
import Testing
@testable import WikiFSCore

/// Phase 3 provenance mutations share the store's post-commit event seam.
/// These integration tests observe the real event bus rather than inspecting
/// implementation details of `mutate`.
struct MetadataEventEmissionTests {
    private func makeRecorder(for store: GRDBWikiStore) -> SignalRecorder {
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "metadata-events"))
        store.eventBus = bus
        let recorder = SignalRecorder()
        bus.subscribe(nil) { recorder.append($0) }
        return recorder
    }

    @Test func pageVersionAndSourcesEmitOnceAfterCommit() async throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Event provenance")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let recorder = makeRecorder(for: store)

        try store.updatePage(
            id: page.id, title: page.title, body: "claim", lastEditedBy: "user",
            provenance: [.init(sourceID: source.id, role: .primary)])

        try await recorder.awaitNonEmpty()
        await flushBusDeliveries()
        #expect(recorder.snapshot.count == 1)
        #expect(recorder.snapshot.first?.kind == .page)
        #expect(recorder.snapshot.first?.id == page.id.rawValue)
        #expect(try store.pageHeadSources(pageID: page.id).map(\.sourceID) == [source.id])
    }

    @Test func rolledBackPageProvenanceEmitsNothing() async throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Rollback provenance")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let recorder = makeRecorder(for: store)
        let duplicate = PageVersionSourceInput(sourceID: source.id, role: .supporting)

        #expect(throws: PageVersionProvenanceWriteError.self) {
            try store.updatePage(
                id: page.id, title: page.title, body: "claim", lastEditedBy: "user",
                provenance: [duplicate, duplicate])
        }

        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(recorder.snapshot.isEmpty)
        #expect(try store.pageHeadSources(pageID: page.id).isEmpty)
    }
}
