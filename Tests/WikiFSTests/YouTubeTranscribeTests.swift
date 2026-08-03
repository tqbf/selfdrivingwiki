import Foundation
import Testing
@testable import WikiFSCore

/// Issue #799 PR5 — verifies the unified `WikiStoreModel.transcribe(sourceID:)`
/// dispatch entry point routes by `origin.provider` to the per-provider
/// helpers, with YouTube getting the new `transcribeYouTube` arm. Mirrors
/// `PodcastIngestRoutingTests` (PR4) for shape: byteless-only ingest, then
/// the user clicks Transcribe to trigger the on-demand caption fetch.
///
/// Uses a fake `YouTubeTranscriptFetching` + a fake URL fetcher (serves the
/// watch-page HTML + caption XML the scrape needs) so we can assert which
/// path ran — no network, no signing helper.
@MainActor
struct YouTubeTranscribeTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-youtube-transcribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Records whether it was asked for a transcript, and returns a canned one.
    final class FakeYouTubeFetcher: YouTubeTranscriptFetching, @unchecked Sendable {
        private(set) var requestedVideoID: String?
        /// Marks the per-call markdown so a swap between two transcribe calls
        /// can simulate "v1" vs "v2" (mirrors `PodcastIngestRoutingTests`'s
        /// `FakePodcastFetcher`).
        var markdown: String
        init(markdown: String = "Hello world. Second cue.") {
            self.markdown = markdown
        }
        func transcript(forVideoID videoID: String) async throws -> YouTubeTranscript {
            requestedVideoID = videoID
            return YouTubeTranscript(
                videoID: videoID,
                title: "Test Talk",
                markdown: markdown,
                filename: "Test-Talk-\(videoID)-transcript.md")
        }
    }

    // MARK: - AC.5: Transcribe writes a transcript HEAD on a YouTube source

    /// Issue #799 PR5 AC.5 — tapping Transcribe on an un-transcribed YouTube
    /// source triggers `YouTubeTranscriptFetching.transcript(forVideoID:)`
    /// and creates a transcript processed-markdown version (HEAD,
    /// `.transcript` origin, `"youtube-captions"` technique). Proves the
    /// dispatch entry point routes `.youtube` → `transcribeYouTube`, which
    /// reconstructs the 11-char video ID from `origin.externalIdentity` (the
    /// byteless-source provenance recorded at ingest).
    @Test func transcribeWritesTranscriptHead() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let youtube = FakeYouTubeFetcher(markdown: "Hello world. Second cue.")

        // 1. Ingest — byteless only, no transcript (PR5 contract mirrors PR4).
        // Note: unlike the podcast path (which writes NO markdown at ingest),
        // YouTube ingestion writes a synthetic metadata-only markdown page via
        // `writeSyntheticBytelessMarkdown` (issue #646) so the reader has
        // readable content. The synthetic page has the
        // `byteless-oembed-synthetic` technique and NO transcript cues —
        // distinct from the transcript version the Transcribe button writes.
        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: BytelessEmbedIntegrationTests.YouTubeFixtureFetcher(),
            podcastFetcher: nil,
            youtubeFetcher: nil)  // intentionally nil: fetcher is unused at ingest
        #expect(outcome.kind == .videoEmbed)
        let sources = try store.listSources()
        let stored = try #require(sources.first)
        // Sanity: at ingest, only the synthetic metadata page exists — NOT a
        // transcript. The synthetic page is the initial HEAD; the Transcribe
        // button (below) replaces it as HEAD by appending the transcript.
        let initialHead = try #require(try store.processedMarkdownHead(sourceID: stored.id))
        #expect(initialHead.technique == "byteless-oembed-synthetic")
        #expect(!initialHead.content.contains("Hello world"))
        #expect(!initialHead.content.contains("Second cue"))

        // 2. Transcribe — the user clicks the Transcribe button. PR5: the
        // public entry point is `transcribe(sourceID:youtubeFetcher:)`.
        let head = try #require(
            try await model.transcribe(sourceID: stored.id, youtubeFetcher: youtube))

        // The fetcher was consulted, with the video ID reconstructed from
        // `origin.externalIdentity` (the 11-char ID stored at ingest).
        #expect(youtube.requestedVideoID == "dQw4w9WgXcQ")
        // The transcript markdown is the new HEAD.
        #expect(head.origin == .transcript)
        #expect(head.technique == "youtube-captions")
        #expect(head.content == "Hello world. Second cue.")
        // Re-read from the store to confirm persistence.
        let persisted = try #require(try store.processedMarkdownHead(sourceID: stored.id))
        #expect(persisted.content == "Hello world. Second cue.")
        #expect(persisted.origin == .transcript)
        #expect(persisted.technique == "youtube-captions")
    }

    // MARK: - AC.6: Re-transcribe appends coexisting alternative

    /// Issue #799 PR5 AC.6 — `transcribe(sourceID:)` always appends a new
    /// processed-markdown version (never clobbers). The first call creates
    /// the HEAD; subsequent calls append coexisting alternatives. So a re-
    /// transcribe creates an alternative the provenance chip + Re-transcribe
    /// with menu surface for the user to pick. Mirrors the podcast
    /// `reTranscribeAppendsCoexistingAlternative` (PR4) and the HTML
    /// `reExtractHtmlAppendsCoexistingAlternative` (PR2): same method, same
    /// write path (`appendProcessedMarkdown`), same append semantic.
    @Test func reTranscribeAppendsCoexistingAlternative() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let youtube = FakeYouTubeFetcher(markdown: "v1 transcript.")

        // Ingest + transcribe v1. YouTube ingestion writes a synthetic
        // metadata page (issue #646) as the initial HEAD; transcribe then
        // appends the v1 transcript as a coexisting alternative that becomes
        // the new HEAD.
        _ = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: BytelessEmbedIntegrationTests.YouTubeFixtureFetcher(),
            podcastFetcher: nil,
            youtubeFetcher: nil)
        let sources = try store.listSources()
        let stored = try #require(sources.first)
        // Sanity: at ingest, only the synthetic metadata page exists.
        let historyAfterIngest = try store.processedMarkdownHistory(sourceID: stored.id)
        #expect(historyAfterIngest.count == 1)
        _ = try await model.transcribe(sourceID: stored.id, youtubeFetcher: youtube)
        // After transcribe v1: synthetic page + v1 transcript (history.count == 2).
        // The synthetic page stays in history as an alternative.
        let historyAfterV1 = try store.processedMarkdownHistory(sourceID: stored.id)
        #expect(historyAfterV1.count == 2)
        let v1 = try #require(try store.processedMarkdownHead(sourceID: stored.id))
        #expect(v1.content == "v1 transcript.")
        #expect(v1.technique == "youtube-captions")

        // Swap the canned transcript + transcribe v2.
        youtube.markdown = "v2 transcript."
        _ = try await model.transcribe(sourceID: stored.id, youtubeFetcher: youtube)

        // A new version was appended (no clobber of v1). History now has
        // synthetic page + v1 + v2 (count == 3).
        let historyAfterV2 = try store.processedMarkdownHistory(sourceID: stored.id)
        #expect(historyAfterV2.count == 3)
        let v2 = try #require(try store.processedMarkdownHead(sourceID: stored.id))
        #expect(v2.content == "v2 transcript.")
        #expect(v2.technique == "youtube-captions")
        #expect(v1.id != v2.id)
        // v1 is still in the history (it's an alternative now).
        #expect(historyAfterV2.contains(where: { $0.id == v1.id }))
    }

    // MARK: - AC.7: Non-media sources throw .notRefreshable

    /// A defensive guard: calling `transcribe(sourceID:)` on a non-transcript-
    /// capable source (e.g. a local-file source) throws
    /// `SourceRefreshService.RefreshError.notRefreshable`. The View-level
    /// `isTranscribable` predicate (PR5) already returns `false` for
    /// non-`.applePodcast` / non-`.youtube` sources via
    /// `provider.supportsTranscription`, so the button doesn't render — this
    /// test pins the model-level guard that backstops a caller bypassing the
    /// predicate (a headless API, a future wikictl verb).
    @Test func transcribeNonMediaSourceThrowsNotRefreshable() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // A local-file source has no transcript pipeline.
        _ = try store.addSource(
            filename: "notes.txt", data: Data("hello".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: nil)
        let source = try #require(try store.listSources().first)

        await #expect(throws: SourceRefreshService.RefreshError.self) {
            _ = try await model.transcribe(sourceID: source.id, youtubeFetcher: FakeYouTubeFetcher())
        }
    }

    // MARK: - AC.7b: YouTube source with no video ID throws .missingPlan

    /// A YouTube source whose `origin.externalIdentity` is missing AND whose
    /// `origin.plan` URL can't be re-parsed as a YouTube URL throws
    /// `.missingPlan` — a data-integrity edge case. The ingester always sets
    /// `externalIdentity` to the 11-char ID via `MediaEmbedURL.youtube`, so
    /// this only fires for legacy rows written before the typed
    /// `MediaEmbedMatch` landed, or for a directly-inserted test source.
    @Test func transcribeYouTubeWithMissingVideoIDThrowsMissingPlan() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // Insert a YouTube source with NO externalIdentity AND a non-YouTube
        // plan URL (a data-integrity edge case — would only happen on a
        // legacy / manually-edited row).
        _ = try store.addBytelessSource(
            filename: "youtube-unknown",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: "https://example.com/some-other-url",
                externalRef: "https://example.com/some-other-url",
                externalIdentity: nil),
            role: .primary)
        let source = try #require(try store.listSources().first)
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        #expect(origin.externalIdentity == nil)
        #expect(origin.provider == .youtube)

        await #expect(throws: SourceRefreshService.RefreshError.missingPlan) {
            _ = try await model.transcribe(sourceID: source.id, youtubeFetcher: FakeYouTubeFetcher())
        }
    }

    // MARK: - AC.7c: YouTube source with no fetcher throws .notRefreshable

    /// A YouTube source with no injected fetcher throws
    /// `.notRefreshable("youtube")`. Production always constructs the default
    /// `YouTubeTranscriptService(fetcher: URLSessionFetcher())` at the
    /// dispatch entry point, so this throw is unreachable in production UI;
    /// the test pins the model-level guard for callers that bypass the
    /// default (e.g. a headless API that explicitly injects `nil`).
    @Test func transcribeYouTubeWithMissingFetcherThrowsNotRefreshable() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // Ingest a real YouTube URL so externalIdentity is recorded.
        _ = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: BytelessEmbedIntegrationTests.YouTubeFixtureFetcher(),
            podcastFetcher: nil,
            youtubeFetcher: nil)
        let source = try #require(try store.listSources().first)

        // Transcribe with no fetcher — explicitly nil. The dispatch entry
        // point's default is non-nil (production never hits this branch).
        await #expect(throws: SourceRefreshService.RefreshError.notRefreshable("youtube")) {
            _ = try await model.transcribe(sourceID: source.id, youtubeFetcher: nil)
        }
    }
}
