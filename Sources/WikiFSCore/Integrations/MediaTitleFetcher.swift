import Foundation

/// Best-effort provider display-title fetcher for **byteless** media-embed
/// sources (YouTube/Vimeo/Spotify/SoundCloud). Uses each provider's public
/// oEmbed endpoint — a single JSON GET that returns `{"title","author_name"}`
/// — so a pasted `youtube.com/watch?v=…` URL shows the real video title as the
/// source's display name instead of a synthetic `youtube-<id>`.
///
/// **Never blocks ingest.** Every entry point swallows each failure
/// (network, non-2xx, malformed JSON) and returns `nil`, so a missing/unreached
/// oEmbed just leaves the synthetic name in place (mirrors the
/// `YouTubeTranscriptService` best-effort discipline). The GET runs via the
/// injected `URLFetchService.URLResourceFetcher` seam — CI uses a fake, the app
/// uses `URLSessionFetcher` — so the call site can keep it off the main actor.
///
/// Issue #572 (YouTube/Vimeo URL ingest UX). Issue #646 extends the decoder to
/// surface the full oEmbed metadata (author, provider, thumbnail, description,
/// duration) so `MediaMarkdownSynthesizer` can render a readable synthetic
/// markdown page for byteless sources.
public enum MediaTitleFetcher {

    /// Best-effort oEmbed metadata for a byteless media match. Every field is
    /// optional — providers vary in what they return. Issue #646.
    public struct MediaOEmbedMetadata: Sendable, Equatable {
        public let title: String?
        public let authorName: String?
        public let authorURL: String?
        public let providerName: String?
        public let thumbnailURL: String?
        public let descriptionText: String?
        /// Duration in seconds, when the provider includes it (Vimeo does).
        public let durationSeconds: Int?

        public init(
            title: String?,
            authorName: String?,
            authorURL: String?,
            providerName: String?,
            thumbnailURL: String?,
            descriptionText: String?,
            durationSeconds: Int?
        ) {
            self.title = title
            self.authorName = authorName
            self.authorURL = authorURL
            self.providerName = providerName
            self.thumbnailURL = thumbnailURL
            self.descriptionText = descriptionText
            self.durationSeconds = durationSeconds
        }
    }

    /// The oEmbed-provided title for `match.planURL`, or `nil` on any failure
    /// (non-2xx, network error, decode failure, unsupported provider). Pure
    /// dispatch + the fetch; never throws.
    public static func title(
        for match: MediaEmbedMatch,
        fetcher: any URLFetchService.URLResourceFetcher
    ) async -> String? {
        // Thin wrapper over `metadata(for:fetcher:)` so the title-only callers
        // (existing tests, the display-name step) keep their simple contract.
        await metadata(for: match, fetcher: fetcher).flatMap { trim($0.title) }
    }

    /// The full oEmbed metadata blob for `match.planURL`, or `nil` on any
    /// failure (non-2xx, network error, decode failure, unsupported provider).
    /// Pure dispatch + the fetch + JSON decode; never throws. Issue #646.
    public static func metadata(
        for match: MediaEmbedMatch,
        fetcher: any URLFetchService.URLResourceFetcher
    ) async -> MediaOEmbedMetadata? {
        guard let oembedURL = oembedURL(for: match) else { return nil }
        let data: Data
        do {
            let resp = try await fetcher.fetch(oembedURL)
            guard !resp.data.isEmpty else { return nil }
            data = resp.data
        } catch {
            DebugLog.ingest("MediaTitleFetcher: oEmbed fetch failed (\(match.agentName)): \(error.localizedDescription)")
            return nil
        }
        return parseMetadata(from: data)
    }

    /// Build the oEmbed endpoint URL for the provider's pasted URL, or `nil`
    /// when the provider has no oEmbed (or is `remote-media`). Pure.
    public static func oembedURL(for match: MediaEmbedMatch) -> URL? {
        // Percent-encode the pasted URL as a single query value. `.urlQueryAllowed`
        // leaves the pasted URL's own `://`, `?`, `&` literal — those would split
        // the oEmbed request query (a YouTube watch URL's `&t=` would steal the
        // trailing `&format=json`). Strip the path/query delimiters from the
        // allowed set so the whole pasted URL becomes one opaque value.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?&=#")
        guard let encoded = match.planURL.addingPercentEncoding(
            withAllowedCharacters: allowed) else { return nil }
        switch match.agentName {
        case "youtube":
            return URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json")
        case "vimeo":
            return URL(string: "https://vimeo.com/api/oembed.json?url=\(encoded)")
        case "spotify":
            return URL(string: "https://open.spotify.com/oembed?url=\(encoded)")
        case "soundcloud":
            return URL(string: "https://soundcloud.com/oembed?format=json&url=\(encoded)")
        default:
            return nil
        }
    }

    /// Parse the `title` field from an oEmbed JSON blob. Every provider above
    /// returns a top-level `{"title": "…", "author_name": "…"}`. Pure; returns
    /// `nil` for empty/absent/undecodable titles.
    public static func parseTitle(from data: Data) -> String? {
        trim((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["title"] as? String)
    }

    /// Parse the full oEmbed metadata blob from a JSON response. Tolerant of
    /// missing fields — every property is optional. Pure; returns `nil` only
    /// when the bytes aren't a JSON object at all. Issue #646.
    public static func parseMetadata(from data: Data) -> MediaOEmbedMetadata? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return MediaOEmbedMetadata(
            title: trim(obj["title"] as? String),
            authorName: trim(obj["author_name"] as? String),
            authorURL: trim(obj["author_url"] as? String),
            providerName: trim(obj["provider_name"] as? String),
            thumbnailURL: trim(obj["thumbnail_url"] as? String),
            descriptionText: trim(obj["description"] as? String),
            // Vimeo returns `duration` as a number (seconds). Other providers
            // omit it. `Int(any)` accepts Int/NSNumber/Double-as-Int safely.
            durationSeconds: duration(from: obj["duration"]))
    }

    /// Coerce oEmbed `duration` (Vimeo returns Int; some providers send a
    /// numeric string) into seconds. Returns `nil` when absent / unparsable.
    private static func duration(from value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    /// Trim + reject-whitespace-only strings so a `"   "` title is treated as
    /// missing. Pure.
    private static func trim(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
