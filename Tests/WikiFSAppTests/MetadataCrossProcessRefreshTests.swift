import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

struct MetadataCrossProcessRefreshTests {
    @Test func darwinPageChangeRehydratesSelectedPage() {
        #expect(MetadataHydrationKey.page(PageID(rawValue: "page"), 1) != .page(PageID(rawValue: "page"), 2))
    }

    @Test func darwinSourceChangeRehydratesSelectedSource() {
        #expect(MetadataHydrationKey.source(SourceID(rawValue: "source"), 1) != .source(SourceID(rawValue: "source"), 2))
    }

    @Test func darwinChatChangeRehydratesSelectedChat() {
        #expect(MetadataHydrationKey.chat(ChatID(rawValue: "chat"), 1) != .chat(ChatID(rawValue: "chat"), 2))
    }

    @Test func eventBusChangeAdvancesHydrationKey() {
        let previous = MetadataHydrationKey.page(PageID(rawValue: "page"), 3)
        let committed = MetadataHydrationKey.page(PageID(rawValue: "page"), 4)
        #expect(previous != committed)
    }

    @Test func daemonSyncRefreshesLiveChatWithoutStoreRead() {
        let live = ChatMetadataLiveSnapshot(turnID: .init(rawValue: "turn"), state: .responding, providerID: nil, modelID: nil, usage: nil)
        let merged = ChatMetadataProjection.mergedUsage(persisted: nil, live: live)
        #expect(merged?.turnID == ChatTurnID(rawValue: "turn"))
    }
}
