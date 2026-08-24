import Foundation
import Testing
@testable import WikiFSCore

/// Metadata projections must observe committed values through the same narrow
/// read capability that production detail views use.
struct MetadataReadServiceTests {
    @Test func readerSeesCommittedChatUsage() async throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "metadata-read-service-chat")
        let writer = try GRDBWikiStore(databaseURL: url)
        let service = WikiReadService(databaseURL: url)
        let chat = try writer.createChat(kind: .edit, title: "Usage")
        _ = try writer.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: .init(
                commandID: ChatCommandID(rawValue: "command"), turnID: ChatTurnID(rawValue: "turn"),
                userText: "text", contextReferences: [], submittedAt: Date(timeIntervalSince1970: 1)
            )
        )
        let claimed = try #require(try writer.claimNextPersistedChatTurn(
            chatID: chat.id, claimID: ChatTurnClaimID(rawValue: "claim"),
            claimedAt: Date(timeIntervalSince1970: 2),
            providerID: ProviderID(rawValue: "provider"), modelID: ModelID(rawValue: "model")
        ))
        _ = try writer.updatePersistedChatTurnUsage(
            chatID: chat.id, turnID: claimed.submission.turnID, claimID: try #require(claimed.claimID),
            usage: .init(inputTokens: 9)
        )

        let usage = try await service.asyncRead { try $0.chatUsageSummary(chatID: chat.id) }
        #expect(usage.inputTokens == 9)
    }

    @Test func readerSeesCommittedPageSources() async throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "metadata-read-service-page")
        let writer = try GRDBWikiStore(databaseURL: url)
        let page = try writer.createPage(title: "Page")
        let version = try #require(try writer.pageHeadVersionID(pageID: page.id))
        let source = try writer.addSource(filename: "source.txt", data: Data("source".utf8))
        writer.close()
        try MetadataSQLiteFixtureSupport.execute(
            "INSERT INTO page_version_sources VALUES ('\(version.rawValue)', '\(source.id.rawValue)', 'supporting')",
            at: url
        )

        let service = WikiReadService(databaseURL: url)
        let sources = try await service.asyncRead { try $0.pageHeadSources(pageID: page.id) }
        #expect(sources == [.init(pageVersionID: version, sourceID: source.id, role: .supporting)])
    }

    @Test func readerSeesCommittedExtractionProvenance() async throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "metadata-read-service-extraction")
        let writer = try GRDBWikiStore(databaseURL: url)
        let source = try writer.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        _ = try writer.appendDerivedMarkdown(
            sourceID: source.id, content: "# markdown", origin: .extraction,
            producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
            sourceVersionID: nil, note: nil)

        let service = WikiReadService(databaseURL: url)
        let provenance = try #require(try await service.asyncRead {
            try $0.activeExtractionProvenance(sourceID: source.id)
        })
        #expect(provenance.producer == .tool(.pdf2md))
    }

    @Test func readerNeverSeesRolledBackMetadata() async throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "metadata-read-service-rollback")
        let writer = try GRDBWikiStore(databaseURL: url)
        let service = WikiReadService(databaseURL: url)
        let chat = try writer.createChat(kind: .edit, title: "Rollback")
        _ = try writer.enqueuePersistedChatTurn(
            chatID: chat.id,
            submission: .init(
                commandID: ChatCommandID(rawValue: "command"), turnID: ChatTurnID(rawValue: "turn"),
                userText: "text", contextReferences: [], submittedAt: Date(timeIntervalSince1970: 1)
            )
        )
        let claimed = try #require(try writer.claimNextPersistedChatTurn(
            chatID: chat.id, claimID: ChatTurnClaimID(rawValue: "claim"), claimedAt: Date(timeIntervalSince1970: 2)
        ))
        do {
            _ = try writer.updatePersistedChatTurnUsage(
                chatID: chat.id, turnID: claimed.submission.turnID,
                claimID: ChatTurnClaimID(rawValue: "stale"), usage: .init(inputTokens: 99)
            )
            Issue.record("expected stale claim rejection")
        } catch let error as MetadataStoreError {
            #expect(error == .staleChatTurnClaim)
        }

        let usage = try await service.asyncRead { try $0.chatUsageSummary(chatID: chat.id) }
        #expect(usage.inputTokens == 0)
    }
}
