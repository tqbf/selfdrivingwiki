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
/// **Always compiled** (no `#if PODCAST_TRANSCRIPTS` guard) so the generic
/// `.podcast` path can reach `EpisodeRef` (C1 in `plans/podcast-generalize.md`).
/// The `parse`/`displayTitle` helpers are Apple-specific but pure + harmless —
/// they're only CALLED from the gated Apple ingest path, so unguarding them
/// doesn't enable Apple ingest on App Store builds (the `addURL` overload that
/// calls them is itself gated).
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

    /// Convert an `EpisodeRef.slug` into a human-readable, title-cased display
    /// name. The slug is a hyphen-separated, ASCII-stemmed form of the episode
    /// title Apple generates at link-time: `if-you-care-about-food-…-land` →
    /// `If You Care About Food You Have to Care About Land`. Pure, runs
    /// offline, and is reused by the refresh path so the title stays consistent
    /// across re-pastes.
    ///
    /// Returns nil when `slug` is nil/empty/whitespace — so the caller falls
    /// back to the synthetic filename display name (mirrors the oEmbed best-
    /// effort discipline for YouTube/Vimeo/Spotify/SoundCloud). The caller is
    /// expected to run the result through `WikiNameRules.sanitized` before any
    /// `setSourceDisplayName` write (the same invariant every display-name
    /// write honors).
    ///
    /// Issue #621.
    public static func displayTitle(from slug: String?) -> String? {
        let trimmed = slug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        // Split on `-` and drop empties (consecutive / leading / trailing
        // hyphens). `URL.pathComponents` already percent-decodes the slug, so
        // non-ASCII characters arrive intact — no extra decoding needed here.
        // Real Apple URL slugs never contain whitespace (the `/` separator
        // carries hyphen-joined ASCII words); the additional whitespace filter
        // is defensive so the helper never returns a whitespace-only "title".
        let words: [String] = trimmed
            .split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !words.isEmpty else { return nil }
        return titleCase(words: words).joined(separator: " ")
    }

    /// Title-case `words` preserving the lowercase form of small connector
    /// words (a/an/the/and/but/or/…/to/…) unless they are the first word —
    /// matches AP-style title casing so the result reads like an episode title
    /// rather than a slug-with-spaces. Naive `String.capitalized`
    /// over-capitalizes "to"/"about"/"the" (#621 risk note).
    private static func titleCase(words: [String]) -> [String] {
        // Lowercased once so we lowercase-initial any short mixed-case slug
        // input. The slug is assumed all-lowercase ASCII (the form Apple
        // generates), but defensively normalizing keeps the function usable for
        // round-tripped inputs.
        let smallWords: Set<String> = [
            "a", "an", "the", "and", "but", "or", "for", "nor", "on", "at",
            "to", "from", "by", "of", "in", "as", "vs", "vs.", "via"
        ]
        return words.enumerated().map { index, raw -> String in
            let word = raw.lowercased()
            guard !word.isEmpty else { return raw }
            if index != 0, smallWords.contains(word) {
                return word
            }
            // Capitalize the first character only — don't `.capitalized` the
            // whole word, which would mangle Apple-style "iPhone" stems or
            // force trailing caps on already-cased input.
            return word.prefix(1).uppercased() + word.dropFirst()
        }
    }
}
