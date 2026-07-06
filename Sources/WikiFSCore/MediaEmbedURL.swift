import Foundation

/// Pure, network-free URL recognizers that classify a pasted URL into a byteless
/// external-embed source. Each recognizer parses the URL (no network), and on a
/// match returns the `MediaEmbedMatch` carrying everything `addBytelessSource`
/// needs (agent name, synthetic/real MIME, external identity, filename, the
/// pasted URL as `planURL`). On no match it returns `nil` so `addURL` routing
/// falls through to the next recognizer.
///
/// Phase 4b — see `plans/graph-model-and-versioning.md` §7 (byteless +
/// `external_identity` → provider-shaped embed). Three flavors share one shape:
/// provider iframes (YouTube/Vimeo/Spotify/SoundCloud), direct-remote media
/// (mp3/mp4/HLS), and the Apple Podcasts player (which needs no recognizer —
/// its byteless sources already exist from the transcript pipeline).

/// The materialized descriptor a recognizer returns — enough to call
/// `addBytelessSource` and report a `FetchOutcome.Kind`. Pure values only.
public struct MediaEmbedMatch: Sendable, Equatable {
    /// Provider agent name (`youtube`, `vimeo`, `spotify`, `soundcloud`,
    /// `remote-media`).
    public let agentName: String
    /// Synthetic mime for providers (`video/youtube`, `audio/spotify`, …) or a
    /// real mime for direct-remote (`audio/mpeg`, `video/mp4`, `application/vnd.apple.mpegurl`).
    public let mimeType: String
    /// `source_versions.external_identity`: the provider id/path or the media URL.
    public let externalIdentity: String
    /// The source filename (shown in the Sources list + used for name resolution).
    public let filename: String
    /// The pasted URL, stored as `activities.plan` (the recipe). For Apple
    /// Podcasts the embed host-swap operates on this; for providers it's the
    /// canonical pasted link.
    public let planURL: String
    /// `activities.kind` — `"fetch"` for providers, `"import"` for direct-remote.
    public let activityKind: String

    public init(agentName: String, mimeType: String, externalIdentity: String,
                filename: String, planURL: String, activityKind: String) {
        self.agentName = agentName
        self.mimeType = mimeType
        self.externalIdentity = externalIdentity
        self.filename = filename
        self.planURL = planURL
        self.activityKind = activityKind
    }
}

public enum MediaEmbedURL {

    // MARK: - Provider iframes (Phase 3)

    /// Recognize a YouTube URL (`watch?v=`, `youtu.be/<id>`, `/embed/<id>`,
    /// `/shorts/<id>`). Extracts the 11-char video id and validates its shape.
    /// Returns `nil` for non-YouTube hosts or a malformed id.
    public static func youtube(_ raw: String) -> MediaEmbedMatch? {
        guard let url = URLFetchService.normalizeURL(raw) else { return nil }
        guard let host = url.host?.lowercased(),
              host == "youtube.com" || host == "www.youtube.com"
                  || host == "m.youtube.com" || host == "youtu.be"
        else { return nil }

        let id: String
        if host == "youtu.be" {
            // youtu.be/<id>
            id = lastPath(url)
        } else if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  comps.path.lowercased().hasSuffix("/watch"),
                  let v = comps.queryItems?.first(where: { $0.name == "v" })?.value,
                  !v.isEmpty {
            // youtube.com/watch?v=<id>
            id = v
        } else if let segs = pathSegments(url), segs.count >= 2,
                  (segs[0].lowercased() == "embed" || segs[0].lowercased() == "shorts") {
            // youtube.com/embed/<id> or youtube.com/shorts/<id>
            id = segs[1]
        } else {
            return nil
        }

        // Validate the 11-char id shape ([A-Za-z0-9_-]).
        guard isValidYouTubeID(id) else { return nil }
        let absolute = url.absoluteString
        return MediaEmbedMatch(
            agentName: "youtube",
            mimeType: "video/youtube",
            externalIdentity: id,
            filename: "youtube-\(id)",
            planURL: absolute,
            activityKind: "fetch")
    }

