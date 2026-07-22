import Foundation

/// Recognizes a **direct RSS podcast feed URL** pasted as a source — PURE,
/// value-in / value-out, so the recognizer is unit-tested without any network.
///
/// Unlike `PodcastEpisodeURL` (which recognizes Apple Podcasts *episode* links),
/// this recognizer validates that a raw URL is a plausible RSS feed URL. It is
/// the intake-side validation for the generic `.podcast` provider (any RSS
/// feed, not just Apple). The actual feed fetch + `<podcast:transcript>` parse
/// happens later in the `podcast-transcript` Python script (triggered by the
/// Transcribe button), NOT at ingest.
///
/// **The ambiguity problem (§3 of the plan):** a raw URL like
/// `https://example.com/ep42` could be a feed OR a webpage — pure URL parsing
/// can't tell. So this recognizer is NOT wired into the generic `addURL` paste
/// path (which would silently misdetect feeds). Instead, the caller explicitly
/// invokes `addPodcastFeedURL(_:)` — a dedicated intake entry point (M3) —
/// which uses this recognizer for validation + slug extraction only.
///
/// Always compiled (no `#if PODCAST_TRANSCRIPTS` guard) — the generic `.podcast`
/// path works on every build. Issue podcast-generalize.
public struct RSSFeedEpisodeRef: Equatable, Sendable {
    /// The raw RSS feed URL (e.g. `https://feeds.example.com/show.xml`).
    public let feedURL: URL
    /// An optional episode GUID to locate a specific `<item>` (nil → latest).
    public let episodeGUID: String?
    /// An optional display stem derived from the feed URL's host + path
    /// (used for the byteless-source filename).
    public let slug: String?

    public init(feedURL: URL, episodeGUID: String? = nil, slug: String? = nil) {
        self.feedURL = feedURL
        self.episodeGUID = episodeGUID
        self.slug = slug
    }
}

public enum RSSFeedEpisodeURL {

    /// Parse raw pasted text into an `RSSFeedEpisodeRef`, or nil when the URL
    /// is missing/invalid. Reuses `URLFetchService.normalizeURL` so the same
    /// pastes the sheet accepts (whitespace, missing scheme) are recognized here.
    ///
    /// A URL is considered a plausible feed candidate if its path ends in
    /// `.xml`/`.rss`/`.atom` OR it has an http(s) scheme with a non-empty host
    /// (the explicit "Add podcast feed" affordance declares intent, so we accept
    /// any http(s) URL and let the script validate the actual feed content).
    public static func parse(_ raw: String) -> RSSFeedEpisodeRef? {
        guard let url = URLFetchService.normalizeURL(raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return RSSFeedEpisodeRef(
            feedURL: url,
            episodeGUID: nil,
            slug: slug(from: url))
    }

    /// Derive a human-readable display stem from the feed URL's host + last
    /// path component. E.g. `https://feeds.example.com/show.xml` → `show`.
    /// Nil when the URL has no usable path component.
    static func slug(from url: URL) -> String? {
        let last = url.lastPathComponent
        guard !last.isEmpty else {
            // No path component — use the host stem (without www. / TLD).
            return readableHost(url.host)
        }
        let stem = (last as NSString).deletingPathExtension
        return stem.isEmpty ? readableHost(url.host) : stem
    }

    /// Strip `www.` and the TLD from a host for a readable stem.
    /// `feeds.example.com` → `example`. Returns nil for unparseable hosts.
    private static func readableHost(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        let cleaned = host.replacingOccurrences(of: "www.", with: "")
        let parts = cleaned.split(separator: ".")
        // parts: ["feeds", "example", "com"] → "example" (second-to-last).
        guard parts.count >= 2 else { return cleaned }
        return String(parts[parts.count - 2])
    }
}
