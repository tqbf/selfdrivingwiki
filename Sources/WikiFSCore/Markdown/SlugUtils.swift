import Foundation

/// Shared slug *base* for the two slug callers in the app:
/// - `SQLiteWikiStore.slugify` (page-title slugs → DB `pages.slug`)
/// - `AnchorBlock.makeSlug` (in-memory heading anchor ids)
///
/// `slugBase` is the pure normalization both share: lowercase → whitespace→`-`
/// → keep letters/numbers/`-` → collapse `-` runs (and trim the ends). Each caller
/// then adds its own empty-fallback (`"untitled"` / `"heading"`) and suffix logic
/// (ULID dedup / `-N` dedup) on top — that differing tail is why this is *base*-only.
///
/// Behaviour note: this matches `AnchorBlock.makeSlug`'s Unicode-permissive
/// normalization (all whitespace → `-`; any `.isLetter`/`.isNumber` kept, not just
/// ASCII). `slugify` previously dropped non-ASCII letters and ignored most
/// whitespace; it now keeps them too. Existing page slugs in the DB are unchanged
/// (read verbatim); only newly-created/renamed titles get the normalized slug.
/// `PodcastEpisodeURL.slug` is path-based and deliberately separate — not here.
///
/// See issue #502 (cross-module dedup, L3).
enum SlugUtils {

    static func slugBase(_ s: String) -> String {
        String(
            s.lowercased()
                .map { $0.isWhitespace ? "-" : $0 }
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
                .split(separator: "-", omittingEmptySubsequences: true)
                .joined(separator: "-")
        )
    }
}
