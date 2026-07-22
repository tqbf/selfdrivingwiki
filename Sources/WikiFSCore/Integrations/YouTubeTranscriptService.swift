import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The finished transcript for a YouTube video: video ID, markdown text, and a
/// suggested source filename. Mirrors `PodcastTranscript`.
public struct YouTubeTranscript: Equatable, Sendable {
    public let videoID: String
    public let title: String
    public let markdown: String
    public let filename: String

    public init(videoID: String, title: String, markdown: String, filename: String) {
        self.videoID = videoID
        self.title = title
        self.markdown = markdown
        self.filename = filename
    }
}

/// The one thing ingest calls: video ID → transcript. Injected so `WikiStoreModel`
/// (Add from URL) and tests can substitute a fake. Mirrors
/// `PodcastTranscriptFetching`.
public protocol YouTubeTranscriptFetching: Sendable {
    func transcript(forVideoID videoID: String) async throws -> YouTubeTranscript
}

/// Errors for the YouTube video → transcript pipeline, user-readable so the
/// Add-from-URL sheet can surface them directly. Mirrors
/// `PodcastTranscriptError`.
public enum YouTubeTranscriptError: Error, LocalizedError, Equatable {
    /// The video page or caption download returned a non-2xx status.
    case badResponse(Int)
    /// `ytInitialPlayerResponse` wasn't found in the watch page HTML (YouTube
    /// changed the page, or the video is age/restricted/region-locked).
    case playerResponseNotFound
    /// The video has no caption tracks at all.
    case noCaptions
    /// The caption bytes didn't parse into any cues.
    case parseFailed
    /// A network or transport failure carrying the underlying message.
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "YouTube returned HTTP \(code)."
        case .playerResponseNotFound:
            return "Couldn't read this video's data (YouTube page changed or the video is restricted)."
        case .noCaptions:
            return "This video has no captions."
        case .parseFailed:
            return "The video's captions couldn't be parsed."
        case .network(let msg):
            return msg
        }
    }
}

/// Fetches a YouTube transcript via the public watch page → caption track flow:
/// no API key, no OAuth. The pipeline is:
///   1. Fetch the watch page HTML (`/watch?v=<id>`) with a desktop User-Agent.
///   2. Extract `ytInitialPlayerResponse` JSON from the inline `<script>`.
///   3. Read `captions.playerCaptionsTracklistRenderer.captionTracks`.
///   4. Pick the English (or first available) track's `baseUrl`.
///   5. Fetch the caption content (timedtext XML/JSON3) from the base URL.
///   6. Parse it with `TimedTextTranscript` → markdown.
///
/// Every HTTP leg is behind the injected `URLResourceFetcher` (production =
/// `URLSessionFetcher`), so the orchestration is unit-tested with canned
/// responses — no real network. Issue #564.
///
/// The fetch runs off-main (the caller is expected to dispatch it on a
/// detached task, mirroring `ApplePodcastMaterializer`); this service itself
/// performs no actor hops.
public struct YouTubeTranscriptService: YouTubeTranscriptFetching {

    private let fetcher: any URLFetchService.URLResourceFetcher

    public init(fetcher: any URLFetchService.URLResourceFetcher = URLSessionFetcher()) {
        self.fetcher = fetcher
    }

    public func transcript(forVideoID videoID: String) async throws -> YouTubeTranscript {
        // Guard the 11-char id shape, mirroring `MediaEmbedURL.isValidYouTubeID`.
        guard Self.isValidVideoID(videoID) else {
            throw YouTubeTranscriptError.network("\"\(videoID)\" isn't a valid YouTube video ID.")
        }

        // 1. Fetch the watch page HTML.
        let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        let watchResponse = try await fetch(watchURL)
        guard !(watchResponse.data.isEmpty) else { throw YouTubeTranscriptError.badResponse(0) }

        // 2. Extract the player response JSON from the HTML.
        let playerResponse = try Self.extractPlayerResponse(from: watchResponse.data)

        // 3. Find the caption tracks + the video title.
        guard let captionTracks = playerResponse.captionTracks,
              !captionTracks.isEmpty else {
            throw YouTubeTranscriptError.noCaptions
        }
        let title = playerResponse.videoDetails?.title ?? "youtube-\(videoID)"

        // 4. Pick the best track: English manual, then English ASR, then first.
        let track = Self.bestTrack(captionTracks)

        // 5. Fetch the caption content. Prefer JSON3 (structured), fall back to
        //    the base URL's default (XML).
        let cues: [TimedTextTranscript.Cue]
        do {
            cues = try await fetchCues(from: track.baseUrl, preferJSON3: true)
        } catch {
            cues = try await fetchCues(from: track.baseUrl, preferJSON3: false)
        }
        guard !cues.isEmpty else { throw YouTubeTranscriptError.parseFailed }

        // 6. Render markdown.
        let transcript = TimedTextTranscript(cues: cues)
        let markdown = Self.header(for: title, videoID: videoID)
            + transcript.markedText
        return YouTubeTranscript(
            videoID: videoID,
            title: title,
            markdown: markdown,
            filename: Self.filename(for: title, videoID: videoID))
    }

    // MARK: - HTTP

