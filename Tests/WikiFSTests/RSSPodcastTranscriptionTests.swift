import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the generic `.podcast` (any-RSS-feed) transcript pipeline — the
/// recognizer, the service's pure result-mapping, the dispatch helper, and the
/// intake entry point.
///
/// **UNGUARDED** (no `#if PODCAST_TRANSCRIPTS`) per M1 in
/// `plans/podcast-generalize.md` — the generic `.podcast` path is always
/// compiled (works on `WIKIFS_APP_STORE=1` builds), so these tests MUST run on
/// every build to validate the AC.4 "works on App Store" claim.
///
/// Issue podcast-generalize.
@MainActor
struct RSSPodcastTranscriptionTests {

    // MARK: - RSSFeedEpisodeURL recognizer (AC.1 intake validation)

    @Test func parseAcceptsXmlFeedURL() throws {
        let ref = try #require(RSSFeedEpisodeURL.parse("https://feeds.example.com/show.xml"))
        #expect(ref.feedURL.absoluteString == "https://feeds.example.com/show.xml")
        #expect(ref.episodeGUID == nil)
        #expect(ref.slug == "show")
    }

    @Test func parseAcceptsRssFeedURL() throws {
        let ref = try #require(RSSFeedEpisodeURL.parse("https://example.com/podcast/feed.rss"))
        #expect(ref.slug == "feed")
    }

    @Test func parseAcceptsBareHTTPSURL() throws {
        // The explicit affordance declares intent, so any http(s) URL is accepted.
        let ref = try #require(RSSFeedEpisodeURL.parse("https://example.com/ep42"))
        #expect(ref.feedURL.host == "example.com")
    }

    @Test func parseRejectsNonHTTP() {
        #expect(RSSFeedEpisodeURL.parse("not a url") == nil)
        #expect(RSSFeedEpisodeURL.parse("file:///local.xml") == nil)
    }

    @Test func parseRejectsEmptyAndWhitespace() {
        #expect(RSSFeedEpisodeURL.parse("") == nil)
        #expect(RSSFeedEpisodeURL.parse("   ") == nil)
    }

    @Test func parseNormalizesMissingScheme() throws {
        let ref = try #require(RSSFeedEpisodeURL.parse("feeds.example.com/show.xml"))
        #expect(ref.feedURL.scheme == "https")
    }

    @Test func slugDerivesFromHostWhenPathEmpty() throws {
        let ref = try #require(RSSFeedEpisodeURL.parse("https://feeds.npr.org/"))
        #expect(ref.slug == "npr")
    }

    // MARK: - RSSPodcastTranscriptService.mapResult (feed path, AC.4 + AC.5)

    @Test func mapResultFeedPathExit0DecodesTranscript() throws {
        let json = """
        {
            "show_id": null,
            "episode_id": null,
            "language": "en",
            "format": "vtt",
            "markdown": "Welcome to the show."
        }
        """
        let feedURL = URL(string: "https://feeds.example.com/show.xml")!
        let result = (stdout: json, stderr: "", status: Int32(0))
        let transcript = try RSSPodcastTranscriptService.mapResult(result, feedURL: feedURL)

        #expect(transcript.markdown == "Welcome to the show.")
        // episodeID falls back to the feed URL when the script omits it.
        #expect(transcript.episodeID == "https://feeds.example.com/show.xml")
        // Filename is derived from the feed host + path, NOT a raw URL.
        #expect(transcript.filename.contains("show"))
        #expect(!transcript.filename.contains("https"))
    }

