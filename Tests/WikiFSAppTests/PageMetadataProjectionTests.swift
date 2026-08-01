import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

struct PageMetadataProjectionTests {
    @Test func pageProjectionOmitsSourceRowsWhenAbsent() {
        #expect(model([]).sections.contains { $0.id == .provenance } == false)
    }

    @Test func pageProjectionIncludesSourceRowsWhenPresent() {
        #expect(rows([source("source", "Source", .primary)]).count == 1)
    }

    @Test func pageProjectionOrdersSourceRowsByRoleNameAndID() {
        let values = rows([source("z", "Zoo", .supporting), source("b", "alpha", .primary), source("a", "Alpha", .primary)]).compactMap { row -> String? in
            guard case .link(let label, _) = row.value else { return nil }; return label
        }
        #expect(values == ["Alpha", "alpha", "Zoo"])
    }

    @Test func pageProjectionSourceRowsCarryTypedSourceTargets() {
        let sourceID = SourceID(rawValue: "source")
        guard case .link(_, .source(let target))? = rows([source("source", "Source", .primary)]).first?.value else {
            Issue.record("source provenance row must have a typed source target")
            return
        }
        #expect(target == sourceID)
    }

    @Test func pageProjectionShowsTechnicalHashWhenPresent() {
        #expect(technical(hash: "hash").contains { $0.id == .hash })
    }

    @Test func pageProjectionOmitsTechnicalHashWhenAbsent() {
        #expect(!technical(hash: nil).contains { $0.id == .hash })
    }

    private func model(_ sources: [MetadataPageSource], hash: String? = nil) -> MetadataPanelModel {
        PageMetadataProjection.make(input: .init(
            page: .init(id: .init(rawValue: "page"), title: "Page", slug: "page", bodyMarkdown: "", createdAt: .distantPast, updatedAt: .distantPast, version: 1),
            currentVersion: hash.map { .init(id: .init(rawValue: "version"), pageID: .init(rawValue: "page"), parentID: nil, mergeParentID: nil, blobHash: $0, title: "Page", activityID: nil, savedAt: .distantPast) },
            origin: nil,
            sources: sources))
    }

    private func rows(_ sources: [MetadataPageSource]) -> [MetadataRow] {
        model(sources).sections.first(where: { $0.id == .provenance })?.rows ?? []
    }

    private func technical(hash: String?) -> [MetadataRow] {
        model([], hash: hash).sections.first(where: { $0.id == .technical })!.rows
    }

    private func source(_ id: String, _ name: String, _ role: PageVersionSourceRole) -> MetadataPageSource {
        .init(sourceID: .init(rawValue: id), displayName: name, role: role)
    }
}
