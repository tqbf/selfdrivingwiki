import Foundation
import Testing
@testable import WikiFSCore

/// Unit tests for the YouTube video → transcript pipeline (no network). The
/// watch-page fetch + caption download are behind a fake `URLResourceFetcher`
/// that returns canned HTML/JSON; the player-response extraction + track
/// selection + parse logic are exercised directly. Issue #564.
struct YouTubeTranscriptServiceTests {

    // MARK: - Fakes

    /// A fetcher that returns canned responses keyed by URL substring. Mirrors
    /// the podcast tests' `FakeHTTP`.
    final class FakeFetcher: URLFetchService.URLResourceFetcher, @unchecked Sendable {
        let responses: [String: URLFetchService.FetchResponse]
        private(set) var requestedURLs: [String] = []

        init(_ responses: [String: URLFetchService.FetchResponse]) {
            self.responses = responses
        }

        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            requestedURLs.append(url.absoluteString)
            for (key, response) in responses {
                if url.absoluteString.contains(key) { return response }
            }
            throw URLFetchService.FetchError.network("no canned response for \(url.absoluteString)")
        }
    }

    // MARK: - Player response extraction (pure)

    static let watchPageHTML = """
    <!DOCTYPE html><html><head><title>Talk Title</title></head><body>
    <script>var ytInitialPlayerResponse = {
        "videoDetails": {"title": "Talk Title", "videoId": "dQw4w9WgXcQ"},
        "captions": {
            "playerCaptionsTracklistRenderer": {
                "captionTracks": [
                    {"baseUrl": "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en",
                     "languageCode": "en", "name": {"simpleText": "English"}},
                    {"baseUrl": "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=es",
                     "languageCode": "es", "name": {"simpleText": "Spanish"}}
                ]
            }
        }
    };</script>
    </body></html>
    """

    static let captionXML = """
    <?xml version="1.0" encoding="utf-8" ?>
    <transcript>
        <text start="0.5" dur="2.3">Hello world</text>
        <text start="2.8" dur="1.5">This is a transcript</text>
    </transcript>
    """

    @Test func extractsPlayerResponseFromHTML() throws {
        let pr = try YouTubeTranscriptService.extractPlayerResponse(
            from: Data(Self.watchPageHTML.utf8))
        #expect(pr.videoDetails?.title == "Talk Title")
        let tracks = try #require(pr.captionTracks)
        #expect(tracks.count == 2)
        #expect(tracks[0].languageCode == "en")
    }

    @Test func playerResponseNotFoundWhenMissing() {
        let html = "<html><body>no player response here</body></html>"
        #expect(throws: YouTubeTranscriptError.playerResponseNotFound) {
            try YouTubeTranscriptService.extractPlayerResponse(from: Data(html.utf8))
        }
    }

    // MARK: - Track selection (pure)

    @Test func prefersManualEnglishTrack() {
        let tracks = [
            track(lang: "es"),
            track(lang: "en"),      // manual English
            track(lang: "en", kind: "asr"),
        ]
        let best = YouTubeTranscriptService.bestTrack(tracks)
        #expect(best.languageCode == "en")
        #expect(best.kind == nil)   // manual, not ASR
    }

    @Test func fallsBackToEnglishASR() {
        let tracks = [
            track(lang: "es"),
            track(lang: "en", kind: "asr"),
        ]
        let best = YouTubeTranscriptService.bestTrack(tracks)
        #expect(best.languageCode == "en")
        #expect(best.kind == "asr")
    }

    @Test func fallsBackToFirstAvailable() {
        let tracks = [
            track(lang: "fr"),
            track(lang: "de"),
        ]
        let best = YouTubeTranscriptService.bestTrack(tracks)
        #expect(best.languageCode == "fr")
    }

    private func track(lang: String, kind: String? = nil) -> YouTubeTranscriptService.PlayerResponse.CaptionTrack {
        YouTubeTranscriptService.PlayerResponse.CaptionTrack(
            baseUrl: "https://example.com/\(lang)", languageCode: lang,
            kind: kind, name: nil)
    }

    // MARK: - Full flow (canned fetcher)

    @Test func fullFlowProducesTranscriptMarkdown() async throws {
        let fetcher = FakeFetcher([
            "watch?v=": URLFetchService.FetchResponse(
                data: Data(Self.watchPageHTML.utf8), contentType: "text/html",
                finalURL: URL(string: "https://youtube.com/watch?v=dQw4w9WgXcQ")!),
            "timedtext": URLFetchService.FetchResponse(
                data: Data(Self.captionXML.utf8), contentType: "text/xml",
                finalURL: URL(string: "https://youtube.com/api/timedtext")!),
        ])
        let service = YouTubeTranscriptService(fetcher: fetcher)
        let transcript = try await service.transcript(forVideoID: "dQw4w9WgXcQ")

        #expect(transcript.videoID == "dQw4w9WgXcQ")
        #expect(transcript.title == "Talk Title")
        #expect(transcript.markdown.contains("Hello world"))
        #expect(transcript.markdown.contains("This is a transcript"))
        #expect(transcript.markdown.contains("[Watch on YouTube]"))
        #expect(transcript.filename == "Talk Title-dQw4w9WgXcQ-transcript.md")
    }

    @Test func noCaptionsThrowsNoCaptions() async {
        let html = """
        <script>var ytInitialPlayerResponse = {
            "videoDetails": {"title": "Restricted"},
            "captions": {"playerCaptionsTracklistRenderer": {"captionTracks": []}}
        };</script>
        """
        let fetcher = FakeFetcher([
            "watch?v=": URLFetchService.FetchResponse(
                data: Data(html.utf8), contentType: "text/html",
                finalURL: URL(string: "https://youtube.com/watch?v=dQw4w9WgXcQ")!),
        ])
        let service = YouTubeTranscriptService(fetcher: fetcher)
        await #expect(throws: YouTubeTranscriptError.noCaptions) {
            _ = try await service.transcript(forVideoID: "dQw4w9WgXcQ")
        }
    }

    @Test func invalidVideoIDThrows() async {
        let service = YouTubeTranscriptService()
        await #expect(throws: YouTubeTranscriptError.network(_)) {
            _ = try await service.transcript(forVideoID: "tooshort")
        }
    }

    @Test func fallsBackToXMLWhenJSON3Fails() async throws {
        // JSON3 fetch will fail (no canned response keyed on fmt=json3), so it
        // should fall back to the XML-typed caption response.
        let fetcher = FakeFetcher([
            "watch?v=": URLFetchService.FetchResponse(
                data: Data(Self.watchPageHTML.utf8), contentType: "text/html",
                finalURL: URL(string: "https://youtube.com/watch?v=dQw4w9WgXcQ")!),
            // The base timedtext URL (without fmt=json3) returns XML.
            "timedtext?": URLFetchService.FetchResponse(
                data: Data(Self.captionXML.utf8), contentType: "text/xml",
                finalURL: URL(string: "https://youtube.com/api/timedtext")!),
        ])
        let service = YouTubeTranscriptService(fetcher: fetcher)
        let transcript = try await service.transcript(forVideoID: "dQw4w9WgXcQ")
        #expect(transcript.markdown.contains("Hello world"))
    }

    // MARK: - ID validation + filename

    @Test func isValidVideoID() {
        #expect(YouTubeTranscriptService.isValidVideoID("dQw4w9WgXcQ"))
        #expect(!YouTubeTranscriptService.isValidVideoID("tooshort"))
        #expect(!YouTubeTranscriptService.isValidVideoID("contains!bad"))
    }

    @Test func filenameEscapesTitle() {
        let name = YouTubeTranscriptService.filename(for: "Great Talk / Part 1", videoID: "dQw4w9WgXcQ")
        #expect(name == "Great Talk - Part 1-dQw4w9WgXcQ-transcript.md")
    }

    @Test func headerContainsTitleAndLink() {
        let header = YouTubeTranscriptService.header(for: "My Video", videoID: "dQw4w9WgXcQ")
        #expect(header.contains("# My Video"))
        #expect(header.contains("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    // MARK: - Error descriptions

    @Test func errorDescriptionsAreReadable() {
        #expect(YouTubeTranscriptError.noCaptions.errorDescription == "This video has no captions.")
        #expect(YouTubeTranscriptError.badResponse(500).errorDescription == "YouTube returned HTTP 500.")
        #expect(YouTubeTranscriptError.playerResponseNotFound.errorDescription?.contains("restricted") == true)
    }

    // MARK: - JSON3 flow (preferred format)

    @Test func prefersJSON3WhenAvailable() async throws {
        let json3 = """
        {"events":[
            {"tStartMs":500,"dDurationMs":2300,"segs":[{"utf8":"Hello world"}]},
            {"tStartMs":2800,"dDurationMs":1500,"segs":[{"utf8":"Second cue"}]}
        ]}
        """
        let fetcher = FakeFetcher([
            "watch?v=": URLFetchService.FetchResponse(
                data: Data(Self.watchPageHTML.utf8), contentType: "text/html",
                finalURL: URL(string: "https://youtube.com/watch?v=dQw4w9WgXcQ")!),
            "fmt=json3": URLFetchService.FetchResponse(
                data: Data(json3.utf8), contentType: "application/json",
                finalURL: URL(string: "https://youtube.com/api/timedtext?fmt=json3")!),
        ])
        let service = YouTubeTranscriptService(fetcher: fetcher)
        let transcript = try await service.transcript(forVideoID: "dQw4w9WgXcQ")
        #expect(transcript.markdown.contains("Hello world"))
        #expect(transcript.markdown.contains("Second cue"))
        // JSON3 fetch was attempted (fmt=json3 in the request).
        #expect(fetcher.requestedURLs.contains { $0.contains("fmt=json3") })
    }
}
