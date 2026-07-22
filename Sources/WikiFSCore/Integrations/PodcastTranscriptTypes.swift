import Foundation

/// Always-compiled transcript value types, the fetcher protocol, the error
/// enum, and the subprocess-backed `RSSPodcastTranscriptService`.
///
/// These symbols have **no FairPlay / private-framework dependency** — only the
/// `podcast-transcript` `uv` script (PEP 723) — so they compile on EVERY build,
/// including `WIKIFS_APP_STORE=1` (where `#if PODCAST_TRANSCRIPTS` is off). The
/// FairPlay-specific code (`ApplePodcastTranscriptService`, `ApplePodcastAMP`,
/// `TTMLTranscript` parse logic, `HelperPodcastTokenProvider`) stays gated.
///
/// Extracted from `ApplePodcastTranscriptService.swift` + `TTMLTranscript.swift`
/// so the generic `.podcast` (any-RSS-feed) path — issue podcast-generalize —
/// can reach `RSSPodcastTranscriptService` without the guard. See C1 in
/// `plans/podcast-generalize.md`.

// MARK: - PodcastTranscript

/// The finished transcript for a recognized episode: episode ID, markdown text,
/// and a suggested source filename.
public struct PodcastTranscript: Equatable, Sendable {
    public let episodeID: String
    public let markdown: String
    public let filename: String

    public init(episodeID: String, markdown: String, filename: String) {
        self.episodeID = episodeID
        self.markdown = markdown
        self.filename = filename
    }
}

// MARK: - PodcastTranscriptFetching (Apple path)

/// The Apple-path fetcher contract: pasted Apple episode URL → transcript.
/// Injected so `URLIngestService` and `WikiStoreModel` can be unit-tested with
/// a fake; the app wires the real `ApplePodcastTranscriptService` (FairPlay).
public protocol PodcastTranscriptFetching: Sendable {
    func transcript(for episode: PodcastEpisodeURL.EpisodeRef) async throws -> PodcastTranscript
}

// MARK: - RSSFeedTranscriptFetching (generic any-RSS-feed path)

/// The generic-RSS-path fetcher contract: a direct RSS feed URL → transcript.
/// Sister protocol to `PodcastTranscriptFetching` for the `.podcast` provider
/// (any RSS feed, no Apple ID, no iTunes Lookup hop). Injection seam so tests
/// can fake the subprocess without spawning `uv`. Always compiled.
///
/// Issue podcast-generalize (H3).
public protocol RSSFeedTranscriptFetching: Sendable {
    func transcript(forFeedURL url: URL) async throws -> PodcastTranscript
}

// MARK: - PodcastTranscriptError

/// Errors for the URL → transcript pipeline, user-readable so the Add-from-URL
/// sheet and `SourceDetailView.runTranscription` can surface them directly.
public enum PodcastTranscriptError: Error, LocalizedError, Equatable {
    /// The private-framework signing helper failed (missing, crashed, or the
    /// macOS release changed the selectors). Carries the helper's stderr.
    case signatureUnavailable(String)
    /// AMP returned 40012 — the token lacks transcript permission even after a
    /// forced refresh.
    case insufficientPermissions
    /// The episode/feed has no transcript (no `<podcast:transcript>` tag, or
    /// Apple has no TTML). Surfaced as a graceful "no transcript" failure.
    case noTranscriptAvailable
    /// An unexpected HTTP status from the AMP or TTML request.
    case badResponse(Int)
    /// The TTML/JSON bytes didn't parse into any usable transcript.
    case ttmlParseFailed

    public var errorDescription: String? {
        switch self {
        case .signatureUnavailable(let detail):
            return "Couldn't sign the Apple Podcasts token request: \(detail)"
        case .insufficientPermissions:
            return "Apple rejected the transcript request (insufficient permissions)."
        case .noTranscriptAvailable:
            return "This episode has no transcript."
        case .badResponse(let code):
            return "The transcript service returned HTTP \(code)."
        case .ttmlParseFailed:
            return "The transcript file couldn't be parsed."
        }
    }
}

// MARK: - RSSPodcastTranscriptService

