import Foundation
import Testing
@testable import WikiFSTypes

/// The manifest-revision-5 `wantsAgentCleanup` claim (issue #1379): decode
/// semantics, the revision gate, the canonical-encoding rule, and the
/// registration-derived lookup the host consults.
@Suite("Extractor manifest wantsAgentCleanup claim")
struct ExtractorManifestWantsAgentCleanupTests {

    // MARK: - Fixtures

    /// A minimal extractor manifest as JSON, with the claim switchable.
    private static func manifestJSON(
        manifestRevision: Int,
        wantsAgentCleanup: String? = nil
    ) -> String {
        var registration = """
                    {
                      "id": "captions",
                      "displayName": "YouTube Transcript",
                      "kinds": ["youtube-transcript"],
                      "mimeTypes": ["video/youtube"]
        """
        if let wantsAgentCleanup {
            registration += ",\n                      \"wantsAgentCleanup\": \(wantsAgentCleanup)"
        }
        registration += "\n                    }"
        return """
        {
          "manifestRevision": \(manifestRevision),
          "packageID": "org.selfdrivingwiki.youtube-transcript",
          "version": "1.1.0",
          "displayName": "YouTube Transcript",
          "protocolRevision": 3,
          "entryPoint": "bin/youtube-transcript-extractor",
          "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
          "registrations": [
        \(registration)
          ],
          "capabilities": ["network"],
          "files": [
            {
              "path": "bin/youtube-transcript-extractor",
              "digest": "0000000000000000000000000000000000000000000000000000000000000000"
            }
          ],
          "limits": {
            "maximumInputByteCount": 1048576,
            "maximumMarkdownOutputByteCount": 33554432,
            "maximumDurationMilliseconds": 600000,
            "maximumProgressEventCount": 64
          }
        }
        """
    }

    private static func decode(_ json: String) throws -> ExtractorManifest {
        try JSONDecoder().decode(ExtractorManifest.self, from: Data(json.utf8))
    }

    private static func claimedRegistration() throws -> ExtractorRegistration {
        try ExtractorRegistration(
            id: try ExtractorRegistrationID(validating: "captions"),
            displayName: "YouTube Transcript",
            kinds: [.youtubeTranscript],
            mimeTypes: [try ExtractorMIMEType(validating: "video/youtube")],
            filenameExtensions: [],
            wantsAgentCleanup: true)
    }

    // MARK: - Decode

    @Test func revision5DecodesAClaimedRegistration() throws {
        let manifest = try Self.decode(Self.manifestJSON(
            manifestRevision: 5, wantsAgentCleanup: "true"))
        #expect(manifest.registrations.first?.wantsAgentCleanup == true)
    }

    @Test func revision5DefaultsTheClaimToFalseWhenAbsent() throws {
        let manifest = try Self.decode(Self.manifestJSON(manifestRevision: 5))
        #expect(manifest.registrations.first?.wantsAgentCleanup == false)
    }

    @Test func revision4RejectsTheClaimKey() {
        // Unknown-field policy: only a revision-5 manifest can carry the key.
        #expect(throws: ExtractorValidationError.self) {
            _ = try Self.decode(Self.manifestJSON(
                manifestRevision: 4, wantsAgentCleanup: "true"))
        }
    }

    @Test func inMemoryRevision4ManifestRejectsACleanupClaim() throws {
        // The same guard in memory: a v4 manifest can never carry a claim.
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorManifest(
                manifestRevision: .v4,
                packageID: try ExtractorPackageID(validating: "org.selfdrivingwiki.youtube-transcript"),
                version: try ExtractorPackageVersion(validating: "1.1.0"),
                displayName: "YouTube Transcript",
                protocolRevision: .v3,
                entryPoint: try ExtractorRelativePath(validating: "bin/youtube-transcript-extractor"),
                launch: .direct,
                registrations: [try Self.claimedRegistration()],
                capabilities: [.network],
                files: [ExtractorPackageFile(
                    path: try ExtractorRelativePath(validating: "bin/youtube-transcript-extractor"),
                    digest: try ExtractorPackageDigest(hex: String(repeating: "0", count: 64)))],
                limits: try ExtractorOperationLimits(
                    maximumInputByteCount: 1_048_576,
                    maximumMarkdownOutputByteCount: 33_554_432,
                    maximumDurationMilliseconds: 600_000,
                    maximumProgressEventCount: 64))
        }
    }

    // MARK: - Encoding (canonical-bytes stability)

    @Test func revision5EncodingWritesTheClaimOnlyWhenSet() throws {
        let claimed = try Self.decode(Self.manifestJSON(
            manifestRevision: 5, wantsAgentCleanup: "true"))
        let claimedJSON = String(decoding: try claimed.canonicalJSON(), as: UTF8.self)
        #expect(claimedJSON.contains("\"wantsAgentCleanup\""))

        let unclaimed = try Self.decode(Self.manifestJSON(manifestRevision: 5))
        let unclaimedJSON = String(decoding: try unclaimed.canonicalJSON(), as: UTF8.self)
        #expect(unclaimedJSON.contains("\"wantsAgentCleanup\"") == false)
    }

    // MARK: - Registration-derived lookup

    @Test func claimsLookupReportsTheClaimForAClaimedMIME() throws {
        let inputs = RegisteredExtractionInputs(claims: [
            .init(
                kind: .youtubeTranscript,
                mimeTypes: ["video/youtube"],
                filenameExtensions: [],
                wantsAgentCleanup: true),
        ])
        #expect(inputs.wantsAgentCleanup(forNormalizedMIME: "video/youtube"))
        #expect(inputs.wantsAgentCleanup(forNormalizedMIME: "VIDEO/YouTube"))
    }

    @Test func claimsLookupIsFalseWithoutAClaim() throws {
        let claimed = RegisteredExtractionInputs(claims: [
            .init(
                kind: .youtubeTranscript,
                mimeTypes: ["video/youtube"],
                filenameExtensions: [],
                wantsAgentCleanup: true),
        ])
        // A claimed-but-unflagged MIME and an unclaimed MIME both say no.
        let unclaimed = RegisteredExtractionInputs(claims: [
            .init(
                kind: .youtubeTranscript,
                mimeTypes: ["video/youtube"],
                filenameExtensions: [],
                wantsAgentCleanup: false),
        ])
        #expect(claimed.wantsAgentCleanup(forNormalizedMIME: "video/vimeo") == false)
        #expect(unclaimed.wantsAgentCleanup(forNormalizedMIME: "video/youtube") == false)
        #expect(RegisteredExtractionInputs.none.wantsAgentCleanup(forNormalizedMIME: "video/youtube") == false)
    }

    @Test func claimsLookupFailsClosedOnDisagreeingClaims() throws {
        // Two registrations claim the same MIME and disagree: no cleanup.
        let inputs = RegisteredExtractionInputs(claims: [
            .init(
                kind: .youtubeTranscript,
                mimeTypes: ["video/youtube"],
                filenameExtensions: [],
                wantsAgentCleanup: true),
            .init(
                kind: .podcastTranscript,
                mimeTypes: ["video/youtube"],
                filenameExtensions: [],
                wantsAgentCleanup: false),
        ])
        #expect(inputs.wantsAgentCleanup(forNormalizedMIME: "video/youtube") == false)
    }
}
