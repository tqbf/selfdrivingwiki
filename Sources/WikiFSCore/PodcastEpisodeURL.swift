#if PODCAST_TRANSCRIPTS  // Apple Podcasts transcript feature; off for WIKIFS_APP_STORE=1 builds.
import Foundation

/// Recognizes Apple Podcasts *episode* URLs pasted as sources — PURE, value-in /
/// value-out, so the recognizer is unit-tested without any network.
///
/// An episode link looks like
/// `https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453`:
/// the numeric `i` query parameter is the EPISODE ID (what the AMP transcript
/// endpoint wants); the `id…` path segment is the *show* ID, which we don't need.
/// The `/podcast/<slug>/` path segment gives a human-readable stem for the stored
/// transcript's filename. A show link without `i=` is NOT an episode — `parse`
/// returns nil and the caller falls through to the normal HTML ingest path.
///
/// See `plans/podcast-transcripts.md`.
public enum PodcastEpisodeURL {

    /// A recognized episode: the numeric episode ID plus the URL's show slug
    /// (nil when the path carries none).
    public struct EpisodeRef: Equatable, Sendable {
        public let id: String
        public let slug: String?

        public init(id: String, slug: String? = nil) {
            self.id = id
            self.slug = slug
        }
    }

    /// Parse raw pasted text into an `EpisodeRef`, or nil when it isn't an Apple
    /// Podcasts episode link. Reuses `URLFetchService.normalizeURL` so the same
    /// pastes the sheet accepts (whitespace, missing scheme) are recognized here.
    public static func parse(_ raw: String) -> EpisodeRef? {
        guard let url = URLFetchService.normalizeURL(raw),
              let host = url.host?.lowercased(),
              host == "podcasts.apple.com" || host.hasSuffix(".podcasts.apple.com"),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "i" })?.value,
              !id.isEmpty, id.allSatisfy(\.isNumber)
        else { return nil }
        return EpisodeRef(id: id, slug: slug(fromPath: url.pathComponents))
    }

    /// The show slug is the path component after `podcast`
    /// (`/us/podcast/chinatalk/id1289062927` → `chinatalk`); nil when absent or
    /// when the next component is already the `id…` show-ID segment.
    private static func slug(fromPath parts: [String]) -> String? {
        guard let idx = parts.firstIndex(of: "podcast"), idx + 1 < parts.count else {
            return nil
        }
        let candidate = parts[idx + 1]
        guard !candidate.isEmpty, !candidate.hasPrefix("id") else { return nil }
        return candidate
    }
}
#endif