    /// Recognize a Vimeo URL (`vimeo.com/<numeric id>`). Returns `nil` for
    /// non-Vimeo hosts or a non-numeric path.
    public static func vimeo(_ raw: String) -> MediaEmbedMatch? {
        guard let url = URLFetchService.normalizeURL(raw) else { return nil }
        guard let host = url.host?.lowercased(),
              host == "vimeo.com" || host == "www.vimeo.com" || host == "player.vimeo.com"
        else { return nil }
        guard let segs = pathSegments(url), !segs.isEmpty else { return nil }
        // The id is the first numeric path segment (skip /video/ if present).
        let id = segs.first { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        guard let id, !id.isEmpty else { return nil }
        let absolute = url.absoluteString
        return MediaEmbedMatch(
            agentName: "vimeo",
            mimeType: "video/vimeo",
            externalIdentity: id,
            filename: "vimeo-\(id)",
            planURL: absolute,
            activityKind: "fetch")
    }

    /// Recognize a Spotify URL (`open.spotify.com/<track|episode|podcast>/<id>`).
    /// Keeps the `<type>/<id>` so the embed path mirrors it. Returns `nil` for a
    /// non-Spotify host or a path that doesn't match the type/id shape.
    public static func spotify(_ raw: String) -> MediaEmbedMatch? {
        guard let url = URLFetchService.normalizeURL(raw) else { return nil }
        guard let host = url.host?.lowercased(),
              host == "open.spotify.com" || host == "www.open.spotify.com"
        else { return nil }
        guard let segs = pathSegments(url), segs.count >= 2 else { return nil }
        let type = segs[0].lowercased()
        guard ["track", "episode", "podcast"].contains(type) else { return nil }
        let id = segs[1]
        guard !id.isEmpty else { return nil }
        let absolute = url.absoluteString
        return MediaEmbedMatch(
            agentName: "spotify",
            mimeType: "audio/spotify",
            externalIdentity: "\(type)/\(id)",
            filename: "spotify-\(type)-\(id)",
            planURL: absolute,
            activityKind: "fetch")
    }

    /// Recognize a SoundCloud track URL (`soundcloud.com/<artist>/<track>`).
    /// The embed needs the full track URL (percent-encoded), so
    /// `externalIdentity` is the absolute URL. Returns `nil` for a non-
    /// SoundCloud host or a path with fewer than two segments.
    public static func soundcloud(_ raw: String) -> MediaEmbedMatch? {
        guard let url = URLFetchService.normalizeURL(raw) else { return nil }
        guard let host = url.host?.lowercased(),
              host == "soundcloud.com" || host == "www.soundcloud.com"
        else { return nil }
        guard let segs = pathSegments(url), segs.count >= 2 else { return nil }
        let trackSlug = segs.last ?? segs[1]
        let absolute = url.absoluteString
        return MediaEmbedMatch(
            agentName: "soundcloud",
            mimeType: "audio/soundcloud",
            externalIdentity: absolute,
            filename: "soundcloud-\(trackSlug)",
            planURL: absolute,
            activityKind: "fetch")
    }

    // MARK: - Direct-remote media (Phase 2)

    /// Recognize a direct-remote media URL by path extension (audio, video, HLS).
    /// Returns `nil` for HTML/unknown/extension-less URLs so they fall through to
    /// the website fetch. The MIME is the real type inferred from the extension.
    public static func remoteMedia(_ raw: String) -> MediaEmbedMatch? {
        guard let url = URLFetchService.normalizeURL(raw) else { return nil }
        let ext = (url.path as NSString).pathExtension.lowercased()
        guard let mime = Self.mediaMIME(forExtension: ext) else { return nil }
        let absolute = url.absoluteString
        // Filename = last path component if present, else a host-based fallback.
        let last = (url.path as NSString).lastPathComponent
        let filename = last.isEmpty ? "remote-\(url.host ?? "media")" : last
        return MediaEmbedMatch(
            agentName: "remote-media",
            mimeType: mime,
            externalIdentity: absolute,
            filename: filename,
            planURL: absolute,
            activityKind: "import")
    }

    /// The set of recognized media extensions → real MIME types. Audio + video +
    /// HLS (.m3u8). HTML/text/unknown extensions map to `nil`.
    static func mediaMIME(forExtension ext: String) -> String? {
        switch ext {
        // Audio
        case "mp3":  return "audio/mpeg"
        case "m4a":  return "audio/mp4"
        case "aac":  return "audio/aac"
        case "ogg":  return "audio/ogg"
        case "opus": return "audio/ogg"
        case "flac": return "audio/flac"
        case "wav":  return "audio/wav"
        case "m4b":  return "audio/mp4"
        // Video
        case "mp4":  return "video/mp4"
        case "m4v":  return "video/x-m4v"
        case "webm": return "video/webm"
        case "mov":  return "video/quicktime"
        // HLS
        case "m3u8": return "application/vnd.apple.mpegurl"
        default:     return nil
        }
    }

    // MARK: - Helpers

    /// YouTube ids are exactly 11 characters from `[A-Za-z0-9_-]`.
    private static func isValidYouTubeID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// The non-empty path segments (URL-decoded), or nil when there are none.
    private static func pathSegments(_ url: URL) -> [String]? {
        let segs = url.path.split(separator: "/").map { String($0) }
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { !$0.isEmpty }
        return segs.isEmpty ? nil : segs
    }

    /// The last non-empty path segment, URL-decoded.
    private static func lastPath(_ url: URL) -> String {
        pathSegments(url)?.last ?? ""
    }
}
