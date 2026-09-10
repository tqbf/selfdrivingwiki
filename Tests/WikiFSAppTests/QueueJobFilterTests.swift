#if os(macOS)
import Testing
@testable import WikiFS
import WikiFSCore

@Suite struct QueueJobFilterTests {
    @Test func filteredReorderDoesNotSendCommand() {
        var filter = QueueJobFilter()
        #expect(filter.allowsReordering)
        filter.search = "source"
        #expect(!filter.allowsReordering)
        filter.search = "   "
        #expect(filter.allowsReordering)
        filter.state = .queued
        #expect(!filter.allowsReordering)
    }

    @Test func jobNavigationScenarios() {
        let item = QueueItem(
            id: QueueItemID(rawValue: "filter-item"),
            queue: .ingestion,
            wikiID: WikiID(rawValue: "filter-wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "filter-source")]),
            state: .queued,
            orderingKey: 1,
            attempt: 0,
            createdAt: 1)
        var filter = QueueJobFilter()
        #expect(filter.includes(item, searchText: "Research Long Source.pdf"))
        filter.search = "long source"
        #expect(filter.includes(item, searchText: "Research Long Source.pdf"))
        filter.operation = .lint
        #expect(!filter.includes(item, searchText: "Research Long Source.pdf"))
        filter.operation = .ingestion
        filter.wikiID = WikiID(rawValue: "different-wiki")
        #expect(!filter.includes(item, searchText: "Research Long Source.pdf"))
    }
}
#endif