/// Fetches a podcast transcript by spawning the `podcast-transcript` PEP 723
/// script (`tools/podcast-transcript/podcast-transcript`), which fetches the
/// RSS feed and looks for `<podcast:transcript>` tags — no FairPlay signing
/// helper, no private frameworks. Mirrors `YouTubeTranscriptService` (subprocess
/// pattern) and is a `PodcastTranscriptFetching` conformer alongside
/// `ApplePodcastTranscriptService` (the FairPlay path).
///
/// The script accepts EITHER an Apple Podcasts episode URL OR a direct RSS feed
/// URL as argv[1] and emits structured JSON with `--json`:
/// `{show_id, episode_id, language, format, markdown}`.
///
/// Two entry points:
/// - `transcript(for:)` — the Apple path (conforms to `PodcastTranscriptFetching`).
///   Uses the stored `sourceURL` (an Apple episode URL).
/// - `transcript(forFeedURL:)` — the generic any-RSS-feed path (conforms to
///   `RSSFeedTranscriptFetching`). Takes the feed URL directly; never touches
///   `EpisodeRef`, so the stored filename is derived from the feed host + path
///   (H3) instead of a numeric episode ID.
///
/// Exit codes are mapped to `PodcastTranscriptError`:
///   0 → success, 3 → podcast not found, 4 → episode not found,
///   1/other → `.noTranscriptAvailable` (no RSS transcript / network error).
///
/// Issues #812 + podcast-generalize.
public struct RSSPodcastTranscriptService: PodcastTranscriptFetching, RSSFeedTranscriptFetching {

    /// The decoded JSON the `podcast-transcript --json` script emits.
    struct ScriptOutput: Decodable {
        let show_id: String?
        let episode_id: String?
        let language: String?
        let format: String?
        let markdown: String?
    }

    /// The full Apple Podcasts episode URL (e.g.
    /// `https://podcasts.apple.com/us/podcast/slug/id123?i=456`). Stored at init
    /// for the Apple-path `transcript(for:)` conformance — the dispatch in
    /// `WikiStoreModel.transcribePodcast` passes `origin.plan` (the page URL).
    /// The generic path (`transcript(forFeedURL:)`) does NOT use this — it takes
    /// the feed URL as a parameter (H3), so the no-arg `init()` leaves this nil.
    private let sourceURL: URL?

    /// Generic-RSS-path default init. `transcript(forFeedURL:)` takes the URL
    /// as a parameter, so no stored URL is needed for the `.podcast` dispatch.
    public init() {
        self.sourceURL = nil
    }

    /// Apple-path init (renamed from `episodeURL:` in podcast-generalize).
    /// The stored URL is an Apple Podcasts episode URL OR a direct RSS feed URL
    /// (the script accepts both); the Apple-path `transcript(for:)` passes it
    /// to the script.
    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    // MARK: Apple path (PodcastTranscriptFetching)

    public func transcript(
        for episode: PodcastEpisodeURL.EpisodeRef
    ) async throws -> PodcastTranscript {
        guard let sourceURL else {
            DebugLog.extraction("[podcast-rss] transcript(for:): no sourceURL stored (use init(sourceURL:))")
            throw PodcastTranscriptError.signatureUnavailable(
                "RSSPodcastTranscriptService was not initialized with a source URL.")
        }

        guard let script = Self.resolveScript() else {
            DebugLog.extraction("[podcast-rss] transcript: script not found")
            throw PodcastTranscriptError.signatureUnavailable(
                "The podcast-transcript script isn't available in this build.")
        }

        DebugLog.extraction("[podcast-rss] transcript: spawning \(script.path) for \(sourceURL.absoluteString)")

        do {
            let result = try await TranscriptSubprocess.run(
                script: script,
                arguments: [sourceURL.absoluteString, "--json"]
            )
            return try Self.mapResult(result, episode: episode)
        } catch let error as TranscriptSubprocessError {
            DebugLog.extraction("[podcast-rss] transcript: subprocess error: \(error.localizedDescription)")
            throw PodcastTranscriptError.signatureUnavailable(error.localizedDescription)
        }
    }

    // MARK: Generic any-RSS-feed path (RSSFeedTranscriptFetching) — H3

    public func transcript(forFeedURL url: URL) async throws -> PodcastTranscript {
        guard let script = Self.resolveScript() else {
            DebugLog.extraction("[podcast-rss] transcript(forFeedURL:): script not found")
            throw PodcastTranscriptError.signatureUnavailable(
                "The podcast-transcript script isn't available in this build.")
        }

        DebugLog.extraction("[podcast-rss] transcript(forFeedURL:): spawning \(script.path) for \(url.absoluteString)")

        do {
            let result = try await TranscriptSubprocess.run(
                script: script,
                arguments: [url.absoluteString, "--json"]
            )
            return try Self.mapResult(result, feedURL: url)
        } catch let error as TranscriptSubprocessError {
            DebugLog.extraction("[podcast-rss] transcript(forFeedURL:): subprocess error: \(error.localizedDescription)")
            throw PodcastTranscriptError.signatureUnavailable(error.localizedDescription)
        }
    }

