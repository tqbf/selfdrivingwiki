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

    @Test func trustSectionDistinguishesUnsetFromExplicitStable() {
        let unset = OKFMetadataPresentation.section(.init(), now: .distantPast)
        let stable = OKFMetadataPresentation.section(.init(status: .stable), now: .distantPast)
        #expect(textValue(.lifecycleStatus, in: unset) == "Not explicitly set")
        #expect(textValue(.lifecycleStatus, in: stable) == "Stable")
    }

    @Test func trustSectionShowsVerificationEvidenceAndFreshnessWithoutColor() throws {
        let verificationID = OKFVerificationID(rawValue: "verification")
        let deadline = Date(timeIntervalSince1970: 100)
        let metadata = OKFConceptMetadata(
            status: .draft, staleAfter: deadline,
            freshnessPolicy: .fixed(deadline),
            verifications: [.init(
                id: verificationID,
                by: try OKFVerifierIdentity("human:reviewer"),
                verifiedAt: Date(timeIntervalSince1970: 50),
                basis: .init(
                    kind: .humanReview,
                    evidence: [.source(.init(rawValue: "source"))],
                    note: "Reviewed against source"))])
        let section = OKFMetadataPresentation.section(
            metadata, now: Date(timeIntervalSince1970: 100))
        #expect(textValue(.trustTier, in: section) == "Human reviewed")
        #expect(textValue(.freshnessState, in: section) == "Stale")
        #expect(section.rows.contains { $0.id == .verificationActor(verificationID) })
        #expect(section.rows.contains { $0.id == .verificationNote(verificationID) })
        guard case .link(_, .source(let sourceID))? = section.rows.first(where: {
            $0.id == .verificationEvidence(verificationID, 0)
        })?.value else {
            Issue.record("Expected typed source evidence link")
            return
        }
        #expect(sourceID == SourceID(rawValue: "source"))
    }

    private func textValue(_ id: MetadataFieldID, in section: MetadataSection) -> String? {
        guard case .text(let value)? = section.rows.first(where: { $0.id == id })?.value else { return nil }
        return value
    }

    private func model(_ sources: [MetadataPageSource], hash: String? = nil) -> MetadataPanelModel {
        PageMetadataProjection.make(input: .init(
            page: .init(id: .init(rawValue: "page"), title: "Page", slug: "page", bodyMarkdown: "", createdAt: .distantPast, updatedAt: .distantPast, version: 1),
            currentVersion: hash.map { .init(id: .init(rawValue: "version"), pageID: .init(rawValue: "page"), parentID: nil, mergeParentID: nil, blobHash: $0, title: "Page", activityID: nil, savedAt: .distantPast) },
            origin: nil,
            sources: sources,
            okfMetadata: .init()))
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
