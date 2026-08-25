import Foundation
import Testing
@testable import WikiFSCore

@Suite struct OKFMetadataStoreTests {
    @Test func pageStatusRoundTripsClearsAndAdvancesToken() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Trust")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        let before = try store.changeToken()

        try store.setPageOKFStatus(versionID: versionID, status: .draft)
        let draft = try #require(try store.pageOKFMetadata(versionID: versionID, includeCorrected: false))
        #expect(draft.pageID == page.id)
        #expect(draft.metadata.status == .draft)
        #expect(draft.metadata.projectionRevision == 1)
        #expect(try store.changeToken().okfMetadataRevisionSum == before.okfMetadataRevisionSum + 1)

        try store.setPageOKFStatus(versionID: versionID, status: nil)
        let cleared = try #require(try store.pageOKFMetadata(versionID: versionID, includeCorrected: false))
        #expect(cleared.metadata.status == nil)
        #expect(cleared.metadata.projectionRevision == 2)
    }

    @Test func newPageVersionDoesNotInheritMetadata() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Versioned")
        let first = try #require(try store.pageHeadVersionID(pageID: page.id))
        try store.setPageOKFStatus(versionID: first, status: .stable)
        let second = try store.appendPageVersion(
            pageID: page.id, title: "Versioned", body: "new",
            expectedHeadVersionID: first, lastEditedBy: "user", provenance: [])

        #expect(try store.pageOKFMetadata(versionID: first, includeCorrected: false)?.metadata.status == .stable)
        let current = try #require(try store.pageOKFMetadata(versionID: second, includeCorrected: false))
        #expect(current.metadata.status == nil)
        #expect(current.metadata.projectionRevision == 0)
    }

    @Test func generatedTTLResolvesOnceFromExactVersionTimestamp() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Fresh")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        let generated = try #require(try store.pageVersionHistory(pageID: page.id).first).savedAt
        let policy = OKFFreshnessPolicy.ttl(seconds: 3600, anchor: .generated)

        try store.setPageOKFFreshness(versionID: versionID, policy: policy)
        let metadata = try #require(try store.pageOKFMetadata(versionID: versionID, includeCorrected: false)).metadata
        #expect(metadata.freshnessPolicy == policy)
        #expect(metadata.staleAfter == generated.addingTimeInterval(3600))
        #expect(metadata.isStale(at: metadata.staleAfter!) == true)
    }

    @Test func verificationAndAnchoredTTLCommitAtomically() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Verified and fresh")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        let verifiedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let verificationID = try store.recordPageOKFVerification(
            versionID: versionID,
            verifier: try OKFVerifierIdentity("human:reviewer"),
            verifiedAt: verifiedAt,
            basis: .init(kind: .humanReview, note: "Checked"),
            freshnessPolicy: .ttl(seconds: 600, anchor: .recordedVerification))

        let metadata = try #require(try store.pageOKFMetadata(
            versionID: versionID, includeCorrected: false)).metadata
        #expect(metadata.staleAfter == verifiedAt.addingTimeInterval(600))
        #expect(metadata.freshnessPolicy == .ttl(
            seconds: 600, anchor: .verification(verificationID)))
        #expect(metadata.projectionRevision == 1)
    }

    @Test func verificationRoundTripsAndCorrectionRemovesActiveClaim() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Verified")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        let verifiedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let verifier = try OKFVerifierIdentity("human:reviewer")
        let verificationID = try store.recordPageOKFVerification(
            versionID: versionID,
            verifier: verifier,
            verifiedAt: verifiedAt,
            basis: .init(kind: .humanReview, evidence: [.external(try #require(URL(string: "https://example.com/evidence")))]),
            freshnessPolicy: nil)

        let active = try #require(try store.pageOKFMetadata(versionID: versionID, includeCorrected: false)).metadata
        #expect(active.activeVerifications.map(\.id) == [verificationID])
        #expect(active.trustTier == .humanReviewed)

        try store.correctPageOKFVerification(
            versionID: versionID,
            verificationID: verificationID,
            correctingVerifier: try OKFVerifierIdentity("human:editor"),
            correctedAt: verifiedAt.addingTimeInterval(30),
            reason: .init(reason: "Wrong evidence"))

        let projected = try #require(try store.pageOKFMetadata(versionID: versionID, includeCorrected: false)).metadata
        #expect(projected.verifications.isEmpty)
        let audit = try #require(try store.pageOKFMetadata(versionID: versionID, includeCorrected: true)).metadata
        #expect(audit.verifications.count == 1)
        #expect(audit.verifications[0].removedAt != nil)
        let correctionActivityID = try #require(audit.verifications[0].correctionActivityID)
        #expect(audit.verifications[0].correctedBy?.rawValue == "human:editor")
        #expect(audit.verifications[0].correctionReason?.reason == "Wrong evidence")
        #expect(throws: OKFMetadataError.verificationAlreadyCorrected) {
            try store.correctPageOKFVerification(
                versionID: versionID, verificationID: verificationID,
                correctingVerifier: try OKFVerifierIdentity("human:editor"),
                correctedAt: verifiedAt.addingTimeInterval(60), reason: nil)
        }

        _ = try store.vacuumActivities(dryRun: false)
        let afterVacuum = try #require(try store.pageOKFMetadata(versionID: versionID, includeCorrected: true)).metadata
        #expect(afterVacuum.verifications.count == 1)
        #expect(afterVacuum.verifications[0].correctionActivityID == correctionActivityID)
        #expect(afterVacuum.verifications[0].correctedBy?.rawValue == "human:editor")
    }

    @Test func nonexistentSourceEvidenceCommitsNothing() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Invalid evidence")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        let beforeToken = try store.changeToken()
        let beforeMetadata = try #require(try store.pageOKFMetadata(
            versionID: versionID, includeCorrected: true)).metadata

        #expect(throws: OKFMetadataError.invalidEvidence(
            "source missing-source does not exist")) {
            try store.recordPageOKFVerification(
                versionID: versionID,
                verifier: try OKFVerifierIdentity("human:reviewer"),
                verifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
                basis: .init(
                    kind: .sourceChecked,
                    evidence: [.source(SourceID(rawValue: "missing-source"))]),
                freshnessPolicy: nil)
        }

        let afterMetadata = try #require(try store.pageOKFMetadata(
            versionID: versionID, includeCorrected: true)).metadata
        #expect(afterMetadata == beforeMetadata)
        #expect(try store.changeToken() == beforeToken)
        #expect(afterMetadata.verifications.isEmpty)
        #expect(afterMetadata.projectionRevision == 0)
    }

    @Test func directlyConstructedInvalidExternalEvidenceCommitsNothing() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Invalid URL evidence")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        let beforeToken = try store.changeToken()
        let invalidURL = try #require(URL(string: "file:///tmp/evidence"))

        #expect(throws: OKFMetadataError.invalidEvidence(
            "external evidence must be an absolute HTTP or HTTPS URL")) {
            try store.recordPageOKFVerification(
                versionID: versionID,
                verifier: try OKFVerifierIdentity("human:reviewer"),
                verifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
                basis: .init(
                    kind: .externalRevalidation,
                    evidence: [.external(invalidURL)]),
                freshnessPolicy: nil)
        }

        let metadata = try #require(try store.pageOKFMetadata(
            versionID: versionID, includeCorrected: true)).metadata
        #expect(metadata.verifications.isEmpty)
        #expect(metadata.projectionRevision == 0)
        #expect(try store.changeToken() == beforeToken)
    }

    @Test func sourceMarkdownStatusUsesItsOwnVersionNamespace() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "source.txt", data: Data("raw".utf8))
        let markdown = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "processed", origin: .user,
            note: nil, technique: nil)
        try store.setSourceMarkdownOKFStatus(versionID: markdown.id, status: .deprecated)

        let metadata = try #require(try store.sourceMarkdownOKFMetadata(
            versionID: markdown.id, includeCorrected: false))
        #expect(metadata.sourceID == source.id)
        #expect(metadata.metadata.status == .deprecated)
    }
}
