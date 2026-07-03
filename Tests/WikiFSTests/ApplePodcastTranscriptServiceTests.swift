#if PODCAST_TRANSCRIPTS  // Feature off for WIKIFS_APP_STORE=1 builds.
import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the AMP response decoding (`ApplePodcastAMP`) and the service
/// orchestration (`ApplePodcastTranscriptService`) — driven by fakes, no network,
/// no private frameworks. The AMP fixture mirrors the REAL captured response shape.
struct ApplePodcastTranscriptServiceTests {

    // MARK: - AMP decoding (pure)

    /// Trimmed from the real captured AMP response for the ChinaTalk episode.
    static let ampJSON = """
        {"data":[{"id":"1000774368453-0","type":"transcripts","attributes":{
        "ttmlAssetUrls":{"ttml":"https://podcasts.itunes.apple.com/itunes-assets/x/transcript_1000774368453.ttml?accessKey=abc"},
        "ttmlToken":"x/transcript_1000774368453.ttml"}}]}
        """

    @Test func decodesTTMLURLFromRealShape() throws {
        let url = try ApplePodcastAMP.ttmlURL(fromStatus: 200, body: Data(Self.ampJSON.utf8))
        #expect(url.absoluteString.hasSuffix("transcript_1000774368453.ttml?accessKey=abc"))
    }

    @Test func status40012MapsToInsufficientPermissions() {
        let body = Data(#"{"errors":[{"code":"40012","title":"Insufficient Permissions"}]}"#.utf8)
        #expect(throws: PodcastTranscriptError.insufficientPermissions) {
            try ApplePodcastAMP.ttmlURL(fromStatus: 400, body: body)
        }
    }

    @Test func emptyDataMapsToNoTranscript() {
        #expect(throws: PodcastTranscriptError.noTranscriptAvailable) {
            try ApplePodcastAMP.ttmlURL(fromStatus: 200, body: Data(#"{"data":[]}"#.utf8))
        }
    }

    @Test func otherBadStatusMapsToBadResponse() {
        #expect(throws: PodcastTranscriptError.badResponse(503)) {
            try ApplePodcastAMP.ttmlURL(fromStatus: 503, body: Data())
        }
    }

    @Test func requestCarriesBearerAndQuery() {
        let req = ApplePodcastAMP.request(episodeID: "1000774368453", token: "eyABC")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer eyABC")
        let url = req.url!.absoluteString
        #expect(url.contains("/podcast-episodes/1000774368453/transcripts"))
        #expect(url.contains("with=entitlements"))
    }

    // MARK: - Fakes

    final class FakeTokens: PodcastTokenProviding, @unchecked Sendable {
        var tokens: [String]           // returned in order per call
        private(set) var forceRefreshCalls: [Bool] = []
        var error: PodcastTranscriptError?
        init(tokens: [String], error: PodcastTranscriptError? = nil) {
            self.tokens = tokens; self.error = error
        }
        func bearerToken(forceRefresh: Bool) async throws -> String {
            forceRefreshCalls.append(forceRefresh)
            if let error { throw error }
            return tokens.isEmpty ? "eyDEFAULT" : tokens.removeFirst()
        }
    }

