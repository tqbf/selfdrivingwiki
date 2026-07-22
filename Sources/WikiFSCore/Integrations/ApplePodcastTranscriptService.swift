#if PODCAST_TRANSCRIPTS  // Apple Podcasts transcript feature; off for WIKIFS_APP_STORE=1 builds.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

/// The one thing ingest calls: pasted URL → transcript. Injected so `URLIngestService`
/// and `WikiStoreModel` can be unit-tested with a fake, and the app wires the real
/// `ApplePodcastTranscriptService`.
public protocol PodcastTranscriptFetching: Sendable {
    func transcript(for episode: PodcastEpisodeURL.EpisodeRef) async throws -> PodcastTranscript
}

/// Produces the FairPlay-signed bearer token. The real one shells out to the
/// `podcast-token-helper`; tests inject a canned token or error.
public protocol PodcastTokenProviding: Sendable {
    func bearerToken(forceRefresh: Bool) async throws -> String
}

/// The AMP + TTML HTTP round-trips. One seam over `URLSession` so the service's
/// orchestration (token → AMP → TTML → parse, plus the 40012 refresh-retry) is
/// unit-tested with canned responses.
public protocol PodcastHTTPClient: Sendable {
    /// Perform a request, returning `(status, body)`.
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
    /// GET the access-key'd TTML URL (no auth), returning `(status, body)`.
    func download(_ url: URL) async throws -> (status: Int, body: Data)
}

/// Orchestrates the URL → transcript pipeline: signed bearer token → AMP transcript
/// metadata → TTML download → parse → markdown. On AMP `40012` it force-refreshes
/// the token ONCE and retries before giving up. Every side-effecting leg is behind
/// an injected protocol, so the whole control flow is unit-tested without network
/// or private frameworks.
///
/// See `plans/podcast-transcripts.md` (step 6).
public struct ApplePodcastTranscriptService: PodcastTranscriptFetching {
    private let tokens: any PodcastTokenProviding
    private let http: any PodcastHTTPClient

    public init(tokens: any PodcastTokenProviding, http: any PodcastHTTPClient) {
        self.tokens = tokens
        self.http = http
    }

    /// Convenience: the production wiring (helper-backed token provider + URLSession).
    public init(helperURL: URL) {
        self.init(
            tokens: HelperPodcastTokenProvider(helperURL: helperURL),
            http: URLSessionPodcastHTTPClient())
    }

    /// The production service if the `podcast-token-helper` binary is present next to
    /// the app (`Contents/Helpers/`) or beside the built executable (dev/test), else
    /// nil — so a build without the helper simply doesn't offer podcast ingest rather
    /// than crashing. Mirrors how `wikictl` is resolved from the bundle.
    public static func bundled() -> ApplePodcastTranscriptService? {
        HelperPodcastTokenProvider.resolveHelperURL().map { ApplePodcastTranscriptService(helperURL: $0) }
    }

    public func transcript(
        for episode: PodcastEpisodeURL.EpisodeRef
    ) async throws -> PodcastTranscript {
        let ttmlURL = try await resolveTTMLURL(episode: episode)

        let (status, body) = try await http.download(ttmlURL)
        guard status == 200 else { throw PodcastTranscriptError.badResponse(status) }

        let transcript = try TTMLTranscript.parse(body)
        return PodcastTranscript(
            episodeID: episode.id,
            markdown: transcript.plainText,
            filename: Self.filename(for: episode))
    }

    /// Get the TTML URL, refreshing the token once on a permissions failure.
    private func resolveTTMLURL(episode: PodcastEpisodeURL.EpisodeRef) async throws -> URL {
        do {
            return try await ttmlURL(episode: episode, forceToken: false)
        } catch PodcastTranscriptError.insufficientPermissions {
            // The cached token lacked transcript permission (stale / unsigned) —
            // re-sign once and retry before surfacing the failure.
            return try await ttmlURL(episode: episode, forceToken: true)
        }
    }

    private func ttmlURL(
        episode: PodcastEpisodeURL.EpisodeRef, forceToken: Bool
    ) async throws -> URL {
        let token = try await tokens.bearerToken(forceRefresh: forceToken)
        let (status, body) = try await http.send(
            ApplePodcastAMP.request(episodeID: episode.id, token: token))
        return try ApplePodcastAMP.ttmlURL(fromStatus: status, body: body)
    }

    /// The stored source's filename: `<slug>-<id>-transcript.md`, or
    /// `podcast-<id>-transcript.md` when the URL carried no slug.
    static func filename(for episode: PodcastEpisodeURL.EpisodeRef) -> String {
        let stem = episode.slug.map { "\($0)-\(episode.id)" } ?? "podcast-\(episode.id)"
        return "\(FilenameEscaping.escapeTitle(stem))-transcript.md"
    }
}
#endif