    private func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
        do {
            return try await fetcher.fetch(url)
        } catch let e as URLFetchService.FetchError {
            throw YouTubeTranscriptError.network(e.localizedDescription)
        } catch {
            throw YouTubeTranscriptError.network(error.localizedDescription)
        }
    }

    /// Fetch a caption track URL and parse its cues. `preferJSON3` appends
    /// `&fmt=json3` to request the structured JSON3 format; otherwise the base
    /// URL is fetched as-is (default timedtext XML).
    private func fetchCues(from baseURL: String, preferJSON3: Bool) async throws -> [TimedTextTranscript.Cue] {
        let urlString: String
        if preferJSON3, !baseURL.contains("fmt=") {
            urlString = baseURL + (baseURL.contains("?") ? "&fmt=json3" : "?fmt=json3")
        } else {
            urlString = baseURL
        }
        guard let url = URL(string: urlString) else {
            throw YouTubeTranscriptError.network("The caption URL wasn't valid.")
        }
        let response = try await fetch(url)
        guard !response.data.isEmpty else { throw YouTubeTranscriptError.parseFailed }
        return try TimedTextTranscript.parse(response.data).cues
    }

    // MARK: - Player response extraction (pure, testable)

    /// The decoded subset of `ytInitialPlayerResponse` we care about.
    struct PlayerResponse: Decodable {
        struct VideoDetails: Decodable { let title: String? }
        struct CaptionTrack: Decodable {
            let baseUrl: String
            let languageCode: String?
            let kind: String?      // "asr" = auto-generated
            let name: NameContainer?
            struct NameContainer: Decodable { let simpleText: String? }
        }
        struct CaptionList: Decodable { let captionTracks: [CaptionTrack]? }
        struct Captions: Decodable {
            let playerCaptionsTracklistRenderer: CaptionList?
        }
        let videoDetails: VideoDetails?
        let captions: Captions?
        var captionTracks: [CaptionTrack]? {
            captions?.playerCaptionsTracklistRenderer?.captionTracks
        }
    }

    /// Pull the `ytInitialPlayerResponse = {...};` JSON out of the watch page
    /// HTML and decode the subset we need. YouTube embeds it in a
    /// `<script>var ytInitialPlayerResponse = {…};</script>` block.
    static func extractPlayerResponse(from html: Data) throws -> PlayerResponse {
        let text = String(data: html, encoding: .utf8)
            ?? String(data: html, encoding: .isoLatin1)
            ?? ""
        let json = try extractPlayerResponseJSON(from: text)
        do {
            return try JSONDecoder().decode(PlayerResponse.self, from: Data(json.utf8))
        } catch {
            throw YouTubeTranscriptError.playerResponseNotFound
        }
    }

    /// Extract the raw JSON string between `ytInitialPlayerResponse = ` and the
    /// matching `};` (YouTube terminates the assignment with `;` on its own or
    /// before `</script>`). Handles both `var ytInitialPlayerResponse = {` and
    /// `window["ytInitialPlayerResponse"] = {`.
    static func extractPlayerResponseJSON(from html: String) throws -> String {
        // Find the assignment start. YouTube uses several spellings; match the
        // key name plus `=` then the opening brace.
        let markers = [
            "ytInitialPlayerResponse",
        ]
        var startIdx: String.Index?
        for marker in markers {
            if let range = html.range(of: "\(marker)") {
                // Find the `=` after the marker, then the `{` after that.
                guard let eqRange = html.range(of: "=", range: range.upperBound..<html.endIndex),
                      let braceRange = html.range(of: "{", range: eqRange.upperBound..<html.endIndex)
                else { continue }
                startIdx = braceRange.lowerBound
                break
            }
        }
        guard let start = startIdx else { throw YouTubeTranscriptError.playerResponseNotFound }

        // Walk the brace depth from the opening `{` to find the matching `}`.
        var depth = 0
        var inString = false
        var escaped = false
        var end = html.index(after: start)
        var idx = start
        while idx < html.endIndex {
            let ch = html[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = html.index(after: idx)
                        break
                    }
                }
            }
            idx = html.index(after: idx)
        }
        let json = String(html[start..<end])
        guard json.contains("\"captionTracks\"") || json.contains("\"playerCaptionsTracklistRenderer\"")
                || json.contains("\"videoDetails\"") else {
            throw YouTubeTranscriptError.playerResponseNotFound
        }
        return json
    }

    /// Pick the best caption track: a manual English track first, then an
    /// English ASR (auto-generated) track, then the first available track.
    static func bestTrack(_ tracks: [PlayerResponse.CaptionTrack]) -> PlayerResponse.CaptionTrack {
        if let english = tracks.first(where: {
            $0.languageCode.map { Self.isEnglish($0) } == true && $0.kind != "asr"
        }) { return english }
        if let englishASR = tracks.first(where: {
            $0.languageCode.map { Self.isEnglish($0) } == true
        }) { return englishASR }
        return tracks[0]
    }

    /// Whether a language code is English (`en`, `en-US`, `en-GB`, …).
    static func isEnglish(_ code: String) -> Bool {
        code.lowercased().hasPrefix("en")
    }

    // MARK: - Filename / header

    /// `<escaped-title>-<videoId>-transcript.md`, mirroring the podcast
    /// convention (`<slug>-<id>-transcript.md`).
    static func filename(for title: String, videoID: String) -> String {
        let stem = "\(FilenameEscaping.escapeTitle(title))-\(videoID)"
        return "\(stem)-transcript.md"
    }

    /// A small markdown header for the transcript source — the video title + a
    /// YouTube link, so the rendered reader shows context above the transcript.
    static func header(for title: String, videoID: String) -> String {
        let escaped = FilenameEscaping.escapeTitle(title)
        return "# \(escaped)\n\n[Watch on YouTube](https://www.youtube.com/watch?v=\(videoID))\n\n"
    }

    /// YouTube video IDs are exactly 11 chars from `[A-Za-z0-9_-]`.
    static func isValidVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