    final class FakeHTTP: PodcastHTTPClient, @unchecked Sendable {
        /// AMP responses returned in order, one per `send`.
        var ampResponses: [(status: Int, body: Data)]
        var ttmlResponse: (status: Int, body: Data)
        private(set) var sentTokens: [String] = []
        init(amp: [(status: Int, body: Data)], ttml: (status: Int, body: Data)) {
            self.ampResponses = amp; self.ttmlResponse = ttml
        }
        func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
            if let auth = request.value(forHTTPHeaderField: "Authorization") {
                sentTokens.append(auth)
            }
            return ampResponses.isEmpty ? (500, Data()) : ampResponses.removeFirst()
        }
        func download(_ url: URL) async throws -> (status: Int, body: Data) { ttmlResponse }
    }

    static let ttmlFixture = Data(TTMLTranscriptTests.fixture.utf8)

    // MARK: - Orchestration

    static let chinaTalk = PodcastEpisodeURL.EpisodeRef(id: "1000774368453", slug: "chinatalk")

    @Test func happyPathReturnsMarkdownTranscript() async throws {
        let tokens = FakeTokens(tokens: ["eyGOOD"])
        let http = FakeHTTP(
            amp: [(200, Data(Self.ampJSON.utf8))],
            ttml: (200, Self.ttmlFixture))
        let service = ApplePodcastTranscriptService(tokens: tokens, http: http)

        let transcript = try await service.transcript(for: Self.chinaTalk)

        #expect(transcript.episodeID == "1000774368453")
        #expect(transcript.filename == "chinatalk-1000774368453-transcript.md")
        #expect(transcript.markdown.contains("SPEAKER_1: Welcome to WarTalk."))
        #expect(http.sentTokens == ["Bearer eyGOOD"])
    }

    @Test func insufficientPermissionsTriggersOneForcedRefreshAndRetries() async throws {
        let tokens = FakeTokens(tokens: ["eySTALE", "eyFRESH"])
        // First AMP call: 40012. Second (after refresh): 200.
        let http = FakeHTTP(
            amp: [
                (400, Data(#"{"errors":[{"code":"40012"}]}"#.utf8)),
                (200, Data(Self.ampJSON.utf8)),
            ],
            ttml: (200, Self.ttmlFixture))
        let service = ApplePodcastTranscriptService(tokens: tokens, http: http)

        let transcript = try await service.transcript(for: Self.chinaTalk)

        #expect(transcript.markdown.contains("Welcome to WarTalk."))
        #expect(tokens.forceRefreshCalls == [false, true])  // exactly one forced refresh
        #expect(http.sentTokens == ["Bearer eySTALE", "Bearer eyFRESH"])
    }

    @Test func stillInsufficientAfterRefreshSurfacesTheError() async throws {
        let tokens = FakeTokens(tokens: ["eySTALE", "eyALSOSTALE"])
        let http = FakeHTTP(
            amp: [
                (400, Data(#"{"errors":[{"code":"40012"}]}"#.utf8)),
                (400, Data(#"{"errors":[{"code":"40012"}]}"#.utf8)),
            ],
            ttml: (200, Self.ttmlFixture))
        let service = ApplePodcastTranscriptService(tokens: tokens, http: http)

        await #expect(throws: PodcastTranscriptError.insufficientPermissions) {
            try await service.transcript(for: Self.chinaTalk)
        }
    }

    @Test func signatureFailurePropagates() async throws {
        let tokens = FakeTokens(tokens: [], error: .signatureUnavailable("no framework"))
        let http = FakeHTTP(amp: [(200, Data())], ttml: (200, Data()))
        let service = ApplePodcastTranscriptService(tokens: tokens, http: http)

        await #expect(throws: PodcastTranscriptError.signatureUnavailable("no framework")) {
            try await service.transcript(for: Self.chinaTalk)
        }
    }

    @Test func ttmlDownloadNon200IsBadResponse() async throws {
        let tokens = FakeTokens(tokens: ["eyGOOD"])
        let http = FakeHTTP(amp: [(200, Data(Self.ampJSON.utf8))], ttml: (404, Data()))
        let service = ApplePodcastTranscriptService(tokens: tokens, http: http)

        await #expect(throws: PodcastTranscriptError.badResponse(404)) {
            try await service.transcript(for: Self.chinaTalk)
        }
    }

    @Test func filenameFallsBackWhenNoSlug() {
        let ref = PodcastEpisodeURL.EpisodeRef(id: "999", slug: nil)
        #expect(ApplePodcastTranscriptService.filename(for: ref) == "podcast-999-transcript.md")
    }
}
#endif
