import Foundation

// MARK: - SourceEmbedDescriptor

/// A batched, value-type projection of the fields a **byteless** source needs to
/// render an external embed in the page reader — the byteless analogue of the
/// per-source `SourceOrigin` (joined active version → activity → agent) but
/// restricted to the columns the embed dispatch cares about, and returned for
/// *all* byteless sources in one query (`embedDescriptors()`).
///
/// Carries no statement handle / column pointer — pure values only — so it is
/// `Sendable` and can cross the detached render task boundary (sqlite-concurrency
/// discipline: no connection state crosses a method boundary).
///
/// See `plans/graph-model-and-versioning.md` §7 (byteless + `external_identity`
/// → provider-shaped embed) and §4.2/§4.3 (byteless sources, PROV).
public struct SourceEmbedDescriptor: Sendable, Equatable {
    public let id: PageID
    /// The active content version's MIME type. For provider embeds this is a
    /// *synthetic* mime (`video/youtube`, `audio/spotify`, …); for direct-remote
    /// media it is a real mime (`audio/mpeg`, `video/mp4`, …).
    public let mimeType: String?
    /// `source_versions.external_identity` — the provider-specific id/URL.
    /// YouTube/Vimeo = the video id; Spotify = `<type>/<id>`; SoundCloud = the
    /// full track URL; direct-remote = the media URL. Apple Podcasts does NOT
    /// use this (it builds its embed from `planURL`).
    public let externalIdentity: String?
    /// `agents.name` — the provider agent (`youtube`, `vimeo`, `apple-podcast`,
    /// `remote-media`, …). Used to key the Apple Podcasts row.
    public let agentName: String?
    /// `activities.plan` — the recipe. For Apple Podcasts this is the episode
    /// page URL the embed host-swap operates on; for providers/direct-remote it
    /// is the pasted URL.
    public let planURL: String?

    public init(
        id: PageID,
        mimeType: String?,
        externalIdentity: String?,
        agentName: String?,
        planURL: String?
    ) {
        self.id = id
        self.mimeType = mimeType
        self.externalIdentity = externalIdentity
        self.agentName = agentName
        self.planURL = planURL
    }
}

// MARK: - WikiReaderOrigin

/// The synthetic https origin the page reader's WKWebView document is loaded
/// under (`loadHTMLString(baseURL:)`). YouTube's embedded player rejects an
/// embed whose parent document has no real origin (opaque `null` under an
/// `about:blank` base) with **error 153** — so the reader document needs a real
/// origin AND the YouTube embed URL must carry a matching `?origin=` param.
///
/// Defined here — in the same file as the embed-URL builder that stamps
/// `?origin=` — so the URL the iframe points at and the `baseURL` the reader
/// loads the wrapping document under can never drift out of lock-step. The host
/// is a private synthetic name (not a real site); it only has to be a
/// syntactically valid https origin that the reader and the embed agree on.
public enum WikiReaderOrigin {
    /// The origin string, e.g. stamped into `?origin=` on the YouTube embed URL.
    /// Uses `.invalid` (RFC 2606) so the host **never** resolves — `.local` is
    /// mDNS/Bonjour-resolvable, so a device on the LAN could advertise this name
    /// and intercept stray relative fetches/XHRs from the reader document.
    /// YouTube's `?origin=` check is a string comparison against
    /// `window.location.origin`, not a DNS lookup, so `.invalid` satisfies it.
    public static let string = "https://reader.wikifs.invalid"
    /// The same origin as a `URL`, for `loadHTMLString(baseURL:)`.
    public static var url: URL? { URL(string: string) }
}

// MARK: - ExternalEmbed (pure dispatch table)

