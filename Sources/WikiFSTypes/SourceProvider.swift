import Foundation

/// Typed taxonomy for source origin — the `agents.name` value stamped by each
/// materializer and projected from the PROV graph. Single source of truth for
/// the convention strings: every construction site (the 5 materializers + the
/// 5 byteless-media recognizers) routes through `SourceProvider.X.rawValue`,
/// and every parse/display site routes through `SourceProvider(rawValue:)`.
///
/// The convention itself is unchanged from the pre-typing discipline
/// (`plans/source-provider-enum.md`): the bytes stored in `agents.name` are
/// byte-identical before and after this enum lands, so no DB migration is
/// required. This mirrors the `PageAuthor` pattern (#797 Phase 1).
///
/// Lives in `WikiFSTypes` (the shared leaf target) so the write seam
/// (`WikiFSCore`'s `SourceMaterializer` / `MediaEmbedURL`), the refresh service
/// (`WikiFSCore`'s `SourceRefreshService`), and the read-side UI (`WikiFS`'s
/// `SourceDetailView`) all share one definition with no new module edge.
public enum SourceProvider: String, CaseIterable, Equatable, Hashable, Sendable {

    /// A drag-dropped / picked local file. Stored as `"local-file"`.
    case localFile       = "local-file"
    /// A fetched website (HTML→Markdown / PDF / text / binary). Stored as `"website"`.
    case website         = "website"
    /// A Zotero attachment import. Stored as `"zotero"`.
    case zotero          = "zotero"
    /// One `.md`/`.markdown` file from a folder import. Stored as `"markdown-folder"`.
    case markdownFolder  = "markdown-folder"
    /// An Apple Podcasts episode transcript (byteless). Stored as `"apple-podcast"`.
    case applePodcast    = "apple-podcast"
    /// A byteless generic RSS podcast feed (transcript via `<podcast:transcript>`).
    /// Stored as `"podcast"`. Unlike `.applePodcast`, this needs no FairPlay
    /// signing helper — it works on every build (App Store included) since the
    /// only dependency is the `podcast-transcript` `uv` script.
    case podcast         = "podcast"
    /// A byteless YouTube embed (synthetic `video/youtube` mime). Stored as `"youtube"`.
    case youtube         = "youtube"
    /// A byteless Vimeo embed. Stored as `"vimeo"`.
    case vimeo           = "vimeo"
    /// A byteless Spotify embed. Stored as `"spotify"`.
    case spotify         = "spotify"
    /// A byteless SoundCloud embed. Stored as `"soundcloud"`.
    case soundcloud      = "soundcloud"
    /// Direct-remote media (mp3/mp4/HLS); real mime, no provider iframe. Stored as `"remote-media"`.
    case remoteMedia     = "remote-media"
    /// The shared pre-v39 / nil-origin fallback. Stored as `"legacy-import"`.
    case legacyImport    = "legacy-import"

    /// Parse a stored `agents.name` value. `nil`/empty/unknown → `nil`.
    /// Unlike `PageAuthor` (which falls back to `.legacyImport`), unknown values
    /// here return `nil` so each switch site can choose its own default-arm
    /// behaviour (the SourceDetailView chip shows "File"; the refresh service
    /// throws `.notRefreshable`). This intentional nil-vs-fallback split is
    /// documented in `plans/source-provider-enum.md` §Type changes.
    public init?(rawValue: String?) {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        self.init(rawValue: rawValue)
    }

    /// Display label for the origin chip — canonical across all UI sites.
    /// Replaces the prior disagreements where `SourceOrigin.displayLabel`
    /// returned "Markdown folder" but `SourceDetailView` rendered "Folder".
    public var displayLabel: String {
        switch self {
        case .localFile:       return "File"
        case .website:         return "Website"
        case .zotero:          return "Zotero"
        case .markdownFolder:  return "Folder"
        case .applePodcast:    return "Apple Podcast"
        case .podcast:         return "Podcast"
        case .youtube:         return "YouTube"
        case .vimeo:           return "Vimeo"
        case .spotify:         return "Spotify"
        case .soundcloud:      return "SoundCloud"
        case .remoteMedia:     return "Media"
        case .legacyImport:    return "Imported"
        }
    }

    /// SF Symbol for the origin chip. The symbol mirrors what each
    /// provider's content *is* (globe for website, folder for folder, doc for
    /// file, play rectangle for video providers, music note for audio, etc.).
    public var systemImage: String {
        switch self {
        case .localFile:       return "doc"
        case .website:         return "globe"
        case .zotero:          return "books.vertical"
        case .markdownFolder:  return "folder"
        case .applePodcast:    return "waveform"
        case .podcast:         return "antenna.radiowaves.left.and.right"
        case .youtube:         return "play.rectangle"
        case .vimeo:           return "play.rectangle"
        case .spotify:         return "music.note"
        case .soundcloud:      return "waveform"
        case .remoteMedia:     return "music.note"
        case .legacyImport:    return "tray.and.arrow.down"
        }
    }

