import Foundation

/// Best-effort provider display-title fetcher for **byteless** media-embed
/// sources (YouTube/Vimeo/Spotify/SoundCloud). Uses each provider's public
/// oEmbed endpoint — a single JSON GET that returns `{"title","author_name"}`
/// — so a pasted `youtube.com/watch?v=…` URL shows the real video title as the
/// source's display name instead of a synthetic `youtube-<id>`.
///
/// **Never blocks ingest.** `title(for:fetcher:)` swallows every failure
/// (network, non-2xx, malformed JSON) and returns `nil`, so a missing/unreached
/// oEmbed just leaves the synthetic name in place (mirrors the
/// `YouTubeTranscriptService` best-effort discipline). The GET runs via the
/// injected `URLFetchService.URLResourceFetcher` seam — CI uses a fake, the app
/// uses `URLSessionFetcher` — so the call site can keep it off the main actor.
///
/// Issue #572 (YouTube/Vimeo URL ingest UX).
public enum MediaTitleFetcher {

    /// The oEmbed-provided title for `match.planURL`, or `nil` on any failure
    /// (non-2xx, network error, decode failure, unsupported provider). Pure
    /// dispatch + the fetch; never throws.
    public static func title(
        for match: MediaEmbedMatch,
        fetcher: any URLFetchService.URLResourceFetcher
    ) async -> String? {
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
        return parseTitle(from: data)
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
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = obj["title"] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
