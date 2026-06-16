import Foundation

/// Rewrites recognized file-share "preview" links to their direct-download URL —
/// PURE, so it is unit-tested value-in/value-out and wired into the real fetch.
///
/// WHY this exists: file-share hosts hand non-browser clients an HTML *landing
/// page* (a JS interstitial), not the file, unless you hit the direct-download
/// host. A Dropbox share link like
/// `https://www.dropbox.com/scl/fi/<id>/Report.pdf?rlkey=…&dl=0` returns 200
/// `text/html` (the interstitial) even with `dl=1`; rewriting the host to
/// `dl.dropboxusercontent.com` (same path + query) returns the raw `%PDF` bytes
/// with the right `.pdf` filename in the path. Google Drive and OneDrive behave
/// the same way.
///
/// Design: a list of provider `Rule`s, each `(matches:, rewrite:)`. `normalize`
/// returns the FIRST rule's rewrite, else the URL UNCHANGED. Conservative on
/// purpose — we only touch hosts we recognize, so an unknown URL passes through
/// byte-for-byte. Adding Google Drive / OneDrive is just another `Rule`.
public enum ShareLinkNormalizer {

    /// A single provider's recognize-and-rewrite rule. Both closures are pure.
    struct Rule: Sendable {
        /// True when this rule recognizes `url` as one of its share links.
        let matches: @Sendable (URL) -> Bool
        /// The direct-download URL for a recognized share link.
        let rewrite: @Sendable (URL) -> URL
    }

    /// Provider rules, tried in order. Only Dropbox is implemented today; the
    /// commented shapes below show how Google Drive / OneDrive slot in.
    static let rules: [Rule] = [dropbox]

    /// Rewrite a recognized share link to its direct-download URL; pass anything
    /// else through unchanged.
    public static func normalize(_ url: URL) -> URL {
        for rule in rules where rule.matches(url) {
            return rule.rewrite(url)
        }
        return url
    }

    // MARK: - Dropbox

    /// Dropbox: `www.dropbox.com` / `dropbox.com` → `dl.dropboxusercontent.com`,
    /// preserving the path + query (so the `.pdf` filename in the path survives and
    /// `rlkey`/`e` query params still authorize the download). This is the
    /// verified-working rewrite that returns the raw file bytes instead of the
    /// JS interstitial that `dl=0` AND `dl=1` both serve to non-browsers.
    static let dropbox = Rule(
        matches: { url in
            guard let host = url.host?.lowercased() else { return false }
            return host == "www.dropbox.com" || host == "dropbox.com"
        },
        rewrite: { url in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            components.host = "dl.dropboxusercontent.com"
            return components.url ?? url
        })

    // MARK: - Future providers (shapes only — not yet wired into `rules`)

    // Google Drive: `drive.google.com/file/d/<ID>/view` →
    //   `drive.google.com/uc?export=download&id=<ID>`
    // Match host `drive.google.com` with a `/file/d/<ID>/` path; pull `<ID>` from
    // the path and emit the `uc?export=download&id=<ID>` direct URL.
    //
    // OneDrive: `1drv.ms/...` or `onedrive.live.com/...` share links →
    // the direct download form (append `&download=1`, or follow the
    // `redir?…` → `download?…` rewrite). Add as another `Rule` here.
}
