import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

@Suite struct WikiCtlOKFCommandTests {
    private let noEnv: (String) -> String? = { _ in nil }

    @Test func parsesPageStatusWithExactPageVersionID() throws {
        let invocation = try ArgumentParser.parse([
            "--wiki", "W", "page", "okf", "status",
            "--version", "01PV", "--status", "stable"
        ], env: noEnv)
        #expect(invocation.command == .page(.okfStatus(
            versionID: PageVersionID(rawValue: "01PV"), status: .stable)))
    }

    @Test func parsesSourceVerificationWithExactMarkdownVersionIDAndTypedEvidence() throws {
        let invocation = try ArgumentParser.parse([
            "--wiki", "W", "source", "okf", "verify",
            "--version", "01SMV", "--by", "checker/2",
            "--at", "2033-05-18T03:33:20Z", "--basis", "source-checked",
            "--evidence", "source:01SOURCE", "--evidence", "url:https://example.com/evidence",
            "--ttl", "24h"
        ], env: noEnv)
        guard case .source(.okfVerify(let versionID, let input)) = invocation.command else {
            Issue.record("Expected source OKF verification action")
            return
        }
        #expect(versionID == SourceMarkdownVersionID(rawValue: "01SMV"))
        #expect(input.verifier.rawValue == "checker/2")
        #expect(input.basis.kind == .sourceChecked)
        #expect(input.basis.evidence == [
            .source(SourceID(rawValue: "01SOURCE")),
            .external(try #require(URL(string: "https://example.com/evidence")))
        ])
        #expect(input.freshness == .ttl(.seconds(86_400), anchor: .recordedVerification))
    }

    @Test func rejectsInvalidStatusDurationAndEvidence() {
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse([
                "--wiki", "W", "page", "okf", "status",
                "--version", "01PV", "--status", "active"
            ], env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse([
                "--wiki", "W", "page", "okf", "freshness",
                "--version", "01PV", "--ttl", "12"
            ], env: noEnv)
        }
        #expect(throws: ArgumentParser.Failure.self) {
            try ArgumentParser.parse([
                "--wiki", "W", "source", "okf", "verify",
                "--version", "01SMV", "--by", "checker/2",
                "--basis", "source-checked", "--evidence", "https://example.com"
            ], env: noEnv)
        }
        for invalidURL in ["url:file:///tmp/evidence", "url:custom://evidence", "url:https:/missing-host"] {
            #expect(throws: ArgumentParser.Failure.self) {
                try ArgumentParser.parse([
                    "--wiki", "W", "source", "okf", "verify",
                    "--version", "01SMV", "--by", "checker/2",
                    "--basis", "external-revalidation", "--evidence", invalidURL
                ], env: noEnv)
            }
        }
    }

    @Test func pageMutationAndInspectionSetCommitFlagsAndJSONFields() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "CLI trust")
        let versionID = try #require(try store.pageHeadVersionID(pageID: page.id))

        let mutation = try PageCommand.run(
            .okfStatus(versionID: versionID, status: .draft), in: store)
        #expect(mutation.didCommit)

        let inspection = try PageCommand.run(
            .okfInspect(versionID: versionID, json: true), in: store)
        #expect(!inspection.didCommit)
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(inspection.output.utf8)) as? [String: Any])
        #expect(object["owner_id"] as? String == page.id.rawValue)
        #expect(object["version_id"] as? String == versionID.rawValue)
        #expect(object["status"] as? String == "draft")
        #expect(object["trust_tier"] as? String == "unverified")
    }

    @Test func sourceVerificationAndCorrectionRoundTrip() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "cli.txt", data: Data("raw".utf8))
        let markdown = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "processed", origin: .user,
            note: nil, technique: nil)
        let verifiedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let verify = try SourceCommand.run(
            .okfVerify(versionID: markdown.id, input: .init(
                verifier: try OKFVerifierIdentity("human:reviewer"),
                verifiedAt: verifiedAt,
                basis: .init(kind: .humanReview),
                freshness: .ttl(.seconds(600), anchor: .recordedVerification))),
            in: store, cwd: ".")
        #expect(verify.didCommit)
        guard case .text(let line) = verify.payload,
              let rawID = line.split(separator: "\t").last else {
            Issue.record("Expected verification id output")
            return
        }
        let correction = try SourceCommand.run(
            .okfCorrect(versionID: markdown.id, input: .init(
                verificationID: .init(rawValue: String(rawID)),
                verifier: try OKFVerifierIdentity("human:editor"),
                correctedAt: verifiedAt.addingTimeInterval(10),
                reason: .init(reason: "Invalid review"))),
            in: store, cwd: ".")
        #expect(correction.didCommit)
        let metadata = try #require(try store.sourceMarkdownOKFMetadata(
            versionID: markdown.id, includeCorrected: true)).metadata
        #expect(metadata.verifications.count == 1)
        #expect(metadata.verifications[0].removedAt != nil)
        #expect(metadata.staleAfter == nil)
    }
}