/// Pure, store-free dispatch from a `SourceEmbedDescriptor` to an `EmbedTarget`.
/// This is the single table the page reader consults to decide whether a
/// byteless source renders an external embed (and what element/URL), instead of
/// falling back to a cite link.
///
/// Order is load-bearing: **provider synthetic mimes are matched exactly first**
/// (so `video/youtube` / `audio/spotify` never reach the generic
/// `hasPrefix("audio/")` / `("video/")` direct-remote rows), then the Apple
/// Podcasts `agentName` row, then the direct-remote real-mime rows. A descriptor
/// that matches none of these returns `nil` → the caller renders a cite link.
///
/// Three consumer flavors, one table:
/// - **Provider iframes** (Phase 3): synthetic mime → provider embed URL.
/// - **Direct-remote media** (Phase 2): real `audio/*`/`video/*` mime + the URL.
/// - **Apple Podcasts player** (Phase 4): `agentName == "apple-podcast"` +
///   host-swapped `planURL`.
public enum ExternalEmbed {

    /// Resolve an embed target for a byteless source descriptor, or `nil` when
    /// the source is not a renderable external embed.
    public static func target(for d: SourceEmbedDescriptor) -> EmbedTarget? {
        let mime = d.mimeType ?? ""

        // 1. Provider synthetic mimes → provider-player iframe URLs.
        switch mime {
        case MimeType.videoYouTube:
            guard let id = d.externalIdentity, !id.isEmpty else { return nil }
            // Privacy-enhanced host (no tracking cookies) — but the player 153-errors
            // unless the embed carries the reader's origin. `enablejsapi=1` lets the
            // player postMessage back to the parent; `origin`/`widget_referrer` name
            // the reader origin the parent document is actually loaded under
            // (`WikiReaderOrigin` → the WKWebView baseURL). Percent-encode the `://`
            // in the origin value so it survives as a single query value (mirrors the
            // SoundCloud track-URL encoding below).
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: ":/")
            let origin = WikiReaderOrigin.string.addingPercentEncoding(withAllowedCharacters: allowed)
                ?? WikiReaderOrigin.string
            var url = "https://www.youtube-nocookie.com/embed/\(id)"
                + "?enablejsapi=1&origin=\(origin)&widget_referrer=\(origin)"
            // Resume at the pasted timestamp: a `&t=…` (or `?start=…`) on the watch
            // URL maps to the embed's `?start=<seconds>`. YouTube accepts integer
            // seconds; the watch URL may use the `1h2m30s` clock form.
            if let start = youTubeStartTime(from: d.planURL) {
                url += "&start=\(start)"
            }
            return EmbedTarget(kind: .iframe, url: url)
        case "video/vimeo":
            guard let id = d.externalIdentity, !id.isEmpty else { return nil }
            return EmbedTarget(kind: .iframe, url: "https://player.vimeo.com/video/\(id)")
        case "audio/spotify":
            // externalIdentity is "<type>/<id>" (track|episode|podcast), mirrored
            // verbatim into the embed path.
            guard let path = d.externalIdentity, !path.isEmpty else { return nil }
            return EmbedTarget(kind: .iframe, url: "https://open.spotify.com/embed/\(path)")
        case "audio/soundcloud":
            // externalIdentity is the full track URL; the player needs it as a
            // query value, so encode the reserved chars (`:`, `/`) that
            // `.urlQueryAllowed` would otherwise leave literal.
            guard let trackURL = d.externalIdentity, !trackURL.isEmpty else { return nil }
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: ":/")
            let encoded = trackURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? trackURL
            return EmbedTarget(kind: .iframe, url: "https://w.soundcloud.com/player/?url=\(encoded)")
        default:
            break
        }

        // 2. Apple Podcasts player: host-swap the stored episode page URL.
        // Keyed on agentName (not a synthetic mime) because the podcast source
        // carries a real-ish mime from the transcript pipeline. Idempotent: a
        // planURL already on embed.podcasts.apple.com resolves unchanged.
        if d.agentName == "apple-podcast", let embedURL = applePodcastEmbedURL(from: d.planURL) {
            return EmbedTarget(kind: .iframe, url: embedURL)
        }

        // 3. Direct-remote media: a REAL audio/video mime + the media URL.
        // Synthetic provider mimes were handled above, so by here any
        // `audio/*` / `video/*` is a genuine direct-remote URL. HLS manifests
        // carry an `application/*` mime but play in a native <video>.
        if mime == "application/vnd.apple.mpegurl" || mime == "application/x-mpegurl",
           let url = d.externalIdentity, !url.isEmpty {
            return EmbedTarget(kind: .video, url: url)
        }
        if mime.hasPrefix("audio/"), let url = d.externalIdentity, !url.isEmpty {
            return EmbedTarget(kind: .audio, url: url)
        }
        if mime.hasPrefix("video/"), let url = d.externalIdentity, !url.isEmpty {
            return EmbedTarget(kind: .video, url: url)
        }

        return nil
    }

    // MARK: - YouTube start time

    /// Parse a resume offset (in whole seconds) from a YouTube watch URL's
    /// `t` / `start` query parameter, handling the clock form YouTube emits
    /// (`569s`, `1m30s`, `1h2m30s`) and a bare integer. Returns `nil` when the
    /// URL carries no timestamp or it can't be parsed. Pure.
    ///
    /// The watch URL's `t` is NOT what the embed accepts — the embed wants an
    /// integer `start` — so this normalizes both forms into seconds.
    static func youTubeStartTime(from planURL: String?) -> Int? {
        guard let raw = planURL,
              let url = URL(string: raw),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return nil }
        // `t` is the link-sharing form; `start` is the embed form some links carry.
        let value = items.first(where: { $0.name == "t" })?.value
            ?? items.first(where: { $0.name == "start" })?.value
        guard let value, !value.isEmpty else { return nil }
        // Bare integer seconds (`569` or `569s`): drop a single trailing `s` and
        // confirm the remainder parses as the whole value.
        if value.hasSuffix("s") || value.allSatisfy(\.isNumber) {
            let digits = value.hasSuffix("s") ? String(value.dropLast()) : value
            if let secs = Int(digits) {
                return secs
            }
        }
        return parseClockDuration(value)
    }

    /// Parse a clock-form duration (`569s`, `1m30s`, `1h2m30s`, `90m`) into
    /// seconds. Each group is `<n>` followed by `h`/`m`/`s`; a bare trailing
    /// number with no unit is treated as seconds. Returns `nil` on a malformed
    /// value (e.g. a unit that isn't h/m/s). Pure.
    private static func parseClockDuration(_ value: String) -> Int? {
        var total = 0
        var number = ""
        var sawUnit = false
        let units = ["h": 3600, "m": 60, "s": 1]
        for ch in value {
            if ch.isNumber {
                number.append(ch)
            } else {
                guard let n = Int(number), n >= 0, let mult = units[String(ch)] else { return nil }
                total += n * mult
                number = ""
                sawUnit = true
            }
        }
        // A trailing number with no unit is seconds (YouTube allows `t=120`).
        if !number.isEmpty {
            guard let n = Int(number), n >= 0 else { return nil }
            total += n
        }
        return sawUnit || total > 0 ? total : nil
    }

    /// Host-swap an Apple Podcasts episode page URL to its embed URL:
    /// `podcasts.apple.com` (or `*.podcasts.apple.com`) →
    /// `embed.podcasts.apple.com`, keeping the full path + `?i=<episodeId>`
    /// query intact. Returns `nil` (graceful: transcript still renders) when
    /// there is no planURL or the host can't be swapped.
    private static func applePodcastEmbedURL(from planURL: String?) -> String? {
        guard let raw = planURL,
              let url = URL(string: raw),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else { return nil }
        // Accept the canonical host OR a per-region subhost
        // (e.g. `us.podcasts.apple.com`); reject anything else so a non-Apple
        // planURL never produces a bogus embed.
        let embedHost: String
        if host == "podcasts.apple.com" {
            embedHost = "embed.podcasts.apple.com"
        } else if host.hasSuffix(".podcasts.apple.com") {
            // Strip the regional subhost and use the canonical embed host.
            embedHost = "embed.podcasts.apple.com"
        } else if host == "embed.podcasts.apple.com" {
            // Already an embed URL — idempotent.
            embedHost = host
        } else {
            return nil
        }
        // Rebuild the URL with the swapped host, preserving path + query.
        // The query MUST keep `?i=<episodeId>` for the embed to resolve.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = embedHost
        return components?.url?.absoluteString
    }
}
