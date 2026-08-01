import Foundation
import Testing
@testable import WikiFSCore

/// The metadata reads added in Phase 1 must retain the same read-pool
/// visibility contract as existing page/source projections.
struct MetadataReadPoolTests {
    @Test func readerSeesCommittedChatUsage() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "metadata-read-pool-chat")
        let writer = try GRDBWikiStore(databaseURL: url)
        let pool = WikiReadPool(databaseURL: url)
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

        let usage = try #require(try pool.read {
            try $0.chatTurnUsage(chatID: chat.id, turnID: claimed.submission.turnID)
        })
        #expect(usage.inputTokens == 9)
        #expect(usage.providerID == ProviderID(rawValue: "provider"))
    }

    @Test func readerSeesCommittedPageSources() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "metadata-read-pool-page")
        let writer = try GRDBWikiStore(databaseURL: url)
        let page = try writer.createPage(title: "Page")
        let version = try #require(try writer.pageHeadVersionID(pageID: page.id))
        let source = try writer.addSource(filename: "source.txt", data: Data("source".utf8))
        writer.close()
        try MetadataSQLiteFixtureSupport.execute(
            "INSERT INTO page_version_sources VALUES ('\(version.rawValue)', '\(source.id.rawValue)', 'supporting')",
            at: url
        )

        let pool = WikiReadPool(databaseURL: url)
        #expect(try pool.read { try $0.pageVersionSources(versionID: version) } == [
            .init(pageVersionID: version, sourceID: source.id, role: .supporting),
        ])
    }

    @Test func readerSeesCommittedExtractionProvenance() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "metadata-read-pool-extraction")
        let writer = try GRDBWikiStore(databaseURL: url)
        let source = try writer.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        let markdownID = try writer.appendDerivedMarkdown(
            sourceID: source.id, content: "# markdown", origin: .extraction,
            producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
            sourceVersionID: nil, note: nil).id

        let pool = WikiReadPool(databaseURL: url)
        let provenance = try #require(try pool.read {
            try $0.extractionProvenance(markdownVersionID: markdownID)
        })
        #expect(provenance.producer == .tool(.pdf2md))
    }

    @Test func readerNeverSeesRolledBackMetadata() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "metadata-read-pool-rollback")
        let writer = try GRDBWikiStore(databaseURL: url)
        let pool = WikiReadPool(databaseURL: url)
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

        let usage = try #require(try pool.read {
            try $0.chatTurnUsage(chatID: chat.id, turnID: claimed.submission.turnID)
        })
        #expect(usage.inputTokens == nil)
    }
}
