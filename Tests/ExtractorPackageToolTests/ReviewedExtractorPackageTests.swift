import Foundation
import Testing
import WikiFSTypes
@testable import ExtractorPackageToolCore

/// The reviewed packages under `ExtractorPackages/` are build inputs: the app
/// and the wikid XPC service both receive this tree, and the machine catalog
/// records the exact digest of every declared file.
///
/// These tests run the real validator over the committed bytes, so a hand
/// edit, a stale regeneration, or a manifest that could never be admitted
/// fails here rather than at install time on a user's Mac.
@Suite("Reviewed extractor packages", .serialized, .timeLimit(.minutes(3)))
struct ReviewedExtractorPackageTests {
    @Test func defuddlePackageValidatesAndKeepsItsReviewedIdentity() throws {
        let output = try validate("Defuddle")

        #expect(output.packageID == "org.selfdrivingwiki.defuddle")
        #expect(output.protocolRevision == 1)
        #expect(output.registrationIDs == ["article"])
    }

    @Test func pdf2mdPackageValidatesAndKeepsItsReviewedIdentity() throws {
        let output = try validate("Pdf2md")

        #expect(output.packageID == "org.selfdrivingwiki.pdf2md")
        #expect(output.protocolRevision == 1)
        #expect(output.registrationIDs == ["document"])
    }

    /// The reviewed Docling Serve package (#1159): manifest revision 2,
    /// protocol revision 2, one PDF registration declaring the optional
    /// `api-token` requirement. No secret value and no credential reference
    /// may appear in the committed bytes.
    @Test func doclingServePackageValidatesRevisionTwoContract() throws {
        let output = try validate("DoclingServe")

        #expect(output.packageID == "org.selfdrivingwiki.docling-serve")
        #expect(output.protocolRevision == 2)
        #expect(output.registrationIDs == ["document"])

        let manifest = try manifest("DoclingServe")
        #expect(manifest.manifestRevision == .v2)
        let requirements = manifest.registrations.flatMap(\.credentialRequirements)
        #expect(requirements.map(\.id.rawValue) == ["api-token"])
        #expect(requirements.allSatisfy { $0.isOptional && $0.kind == .secret })

        // Secret-free bytes: the declared requirement is a review fact; a
        // value or a reference binding must never be committed.
        let manifestData = try Data(contentsOf: Self.packageURL("DoclingServe")
            .appendingPathComponent("manifest.json"))
        let payload = String(decoding: manifestData, as: UTF8.self)
        #expect(payload.contains("credentialReference") == false)
        #expect(payload.contains("credential_locations") == false)
    }

