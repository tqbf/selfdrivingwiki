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
        // Network for the feed/transcript fetches; shared-runtime-cache
        // keeps uv's CPython install and wheel cache warm across operations
        // (shared with the other uv-launched packages).
        #expect(manifest.capabilities == [.network, .sharedRuntimeCache])
        guard case .runtime(let command, let arguments) = manifest.launch else {
            Issue.record("podcast-transcript must launch through a runtime")
            return
        }
        #expect(command.rawValue == "uv")
        #expect(arguments == ["run", "--script"])

        // The exact reviewed identity is pinned byte-for-byte; a regenerated
        // package whose digest changed fails this gate with the new value.
        #expect(output.packageDigest
            == "14ea800bd0fd525a925f5bc47ce4b4cf5b3b6d31892edfea20e0cb8d3a5621af")
    }

    /// The registered source URL never appears in the committed package
    /// bytes, and the reviewed registration never declares the Whisper
    /// transcription fallback or model capabilities. The shared runtime
    /// cache keeps its uv runtime warm across operations.
    @Test func podcastTranscriptDeclaresNoModelCapabilities() throws {
        let manifest = try manifest("PodcastTranscript")
        #expect(manifest.capabilities.contains(.modelDownload) == false)
        #expect(manifest.capabilities.contains(.sharedRuntimeCache))

        let payload = try String(
            contentsOf: Self.packageURL("PodcastTranscript")
                .appendingPathComponent("PROVENANCE.md"),
            encoding: .utf8)
        #expect(payload.contains("model-download") == false)
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

    /// The reviewed YouTube transcript package: manifest revision 5 (the
    /// `wantsAgentCleanup` claim, issue #1379) with protocol revision 3, one
    /// `youtube-transcript` registration over the synthetic `video/youtube`
    /// MIME, and the `network` capability only. Media download and
    /// speech-to-text are not registered.
    @Test func youtubeTranscriptRevisionMatchesGolden() throws {
        let output = try validate("YouTubeTranscript")

        #expect(output.packageID == "org.selfdrivingwiki.youtube-transcript")
        #expect(output.protocolRevision == 3)
        #expect(output.registrationIDs == ["captions"])

        let manifest = try manifest("YouTubeTranscript")
        #expect(manifest.manifestRevision == .v5)
        let registration = try #require(manifest.registrations.first)
        #expect(registration.kinds == [.youtubeTranscript])
        #expect(registration.mimeTypes == [try ExtractorMIMEType(validating: "video/youtube")])
        #expect(registration.credentialRequirements.isEmpty)
        // Issue #1379: the raw auto-captions want the host's best-effort
        // agent cleanup pass after they land.
        #expect(registration.wantsAgentCleanup)
        // Network for the caption fetch; shared-runtime-cache keeps uv's
        // CPython install and wheel cache warm across operations.
        #expect(manifest.capabilities == [.network, .sharedRuntimeCache])
        #expect(manifest.limits.maximumDurationMilliseconds == 600_000)
        guard case .runtime(let command, let arguments) = manifest.launch else {
            Issue.record("youtube-transcript must launch through a runtime")
            return
        }
        #expect(command.rawValue == "uv")
        #expect(arguments == ["run", "--script"])

        // The exact reviewed identity is pinned byte-for-byte; a regenerated
        // package whose digest changed fails this gate with the new value.
        #expect(output.packageDigest
            == "8baac5e4c4d78a6869a0acf2ca9d1bf7503f65a7a5c61889aab33df492347a52")
    }

    /// The reviewed YouTube package never claims model download: it fetches
    /// captions YouTube exposes and does nothing else. The shared runtime
    /// cache keeps its uv runtime warm across operations.
    @Test func youtubeTranscriptDeclaresNoModelCapabilities() throws {
        let manifest = try manifest("YouTubeTranscript")
        #expect(manifest.capabilities.contains(.modelDownload) == false)
        #expect(manifest.capabilities.contains(.sharedRuntimeCache))
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

        // The yt-dlp fallback route: the "trying the caption fallback"
        // progress step and the yt-dlp tool provenance on the result.
        let fallback = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("YouTubeTranscript").path,
            request,
            fixtures.appendingPathComponent("frames-ytdlp-fallback.jsonl").path,
        ])
        #expect(fallback.terminalKind == "result")
        #expect(fallback.progressEventCount == 4)
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

    /// The reviewed Zotero package: manifest revision 4 with the FETCHER
    /// role (no operation kinds — its claims are the synthetic source MIME),
    /// protocol revision 5 (typed fetch results), a REQUIRED credential
    /// requirement, and the acquisition-only capability set. The package
    /// downloads attachments; it never converts formats.
    @Test func zoteroPackageValidatesFetcherContract() throws {
        let output = try validate("Zotero")

        #expect(output.packageID == "org.selfdrivingwiki.zotero")
        #expect(output.protocolRevision == 5)
        #expect(output.registrationIDs == ["attachment"])

        let manifest = try manifest("Zotero")
        #expect(manifest.manifestRevision == .v4)
        let registration = try #require(manifest.registrations.first)
        // Fetcher: role declared by the package, no kinds, and the claimed
        // input MIME set is exactly the synthetic source route.
        #expect(registration.role == .fetcher)
        #expect(registration.kinds.isEmpty)
        #expect(registration.mimeTypes == [try ExtractorMIMEType(validating: "application/zotero")])
        #expect(registration.filenameExtensions.isEmpty)
        // The API key is REQUIRED: acquisition cannot proceed without it.
        let requirements = registration.credentialRequirements
        #expect(requirements.map(\.id.rawValue) == ["zotero-api-key"])
        #expect(requirements.allSatisfy { !$0.isOptional && $0.kind == .secret })
        // The sync declaration is the package's declared acquisition surface:
        // the config sidecar, the file-endpoint URL template, and the
        // 8-character A-Z0-9 attachment-key list. The declared source MIME
        // is one of this fetcher's claimed input MIME types. Nothing
        // host-side knows these facts.
        let sync = try #require(registration.sync)
        #expect(sync.configFileName == "zotero-config.json")
        #expect(sync.urlTemplate == "https://api.zotero.org/users/{libraryID}/items/{itemKey}/file")
        #expect(sync.fields.map(\.name) == ["libraryID", "attachments"])
        #expect(sync.fields.map(\.isRequired) == [true, true])
        #expect(sync.fields.last?.isList == true)
        #expect(sync.itemValidation?.minimumLength == 8)
        #expect(sync.itemValidation?.maximumLength == 8)
        #expect(sync.itemValidation?.alphabet == "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        #expect(sync.sourceMIMEType == registration.mimeTypes.first)
        // Acquisition only: network (REQUIRED for a fetcher) + shared
        // runtime cache, no model.
        #expect(manifest.capabilities == [.network, .sharedRuntimeCache])
        #expect(manifest.capabilities.contains(.modelDownload) == false)
        #expect(manifest.limits.maximumMarkdownOutputByteCount == 134_217_728)
        #expect(manifest.limits.maximumDurationMilliseconds == 600_000)
        guard case .runtime(let command, let arguments) = manifest.launch else {
            Issue.record("zotero must launch through a runtime")
            return
        }
        #expect(command.rawValue == "uv")
        #expect(arguments == ["run", "--script"])

        // The exact reviewed identity is pinned byte-for-byte; a regenerated
        // package whose digest changed fails this gate with the new value.
        #expect(output.packageDigest
            == "ecd2466df32e81a5347caee9b30b75b9fc9672b9429f4f406c3045d6ae0f9f7a")

        // Secret-free bytes: the declared requirement is a review fact; a
        // value or a reference binding must never be committed.
        let manifestData = try Data(contentsOf: Self.packageURL("Zotero")
            .appendingPathComponent("manifest.json"))
        let payload = String(decoding: manifestData, as: UTF8.self)
        #expect(payload.contains("credentialReference") == false)
        #expect(payload.contains("credential_locations") == false)
    }

    /// AC.3: the recorded source-bytes result frame sequence from the
    /// committed bundle replays through `protocol-smoke` — the revision-5
    /// fetch request plus an explicit `source-bytes` result frame carrying
    /// `resultMIMEType`, `originalFilename`, and
    /// `articleMetadata.identifier`, and the sequence accepts them for a
    /// revision-5 fetch request.
    @Test func zoteroRecordedProtocolFramesReplayThroughProtocolSmoke() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Zotero", isDirectory: true)

        let success = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("Zotero").path,
            fixtures.appendingPathComponent("request.json").path,
            fixtures.appendingPathComponent("frames.jsonl").path,
        ])
        #expect(success.packageID == "org.selfdrivingwiki.zotero")
        #expect(success.terminalKind == "result")
        #expect(success.progressEventCount == 2)
    }

    /// The revision-5 fetch fields are revision-scoped: replaying the same
    /// result frames against a forged revision-4 extractor request fails
    /// the sequence (the older-host fail-closed rule — a revision-4 request
    /// can never carry a `resultType` tag, and a v4 request is not a fetch).
    @Test func zoteroFetchResultFramesRejectRevision4Request() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Zotero", isDirectory: true)
        let request = try Data(contentsOf: fixtures.appendingPathComponent("request.json"))
        let v4Request = String(decoding: request, as: UTF8.self)
            .replacing("\"protocolRevision\": 5", with: "\"protocolRevision\": 4")
        let v4URL = fixtures.appendingPathComponent("request-v4.json")
        try v4Request.write(to: v4URL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: v4URL) }

        #expect(throws: ExtractorPackageToolFailure.self) {
            try ExtractorPackageToolExecutor().execute(arguments: [
                "protocol-smoke",
                Self.packageURL("Zotero").path,
                v4URL.path,
                fixtures.appendingPathComponent("frames.jsonl").path,
            ])
        }
    }

    /// The reviewed audio-acquire package: manifest revision 4 with the
    /// FETCHER role (no operation kinds — its claim is the synthetic
    /// `audio/x-wiki-audio-acquire` source MIME), protocol revision 5 with
    /// a typed `source-bytes` result declaring `audio/mp4`, and the
    /// acquisition-only capability set. The package downloads ONE audio
    /// stream for the speech arm's transient analysis; it never converts
    /// formats, never runs speech-to-text, and never stores audio as a
    /// source blob.
    @Test func audioAcquireRevisionMatchesGolden() throws {
        let output = try validate("AudioAcquire")

        #expect(output.packageID == "org.selfdrivingwiki.audio-acquire")
        #expect(output.protocolRevision == 5)
        #expect(output.registrationIDs == ["audio"])

        let manifest = try manifest("AudioAcquire")
        #expect(manifest.manifestRevision == .v4)
        let registration = try #require(manifest.registrations.first)
        // Fetcher: role declared by the package, no kinds, and the claimed
        // input MIME set is exactly the synthetic source route.
        #expect(registration.role == .fetcher)
        #expect(registration.kinds.isEmpty)
        #expect(registration.mimeTypes == [try ExtractorMIMEType(validating: "audio/x-wiki-audio-acquire")])
        #expect(registration.filenameExtensions.isEmpty)
        #expect(registration.credentialRequirements.isEmpty)
        // Acquisition only: network (REQUIRED for a fetcher) + shared
        // runtime cache, no model.
        #expect(manifest.capabilities == [.network, .sharedRuntimeCache])
        #expect(manifest.capabilities.contains(.modelDownload) == false)
        // The output bound stays ABOVE the package's 120 MiB download cap,
        // and the 30-minute duration bound covers a full-length download.
        #expect(manifest.limits.maximumMarkdownOutputByteCount == 134_217_728)
        #expect(manifest.limits.maximumMarkdownOutputByteCount > 120 * 1024 * 1024)
        #expect(manifest.limits.maximumDurationMilliseconds == 1_800_000)
        guard case .runtime(let command, let arguments) = manifest.launch else {
            Issue.record("audio-acquire must launch through a runtime")
            return
        }
        #expect(command.rawValue == "uv")
        #expect(arguments == ["run", "--script"])

        // The exact reviewed identity is pinned byte-for-byte; a regenerated
        // package whose digest changed fails this gate with the new value.
        #expect(output.packageDigest
            == "2c27524ed9ebe8869c348e5ee084b7a6258d4595156e216e3f900d9a07d4a910")
    }

    /// The recorded audio-acquire protocol frames replay through the
    /// revision-5 sequence: progress frames, then one terminal `result`
    /// carrying the `source-bytes` tag and the concrete `audio/mp4` MIME.
    @Test func audioAcquireProtocolSmoke() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AudioAcquire", isDirectory: true)

        let success = try ExtractorPackageToolExecutor().execute(arguments: [
            "protocol-smoke",
            Self.packageURL("AudioAcquire").path,
            fixtures.appendingPathComponent("request.json").path,
            fixtures.appendingPathComponent("frames.jsonl").path,
        ])
        #expect(success.packageID == "org.selfdrivingwiki.audio-acquire")
        #expect(success.terminalKind == "result")
        #expect(success.progressEventCount == 5)
    }

    @Test func reviewedDigestsAreStableAcrossRepeatedValidation() throws {
        for name in ["Defuddle", "Pdf2md", "DoclingServe", "Docx2md", "PodcastTranscript", "ApplePodcastTranscript", "YouTubeTranscript", "Zotero"] {
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
        let zotero = try manifest("Zotero")

        #expect(defuddle.registrations.allSatisfy { $0.kinds == [.html] })
        #expect(pdf2md.registrations.allSatisfy { $0.kinds == [.pdf] })
        #expect(docx2md.registrations.allSatisfy { $0.kinds == [.docx] })
        #expect(podcast.registrations.allSatisfy { $0.kinds == [.podcastTranscript] })
        #expect(applePodcast.registrations.allSatisfy { $0.kinds == [.applePodcastTranscript] })
        #expect(youtube.registrations.allSatisfy { $0.kinds == [.youtubeTranscript] })
        // Zotero is the fetcher member: no kind at all — its claims are the
        // synthetic source MIME set.
        #expect(zotero.registrations.allSatisfy { $0.role == .fetcher && $0.kinds.isEmpty })
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