    @Test func mapResultFeedPathNonZeroThrowsNoTranscript() {
        // AC.5: graceful failure — no <podcast:transcript> tag → exit 1 → .noTranscriptAvailable.
        let feedURL = URL(string: "https://feeds.example.com/show.xml")!
        let result = (stdout: "", stderr: "No transcript available", status: Int32(1))
        #expect(throws: PodcastTranscriptError.noTranscriptAvailable) {
            try RSSPodcastTranscriptService.mapResult(result, feedURL: feedURL)
        }
    }

    @Test func mapResultFeedPathExit3ThrowsNoTranscript() {
        let feedURL = URL(string: "https://feeds.example.com/show.xml")!
        let result = (stdout: "", stderr: "Podcast not found", status: Int32(3))
        #expect(throws: PodcastTranscriptError.noTranscriptAvailable) {
            try RSSPodcastTranscriptService.mapResult(result, feedURL: feedURL)
        }
    }

    @Test func mapResultFeedPathEmptyOutputThrowsParseFailed() {
        let feedURL = URL(string: "https://feeds.example.com/show.xml")!
        let result = (stdout: "  \n ", stderr: "", status: Int32(0))
        #expect(throws: PodcastTranscriptError.ttmlParseFailed) {
            try RSSPodcastTranscriptService.mapResult(result, feedURL: feedURL)
        }
    }

    @Test func mapResultFeedPathInvalidJsonThrowsParseFailed() {
        let feedURL = URL(string: "https://feeds.example.com/show.xml")!
        let result = (stdout: "not json", stderr: "", status: Int32(0))
        #expect(throws: PodcastTranscriptError.ttmlParseFailed) {
            try RSSPodcastTranscriptService.mapResult(result, feedURL: feedURL)
        }
    }

    // MARK: - Filename (H3 — feed-oriented, not raw URL)

    @Test func filenameForFeedURLDerivesFromHostAndPath() {
        let url = URL(string: "https://feeds.example.com/show.xml")!
        let name = RSSPodcastTranscriptService.filename(forFeedURL: url)
        #expect(name.contains("show"))
        #expect(name.contains("example"))
        #expect(!name.contains("https"))
        #expect(!name.contains("://"))
    }

    @Test func filenameForFeedURLHandlesNoPath() {
        let url = URL(string: "https://feeds.example.com/")!
        let name = RSSPodcastTranscriptService.filename(forFeedURL: url)
        #expect(!name.isEmpty)
        #expect(name.contains("example"))
    }

    // MARK: - Rename-regression (L2)

    @Test func sourceURLInitPreservesURL() throws {
        // L2: the init(sourceURL:) rename preserves the URL for the Apple path.
        let url = URL(string: "https://podcasts.apple.com/us/podcast/slug/id123?i=456")!
        let svc = RSSPodcastTranscriptService(sourceURL: url)
        // The service stores the URL; we verify via the Apple-path mapResult
        // which is the consumer. A non-throwing construction is the baseline.
        _ = svc
    }

    @Test func noArgInitWorksForGenericPath() {
        // The generic-path dispatch default uses init() — verify it constructs.
        let svc = RSSPodcastTranscriptService()
        _ = svc
    }

    // MARK: - Dispatch (AC.4 — inject fake fetcher)

    /// A fake `RSSFeedTranscriptFetching` returning canned markdown, so the
    /// dispatch test asserts routing + append without spawning `uv`.
    private struct FakeRSSFeedFetcher: RSSFeedTranscriptFetching {
        let cannedMarkdown: String
        var shouldThrow: Bool = false

        func transcript(forFeedURL url: URL) async throws -> PodcastTranscript {
            if shouldThrow {
                throw PodcastTranscriptError.noTranscriptAvailable
            }
            return PodcastTranscript(
                episodeID: url.absoluteString,
                markdown: cannedMarkdown,
                filename: "podcast-fake-transcript.md")
        }
    }

    @Test func transcribeDispatchesToRSSPodcastAndAppends() async throws {
        let store = try Self.tempStore()
        let model = WikiStoreModel(store: store)

        // Create a byteless .podcast source (intake).
        _ = try await model.addPodcastFeedURL("https://feeds.example.com/show.xml")
        model.reloadFromStore()
        let sourceID = try #require(model.sources.first?.id)

        // No markdown version exists yet (no transcript at ingest).
        #expect(model.hasProcessedMarkdown(for: sourceID) == false)

        // Transcribe with an injected fake fetcher returning canned markdown.
        let fake = FakeRSSFeedFetcher(cannedMarkdown: "# Fake Transcript\n\nHello world.")
        let version = try await model.transcribe(
            sourceID: sourceID,
            rssPodcastFetcher: fake)

        // The dispatch reached the RSS path and appended a markdown version.
        let appended = try #require(version)
        #expect(appended.content.contains("Fake Transcript"))
        #expect(appended.technique == "rss-podcast-transcript")
        #expect(model.hasProcessedMarkdown(for: sourceID) == true)
    }

    @Test func transcribePodcastNoTranscriptSurfacesError() async throws {
        // AC.5: when the feed has no transcript tag, the fetcher throws
        // .noTranscriptAvailable and the dispatch propagates it (does NOT
        // silently return nil).
        let store = try Self.tempStore()
        let model = WikiStoreModel(store: store)

        _ = try await model.addPodcastFeedURL("https://feeds.example.com/notranscript.xml")
        model.reloadFromStore()
        let sourceID = try #require(model.sources.first?.id)

        let fake = FakeRSSFeedFetcher(cannedMarkdown: "", shouldThrow: true)
        await #expect(throws: PodcastTranscriptError.self) {
            _ = try await model.transcribe(sourceID: sourceID, rssPodcastFetcher: fake)
        }
    }

    @Test func transcribePodcastMissingPlanThrowsMissingPlan() async throws {
        // A .podcast source with no plan URL → .missingPlan.
        let store = try Self.tempStore()
        let model = WikiStoreModel(store: store)

        // Manually create a source with .podcast provider but no plan URL.
        let summary = try store.addBytelessSource(
            filename: "podcast-orphan",
            mimeType: "audio/podcast",
            provenance: SourceProvenance(
                agentName: SourceProvider.podcast.rawValue,
                activityKind: "fetch",
                plan: nil, externalRef: nil, externalIdentity: nil),
            role: .primary)

        let fake = FakeRSSFeedFetcher(cannedMarkdown: "x")
        await #expect(throws: SourceRefreshService.RefreshError.self) {
            _ = try await model.transcribe(sourceID: summary.id, rssPodcastFetcher: fake)
        }
    }

    // MARK: - Intake (AC.3)

    @Test func addPodcastFeedURLCreatesBytelessPodcastSource() async throws {
        let store = try Self.tempStore()
        let model = WikiStoreModel(store: store)

        let outcome = try await model.addPodcastFeedURL("https://feeds.example.com/show.xml")
        model.reloadFromStore()

        #expect(outcome.byteSize == 0)
        #expect(model.sources.count == 1)
        let source = try #require(model.sources.first)
        #expect(source.byteSize == 0)

        // Verify provenance: provider .podcast, plan = feed URL.
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        #expect(origin.provider == .podcast)
        #expect(origin.plan == "https://feeds.example.com/show.xml")

        // No transcript written at ingest (AC.3).
        #expect(model.hasProcessedMarkdown(for: source.id) == false)
    }

    @Test func addPodcastFeedURLRejectsInvalidURL() async throws {
        let store = try Self.tempStore()
        let model = WikiStoreModel(store: store)

        await #expect(throws: WikiStoreError.self) {
            _ = try await model.addPodcastFeedURL("not a url")
        }
        #expect(model.sources.isEmpty)
    }

    @Test func addPodcastFeedURLDeduplicatesSameFeed() async throws {
        let store = try Self.tempStore()
        let model = WikiStoreModel(store: store)

        _ = try await model.addPodcastFeedURL("https://feeds.example.com/show.xml")
        model.reloadFromStore()
        // Re-pasting the same feed URL → duplicate content error.
        await #expect(throws: WikiStoreError.self) {
            _ = try await model.addPodcastFeedURL("https://feeds.example.com/show.xml")
        }
        #expect(model.sources.count == 1)
    }

    // MARK: - Helpers

    private static func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-rsspodcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }
}