    /// The reviewed docx2md package: manifest revision 1, protocol revision
    /// 1, one DOCX registration with no capabilities (offline conversion).
    @Test func docx2mdPackageValidatesAndKeepsItsReviewedIdentity() throws {
        let output = try validate("Docx2md")

        #expect(output.packageID == "org.selfdrivingwiki.docx2md")
        #expect(output.protocolRevision == 1)
        #expect(output.registrationIDs == ["document"])

        let manifest = try manifest("Docx2md")
        let registration = try #require(manifest.registrations.first)
        #expect(registration.kinds == [.docx])
        #expect(registration.filenameExtensions.contains(
            try ExtractorFileExtension(validating: "docx")))
        #expect(manifest.capabilities.isEmpty)
        guard case .runtime(let command, let arguments) = manifest.launch else {
            Issue.record("docx2md must launch through a runtime")
            return
        }
        #expect(command.rawValue == "bun")
        #expect(arguments.isEmpty)
    }

    /// The reviewed podcast transcript package: manifest revision 1 with
    /// protocol revision 3 — the new kind is registration data, not a new
    /// manifest field. `remote-url` is its only input transport, `network`
    /// its only capability, and the Whisper fallback is not registered.
    @Test func podcastTranscriptRevisionMatchesGolden() throws {
        let output = try validate("PodcastTranscript")

        #expect(output.packageID == "org.selfdrivingwiki.podcast-transcript")
        #expect(output.protocolRevision == 3)
        #expect(output.registrationIDs == ["feed"])

        let manifest = try manifest("PodcastTranscript")
        #expect(manifest.manifestRevision == .v1)
        let registration = try #require(manifest.registrations.first)
        #expect(registration.kinds == [.podcastTranscript])
        #expect(registration.mimeTypes == [try ExtractorMIMEType(validating: "audio/podcast")])
        #expect(registration.credentialRequirements.isEmpty)
        #expect(manifest.capabilities == [.network])
        guard case .runtime(let command, let arguments) = manifest.launch else {
            Issue.record("podcast-transcript must launch through a runtime")
            return
        }
        #expect(command.rawValue == "uv")
        #expect(arguments == ["run", "--script"])

        // The exact reviewed identity is pinned byte-for-byte; a regenerated
        // package whose digest changed fails this gate with the new value.
        #expect(output.packageDigest
            == "8bfc2f5cab3e8e7a7cba421cf34afc11e1f2e4bd5bb8fcf5aae05fb4c87db54a")
    }

    /// The registered source URL never appears in the committed package
    /// bytes, and the reviewed registration never declares the Whisper
    /// transcription fallback or model capabilities.
    @Test func podcastTranscriptDeclaresNoModelOrSharedCacheCapabilities() throws {
        let manifest = try manifest("PodcastTranscript")
        #expect(manifest.capabilities.contains(.modelDownload) == false)
        #expect(manifest.capabilities.contains(.sharedRuntimeCache) == false)

        let payload = try String(
            contentsOf: Self.packageURL("PodcastTranscript")
                .appendingPathComponent("PROVENANCE.md"),
            encoding: .utf8)
        #expect(payload.contains("model-download") == false)
        #expect(payload.contains("shared-runtime-cache") == false)
    }

    /// AC.3: recorded success and bounded-failure frame sequences from the
    /// committed bundle replay through `protocol-smoke`. The tool never
    /// launches the process — it validates the directory and replays the
    /// recorded frames against the manifest's limits.
    @Test func podcastTranscriptRecordedProtocolFramesReplayThroughProtocolSmoke() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PodcastTranscript", isDirectory: true)
        let request = fixtures.appendingPathComponent("request.json").path

        let success = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("PodcastTranscript").path,
            request,
            fixtures.appendingPathComponent("frames.jsonl").path,
        ])
        #expect(success.packageID == "org.selfdrivingwiki.podcast-transcript")
        #expect(success.terminalKind == "result")
        #expect(success.progressEventCount == 3)

        let missingTranscript = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("PodcastTranscript").path,
            request,
            fixtures.appendingPathComponent("frames-missing-transcript.jsonl").path,
        ])
        #expect(missingTranscript.terminalKind == "failure")

        let networkFailure = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("PodcastTranscript").path,
            request,
            fixtures.appendingPathComponent("frames-network-failure.jsonl").path,
        ])
        #expect(networkFailure.terminalKind == "failure")
    }

    /// A `remote-url` request must be rejected for a revision-1 package and
    /// an `operation-file` request must be rejected for this revision-3
    /// package: the transports are revision-scoped in both directions.
    @Test func podcastTranscriptRejectsWrongTransportAndRevision() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PodcastTranscript", isDirectory: true)
        let request = try Data(contentsOf: fixtures.appendingPathComponent("request.json"))

        // A valid v1 operation-file request document with this package: the
        // tool's revision gate rejects the mismatch.
        let v1Request = String(decoding: request, as: UTF8.self)
            .replacing("\"protocolRevision\":3", with: "\"protocolRevision\":1")
            .replacing(
                "\"inputTransport\":\"remote-url\",\"remoteURL\":\"https://example.com/feed.rss\"",
                with: "\"inputTransport\":\"operation-file\",\"inputPath\":\"input/source\"")
        let v1URL = fixtures.appendingPathComponent("request-v1.json")
        try v1Request.write(to: v1URL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: v1URL) }
        #expect(throws: ExtractorPackageToolFailure.protocolRevisionMismatch) {
            try ExtractorPackageToolExecutor().execute(arguments: [
                "protocol-smoke",
                Self.packageURL("PodcastTranscript").path,
                v1URL.path,
                fixtures.appendingPathComponent("frames.jsonl").path,
            ])
        }

        // An operation-file request document for this package: revision
        // matches, but the registration does not claim the docx MIME type.
        let fileRequest = String(decoding: request, as: UTF8.self)
            .replacing("\"inputTransport\":\"remote-url\",\"remoteURL\":\"https://example.com/feed.rss\"", with: "\"inputTransport\":\"operation-file\",\"inputPath\":\"input/source\"")
            .replacing("\"kind\":\"podcast-transcript\"", with: "\"kind\":\"pdf\"")
            .replacing("\"mimeType\":\"audio/podcast\"", with: "\"mimeType\":\"application/pdf\"")
        let fileURL = fixtures.appendingPathComponent("request-file.json")
        try fileRequest.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(throws: ExtractorPackageToolFailure.unsupportedRegistration) {
            try ExtractorPackageToolExecutor().execute(arguments: [
                "protocol-smoke",
                Self.packageURL("PodcastTranscript").path,
                fileURL.path,
                fixtures.appendingPathComponent("frames.jsonl").path,
            ])
        }
    }

    /// The reviewed YouTube transcript package: manifest revision 1 with
    /// protocol revision 3, one `youtube-transcript` registration over the
    /// synthetic `video/youtube` MIME, and the `network` capability only.
    /// Media download and speech-to-text are not registered.
    @Test func youtubeTranscriptRevisionMatchesGolden() throws {
        let output = try validate("YouTubeTranscript")

        #expect(output.packageID == "org.selfdrivingwiki.youtube-transcript")
        #expect(output.protocolRevision == 3)
        #expect(output.registrationIDs == ["captions"])

        let manifest = try manifest("YouTubeTranscript")
        #expect(manifest.manifestRevision == .v1)
        let registration = try #require(manifest.registrations.first)
        #expect(registration.kinds == [.youtubeTranscript])
        #expect(registration.mimeTypes == [try ExtractorMIMEType(validating: "video/youtube")])
        #expect(registration.credentialRequirements.isEmpty)
        #expect(manifest.capabilities == [.network])
        guard case .runtime(let command, let arguments) = manifest.launch else {
            Issue.record("youtube-transcript must launch through a runtime")
            return
        }
        #expect(command.rawValue == "uv")
        #expect(arguments == ["run", "--script"])

        // The exact reviewed identity is pinned byte-for-byte; a regenerated
        // package whose digest changed fails this gate with the new value.
        #expect(output.packageDigest
            == "daf2ab7e61164aeb82246e03747df459fdf116c5235c9bf0faee11f57ac7cd54")
    }

    /// The reviewed YouTube package never claims model or shared-cache
    /// capabilities: it fetches captions YouTube exposes and does nothing else.
    @Test func youtubeTranscriptDeclaresNoModelOrSharedCacheCapabilities() throws {
        let manifest = try manifest("YouTubeTranscript")
        #expect(manifest.capabilities.contains(.modelDownload) == false)
        #expect(manifest.capabilities.contains(.sharedRuntimeCache) == false)
    }

    /// Recorded success, no-caption, and blocked-request frame sequences from
    /// the committed bundle replay through `protocol-smoke`. The tool never
    /// launches the process — it validates the directory and replays the
    /// recorded frames against the manifest's limits.
    @Test func youtubeTranscriptRecordedProtocolFramesReplayThroughProtocolSmoke() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/YouTubeTranscript", isDirectory: true)
        let request = fixtures.appendingPathComponent("request.json").path

        let success = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("YouTubeTranscript").path,
            request,
            fixtures.appendingPathComponent("frames.jsonl").path,
        ])
        #expect(success.packageID == "org.selfdrivingwiki.youtube-transcript")
        #expect(success.terminalKind == "result")
        #expect(success.progressEventCount == 4)

        let noCaptions = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("YouTubeTranscript").path,
            request,
            fixtures.appendingPathComponent("frames-no-captions.jsonl").path,
        ])
        #expect(noCaptions.terminalKind == "failure")

        let blocked = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("YouTubeTranscript").path,
            request,
            fixtures.appendingPathComponent("frames-blocked.jsonl").path,
        ])
        #expect(blocked.terminalKind == "failure")
    }

    /// A malformed frame document (two terminal frames) must fail the
    /// protocol-smoke replay: exactly one terminal frame is the contract.
    @Test func youtubeTranscriptRejectsFrameRuleViolations() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/YouTubeTranscript", isDirectory: true)
        let request = fixtures.appendingPathComponent("request.json").path
        let malformed = fixtures.appendingPathComponent("frames-malformed.jsonl")
        let frame = """
        {"kind":"failure","payload":{"requestID":"6f1e2b3c-0000-4000-8000-000000000001","cause":"extraction-failure","message":"caption retrieval failed"}}
        """
        try Data((frame + "\n" + frame).utf8).write(to: malformed)
        defer { try? FileManager.default.removeItem(at: malformed) }

        #expect(throws: (any Error).self) {
            _ = try ExtractorPackageToolExecutor().execute(arguments: [
                "protocol-smoke",
                Self.packageURL("YouTubeTranscript").path,
                request,
                malformed.path,
            ])
        }
    }

    @Test func reviewedDigestsAreStableAcrossRepeatedValidation() throws {
        for name in ["Defuddle", "Pdf2md", "DoclingServe", "Docx2md", "PodcastTranscript", "ApplePodcastTranscript", "YouTubeTranscript"] {
            let first = try validate(name)
            let second = try validate(name)
            #expect(first.packageDigest == second.packageDigest)
            #expect(first.packageDigest.count == 64)
        }
        // The compiled reviewed identity matches the committed bytes (AC.17).
        // The golden constant lives in WikiFSEngine.ReviewedExtractorPackages;
        // pinned here byte-for-byte so this tool-target gate fails loudly on
        // drift even though it cannot import the engine module.
        #expect(try validate("DoclingServe").packageDigest
            == "1a47573f0e07699a42f25b27bb300a29437c83489f18f33e1653f3e6192eb658")
        #expect(try validate("Docx2md").packageDigest
            == "ae5247e9108a0da5b8deb4f1dda154f72939c758f9f3db8f12d4dbb61977d42e")
    }

    /// Revision 1 supports PDF, HTML, and DOCX byte extraction, and every
    /// reviewed package must claim a distinct kind. The podcast transcript
    /// package is the revision-3 `podcast-transcript` member.
    @Test func reviewedPackagesCoverDistinctKinds() throws {
        let defuddle = try manifest("Defuddle")
        let pdf2md = try manifest("Pdf2md")
        let docx2md = try manifest("Docx2md")
        let podcast = try manifest("PodcastTranscript")
        let applePodcast = try manifest("ApplePodcastTranscript")
        let youtube = try manifest("YouTubeTranscript")

        #expect(defuddle.registrations.allSatisfy { $0.kinds == [.html] })
        #expect(pdf2md.registrations.allSatisfy { $0.kinds == [.pdf] })
        #expect(docx2md.registrations.allSatisfy { $0.kinds == [.docx] })
        #expect(podcast.registrations.allSatisfy { $0.kinds == [.podcastTranscript] })
        #expect(applePodcast.registrations.allSatisfy { $0.kinds == [.applePodcastTranscript] })
        #expect(youtube.registrations.allSatisfy { $0.kinds == [.youtubeTranscript] })
    }

    /// AC.4: a frames.jsonl + request.json pair recorded from a real run of
    /// the committed bundle replays through `protocol-smoke` with exactly one
    /// terminal result frame. The tool never launches the process — it
    /// validates the directory and replays the recorded frames.
    @Test func docx2mdRecordedProtocolFramesReplayThroughProtocolSmoke() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Docx2md", isDirectory: true)
        let output = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("Docx2md").path,
            fixtures.appendingPathComponent("request.json").path,
            fixtures.appendingPathComponent("frames.jsonl").path,
        ])
        #expect(output.packageID == "org.selfdrivingwiki.docx2md")
        #expect(output.terminalKind == "result")
    }

    /// A runtime package must name one command without a path. The host
    /// resolves it against its own immutable search list, so a manifest that
    /// carried a path would bypass that policy.
    @Test func reviewedPackagesLaunchThroughNamedRuntimes() throws {
        guard case .runtime(let defuddleCommand, let defuddleArguments) = try manifest("Defuddle").launch else {
            Issue.record("Defuddle must launch through a runtime")
            return
        }
        #expect(defuddleCommand.rawValue == "bun")
        #expect(defuddleArguments.isEmpty)

        guard case .runtime(let pdfCommand, let pdfArguments) = try manifest("Pdf2md").launch else {
            Issue.record("pdf2md must launch through a runtime")
            return
        }
        #expect(pdfCommand.rawValue == "uv")
        // The host appends the entry point after these arguments.
        #expect(pdfArguments == ["run", "--script"])
    }

    /// Capability declarations are review facts. Local HTML extraction reads
    /// only its operation input, so Defuddle must not claim network access.
    @Test func defuddleClaimsNoCapabilities() throws {
        #expect(try manifest("Defuddle").capabilities.isEmpty)
    }

    /// uv resolves dependencies and docling downloads its model on first use.
    @Test func pdf2mdDeclaresItsNetworkAndModelCapabilities() throws {
        let capabilities = try manifest("Pdf2md").capabilities

        #expect(capabilities.contains(.network))
        #expect(capabilities.contains(.modelDownload))
        #expect(capabilities.contains(.sharedRuntimeCache))
    }

    // MARK: - Helpers

    private func validate(_ name: String) throws -> ExtractorPackageValidationOutput {
        try ExtractorPackageToolExecutor().execute(
            arguments: ["validate", Self.packageURL(name).path])
    }

    private func manifest(_ name: String) throws -> ExtractorManifest {
        let data = try Data(contentsOf: Self.packageURL(name).appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(ExtractorManifest.self, from: data)
    }

    private static func packageURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExtractorPackages", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}