    // MARK: - Result mapping (pure, testable)

    /// Map the subprocess result to a `PodcastTranscript` (Apple path) or throw
    /// the appropriate `PodcastTranscriptError`. Pure — extracted for testability.
    static func mapResult(
        _ result: (stdout: String, stderr: String, status: Int32),
        episode: PodcastEpisodeURL.EpisodeRef
    ) throws -> PodcastTranscript {
        let output = try Self.decode(result)
        let episodeID = output.script.episode_id ?? episode.id
        return PodcastTranscript(
            episodeID: episodeID,
            markdown: output.script.markdown ?? "",
            filename: Self.filename(for: episode))
    }

    /// Map the subprocess result to a `PodcastTranscript` (generic RSS-feed
    /// path). Pure — extracted for testability. The filename is derived from
    /// the feed host + last path component (H3), never a raw URL string.
    static func mapResult(
        _ result: (stdout: String, stderr: String, status: Int32),
        feedURL: URL
    ) throws -> PodcastTranscript {
        let output = try Self.decode(result)
        let episodeID = output.script.episode_id ?? feedURL.absoluteString
        return PodcastTranscript(
            episodeID: episodeID,
            markdown: output.script.markdown ?? "",
            filename: Self.filename(forFeedURL: feedURL))
    }

    /// Shared exit-code + JSON-decode gate. Returns the decoded `ScriptOutput`
    /// after verifying a zero exit status and non-empty stdout.
    private static func decode(
        _ result: (stdout: String, stderr: String, status: Int32)
    ) throws -> (script: ScriptOutput, raw: String) {
        switch result.status {
        case 0:
            break
        case 3, 4:
            throw PodcastTranscriptError.noTranscriptAvailable
        default:
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            DebugLog.extraction("[podcast-rss] transcript: exit \(result.status): \(msg)")
            throw PodcastTranscriptError.noTranscriptAvailable
        }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PodcastTranscriptError.ttmlParseFailed
        }

        do {
            let script = try JSONDecoder().decode(ScriptOutput.self, from: Data(trimmed.utf8))
            return (script, trimmed)
        } catch {
            DebugLog.extraction("[podcast-rss] transcript: JSON decode failed: \(error)")
            throw PodcastTranscriptError.ttmlParseFailed
        }
    }

    /// Resolve the `podcast-transcript` script. Mirrors
    /// `PdfExtractionService.resolveScript()`.
    static func resolveScript() -> URL? {
        TranscriptSubprocess.resolveScript(
            named: "podcast-transcript",
            repoSubdir: "tools/podcast-transcript")
    }

    // MARK: - Filenames

    /// Apple-path filename: `<slug>-<id>-transcript.md`, or
    /// `podcast-<id>-transcript.md` when the URL carried no slug.
    static func filename(for episode: PodcastEpisodeURL.EpisodeRef) -> String {
        let stem = episode.slug.map { "\($0)-\(episode.id)" } ?? "podcast-\(episode.id)"
        return "\(FilenameEscaping.escapeTitle(stem))-transcript.md"
    }

    /// Generic-RSS-feed filename (H3): derived from the feed host + last path
    /// component so it reads like a source name, NOT a raw URL. E.g.
    /// `https://feeds.example.com/show.xml` → `podcast-feeds-example-com-show`.
    /// The `-transcript.md` suffix is added by the caller's
    /// `appendProcessedMarkdown` filename derivation; here we produce the stem
    /// that matches the byteless-source filename convention.
    static func filename(forFeedURL url: URL) -> String {
        let host = (url.host ?? "feed")
            .replacingOccurrences(of: "www.", with: "")
        let last = url.lastPathComponent.isEmpty
            ? "feed"
            : (url.lastPathComponent as NSString).deletingPathExtension
        // Collapse non-alphanumerics to hyphens for a filesystem-safe stem,
        // matching FilenameEscaping's spaces-as-underscores discipline loosely.
        let raw = "\(host)-\(last)"
        let stem = raw.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .repeatingHyphensCollapsed()
        return FilenameEscaping.escapeTitle("podcast-\(stem)")
    }
}

private extension String {
    /// Collapse runs of `-` into a single `-` and trim leading/trailing `-`.
    func repeatingHyphensCollapsed() -> String {
        var out = ""
        var prevDash = false
        for ch in self {
            if ch == "-" {
                if !prevDash { out.append(ch) }
                prevDash = true
            } else {
                out.append(ch)
                prevDash = false
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
