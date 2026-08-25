import Foundation
import Testing
@testable import WikiFSCore

@Suite struct OKFTrustLifecycleTests {
    @Test func statusVocabularyIsNormative() {
        #expect(OKFConceptStatus.allCases.map(\.rawValue) == ["draft", "stable", "deprecated"])
        #expect(OKFConceptStatus(rawValue: "active") == nil)
        #expect(OKFConceptStatus(rawValue: "archived") == nil)
    }

    @Test(arguments: ["human:alice", "process:review-bot", "checker/2.1"])
    func verifierGrammarAcceptsSupportedForms(_ rawValue: String) throws {
        #expect(try OKFVerifierIdentity(rawValue).rawValue == rawValue)
    }

    @Test(arguments: ["", "human:", "process:", "checker", "/1", "checker/", "a/b/c", " human:alice"])
    func verifierGrammarRejectsMalformedForms(_ rawValue: String) {
        #expect(throws: OKFMetadataError.self) {
            _ = try OKFVerifierIdentity(rawValue)
        }
    }

    @Test func trustTierUsesActiveVerifierIdentity() throws {
        let machine = OKFVerificationEvent(
            id: .init(rawValue: "01M"), by: try OKFVerifierIdentity("checker/1"),
            verifiedAt: .distantPast, basis: .init(kind: .sourceChecked))
        let human = OKFVerificationEvent(
            id: .init(rawValue: "01H"), by: try OKFVerifierIdentity("human:alice"),
            verifiedAt: .distantPast, basis: .init(kind: .humanReview))
        #expect(OKFConceptMetadata().trustTier == .unverified)
        #expect(OKFConceptMetadata(verifications: [machine]).trustTier == .machineConfirmed)
        #expect(OKFConceptMetadata(verifications: [machine, human]).trustTier == .humanReviewed)
    }

    @Test func staleBoundaryIsInclusive() {
        let deadline = Date(timeIntervalSince1970: 100)
        let metadata = OKFConceptMetadata(staleAfter: deadline)
        #expect(metadata.isStale(at: Date(timeIntervalSince1970: 99)) == false)
        #expect(metadata.isStale(at: deadline) == true)
        #expect(OKFConceptMetadata().isStale(at: deadline) == nil)
    }

    @Test func ttlRequiresPositiveWholeSeconds() throws {
        #expect(try OKFFreshnessPolicy.ttl(.seconds(60), anchor: .generated)
            == .ttl(seconds: 60, anchor: .generated))
        #expect(throws: OKFMetadataError.invalidFreshnessDuration) {
            _ = try OKFFreshnessPolicy.ttl(.zero, anchor: .generated)
        }
        #expect(throws: OKFMetadataError.invalidFreshnessDuration) {
            _ = try OKFFreshnessPolicy.ttl(.milliseconds(1), anchor: .generated)
        }
    }
}
