import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

struct MetadataPresentationTests {
    @Test func pageProjectionOrdersSourceRowsByRoleNameAndID() {
        let page = WikiPage(id: .init(rawValue: "page"), title: "Page", slug: "page", bodyMarkdown: "", createdAt: .distantPast, updatedAt: .distantPast, version: 1)
        let model = PageMetadataProjection.make(input: .init(
            page: page,
            currentVersion: nil,
            origin: nil,
            sources: [
                .init(sourceID: .init(rawValue: "z"), displayName: "Zoo", role: .supporting),
                .init(sourceID: .init(rawValue: "b"), displayName: "alpha", role: .primary),
                .init(sourceID: .init(rawValue: "a"), displayName: "Alpha", role: .primary)
            ],
            okfMetadata: .init()))
        let rows = model.sections.first { $0.id == .provenance }!.rows
        let names = rows.compactMap { row -> String? in
            guard case .link(let label, _) = row.value else { return nil }
            return label
        }
        #expect(names == ["Alpha", "alpha", "Zoo"])
    }

    @Test func sourceProjectionWithTwoAlternativesIncludesCompareAction() {
        let source = SourceSummary(id: .init(rawValue: "source"), filename: "a.pdf", ext: "pdf", mimeType: "application/pdf", byteSize: 12, createdAt: .distantPast, updatedAt: .distantPast, version: 1)
        let model = SourceMetadataProjection.make(input: .init(
            source: source, markdown: nil, extraction: nil,
            alternativeCount: 2, okfMetadata: .init()))
        #expect(model.sections.flatMap(\.rows).contains { $0.id == .compareExtractions })
    }

    @Test func chatProjectionComputesTotalOnlyWhenBothCountersExist() {
        let chat = ChatSummary(id: .init(rawValue: "chat"), kind: .edit, title: "Chat", createdAt: .distantPast, updatedAt: .distantPast, messageCount: 0)
        let usage = ChatTurnUsage(turnID: .init(rawValue: "turn"), providerID: nil, modelID: nil, startedAt: nil, finishedAt: nil, state: .completed, inputTokens: 2, outputTokens: 3, thoughtTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, cost: nil, currency: nil)
        let model = ChatMetadataProjection.make(input: .init(chat: chat, usageSummary: .init(latestTurn: usage, inputTokens: 2, outputTokens: 3, thoughtTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: nil, currency: nil)))
        #expect(model.sections.flatMap(\.rows).contains { $0.id == .totalTokens })
    }

    @Test func rendersIdentifier() {
        #expect(MetadataValueRenderer.presentation(for: .identifier("id")) == .identifier("id"))
    }

    @Test func usesTabularDigitsForCounts() {
        #expect(MetadataValueRenderer.presentation(for: .tokenCount(12)).usesTabularDigits)
    }

    @Test func unsafeURLIsRejectedWithoutOpen() {
        #expect(!MetadataActionRouter.isSafeURL(URL(string: "file:///private/test")!))
        #expect(MetadataActionRouter.isSafeURL(URL(string: "https://example.com")!))
    }
}