    /// Help-text verb for the origin chip's tooltip/click action. Composed at
    /// the call site as `"\(helpVerb): \(urlString)"` (or used verbatim). The
    /// verb distinguishes "Open" (URL providers) from "Reveal" (local paths).
    public var helpVerb: String {
        switch self {
        case .localFile:       return "Reveal original file"
        case .website:         return "Open original"
        case .zotero:          return "View in Zotero"
        case .markdownFolder:  return "Reveal original folder"
        case .applePodcast:    return "Open episode"
        case .podcast:         return "Open feed"
        case .youtube:         return "Open video"
        case .vimeo:           return "Open video"
        case .spotify:         return "Open track"
        case .soundcloud:      return "Open track"
        case .remoteMedia:     return "Open media"
        case .legacyImport:    return "View provenance"
        }
    }

    /// **Baseline** refresh capability — `true` for providers that *in
    /// principle* support re-fetching a newer content version. NOT the full
    /// refreshability predicate.
    ///
    /// Runtime guards layered on top at `WikiStoreModel.isSourceRefreshable`:
    /// - `website`: `false` when the source is a snapshot with image siblings
    ///   (single-source refresh would orphan them — D3 guard).
    /// - `applePodcast`: `false` when this build doesn't compile podcast
    ///   support OR the `podcast-token-helper` binary isn't present at runtime.
    /// - `podcast` (generic RSS): always refreshable on every build — the
    ///   re-transcribe fetches a fresh `<podcast:transcript>` via the
    ///   `podcast-transcript` `uv` script (no signing helper).
    ///
    /// Every other provider (local-file / Zotero / folder / YouTube / Vimeo /
    /// Spotify / SoundCloud / remote-media / legacy-import / unknown) is
    /// import-only or byteless-embed-only — there's no URL to re-fetch.
    public var supportsRefresh: Bool {
        switch self {
        case .website, .applePodcast, .podcast:
            return true
        case .localFile, .zotero, .markdownFolder,
             .youtube, .vimeo, .spotify, .soundcloud, .remoteMedia,
             .legacyImport:
            return false
        }
    }

    /// **Baseline** transcription capability — `true` for providers that *in
    /// principle* support fetching on-demand a fresh transcript markdown version
    /// via `WikiStoreModel.transcribe(sourceID:)` (the unified dispatch entry
    /// point, issue #799 PR5). Sister property to `supportsRefresh`; covers the
    /// byteless-embed providers whose only path to a transcript markdown is the
    /// on-demand Transcribe button (`SourceDetailView.runTranscription`):
    /// - `applePodcast` — signed bearer → AMP metadata → TTML download → parse
    ///   (PR4). Runtime guard layered on top at the model: the bundled
    ///   signing helper must be present (`ApplePodcastTranscriptService.bundled()`
    ///   != nil) AND this build must compile podcast support
    ///   (`#if PODCAST_TRANSCRIPTS`).
    /// - `podcast` (generic RSS) — the `podcast-transcript` `uv` script fetches
    ///   the feed and parses `<podcast:transcript>` tags. No signing helper
    ///   needed; always available on every build (App Store included). The
    ///   `transcribeRSSPodcast` helper lives outside `#if PODCAST_TRANSCRIPTS`.
    /// - `youtube` — pure-Swift watch-page → caption track scrape (PR5). No
    ///   signing helper needed; always available when the source has a valid
    ///   11-char video ID in `origin.externalIdentity`.
    ///
    /// Every other provider (local-file / Zotero / folder / website / Vimeo /
    /// Spotify / SoundCloud / remote-media / legacy-import / unknown) has no
    /// transcript pipeline today — `transcribe` on those throws
    /// `.notRefreshable`. Vimeo is a future extension (needs a Keychain OAuth
    /// token; #564 Phase 4 follow-up).
    ///
    /// # PR2: delegates to the content-type registry
    ///
    /// The static baseline now routes through the registry rather than
    /// duplicating the provider switch (PR1 introduced the registry as the
    /// single decision table; this property was the last holdout among the
    /// §2 sites). `ContentKind.resolve(mimeType: nil, provider: self)`
    /// classifies `applePodcast` / `podcast` → `.podcastTranscript` and
    /// `youtube` → `.youtubeTranscript`; every other provider falls through
    /// to MIME → `.unknown` (`extractionPath == nil`) since `mimeType` is
    /// `nil` here. `hasTranscriptBackend` on the capabilities struct is the
    /// boolean form of "extractionPath is `.podcastTranscript` or
    /// `.youtubeTranscript`" — same semantics as the original switch.
    ///
    /// The runtime guards (signing helper present, `#if PODCAST_TRANSCRIPTS`)
    /// still layer on top at `SourceDetailView.isTranscribable` /
    /// `WikiStoreModel.isSourceRefreshable(for:)`; this property is the
    /// *static* capability, not the runtime availability.
    public var supportsTranscription: Bool {
        ContentKind.resolve(mimeType: nil, provider: self)
            .capabilities.hasTranscriptBackend
    }
}
