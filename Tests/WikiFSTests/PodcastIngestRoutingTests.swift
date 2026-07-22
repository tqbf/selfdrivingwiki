#if PODCAST_TRANSCRIPTS  // Feature off for WIKIFS_APP_STORE=1 builds.
import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.addURL` ROUTES an Apple Podcasts episode link to
/// the byteless-embed pipeline (not the HTML fetcher) and stores the source
/// WITHOUT a transcript. Issue #799 PR4: ingest is byteless-only — no auto-
/// transcription. The user clicks "Transcribe" in `SourceDetailView` to
/// trigger the network fetch explicitly via `transcribePodcast(sourceID:)`.
///
/// Uses a fake `PodcastTranscriptFetching` + a fake HTML fetcher so we can
/// assert which path ran — no network, no private frameworks.
@MainActor
struct PodcastIngestRoutingTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-podcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Records whether it was asked for a transcript, and returns a canned one.
    final class FakePodcastFetcher: PodcastTranscriptFetching, @unchecked Sendable {
        private(set) var requestedEpisodeID: String?
        /// Marks the per-call markdown so a swap between two transcribe calls
        /// can simulate "v1" vs "v2" (mirrors `SourceRefreshTests`'s SwapFetcher).
        var markdown: String
        init(markdown: String = "SPEAKER_1: Hello from the episode.") {
            self.markdown = markdown
        }
        func transcript(for episode: PodcastEpisodeURL.EpisodeRef) async throws -> PodcastTranscript {
            requestedEpisodeID = episode.id
            return PodcastTranscript(
                episodeID: episode.id,
                markdown: markdown,
                filename: "\(episode.slug ?? "podcast")-\(episode.id)-transcript.md")
        }
    }

    /// Fails if the HTML fetch path is taken — a podcast URL must NOT reach it.
    struct ExplodingFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            Issue.record("HTML fetcher must not run for an Apple Podcasts episode URL")
            throw URLFetchService.FetchError.empty
        }
    }

    private static let chinaTalkURL =
        "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453"

    // MARK: - AC.14: Ingest stores byteless embed WITHOUT a transcript

    /// Issue #799 PR4 AC.14 — ingesting an Apple Podcasts episode URL stores
    /// a byteless embed source with NO transcript. The fetcher is NOT
    /// consulted at ingest (this is the post-PR4 invariant; pre-PR4 ingest
    /// fetched the transcript AND stored it as the processed-markdown HEAD).
    /// The Transcribe button (PR4) is what triggers the fetch — see
    /// `transcribePodcastWritesTranscriptAlternative` (AC.15).
    @Test func episodeURLStoresBytelessEmbedWithoutTranscript() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

        // The fetcher was NOT consulted at ingest — PR4 stopped auto-
        // transcribing. The transcribe trigger is a separate code path.
        #expect(podcast.requestedEpisodeID == nil)
        // Outcome reports the byteless audio-embed (matching Spotify/SoundCloud),
        // NOT `.podcastTranscript` (which implied a transcript was fetched).
        #expect(outcome.kind == .audioEmbed)
        #expect(outcome.byteSize == 0)
        // Filename is `<slug>-<id>` (mirrors YouTube's `youtube-<id>`); the
        // `-transcript.md` suffix is reserved for the transcript version row's
        // filename (written by `transcribePodcast(sourceID:)`), NOT the embed
        // source's filename.
        #expect(outcome.filename == "chinatalk-1000774368453")

        // §11 byteless model: the source is byteless (no content bytes).
        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.byteSize == 0)
        // sourceContent returns empty Data for a byteless source.
        #expect(try store.sourceContent(id: stored.id).isEmpty)
        // No processed-markdown version was written — the source's
        // `source_markdown_versions` is empty until the user transcribes.
        #expect(try store.processedMarkdownHead(sourceID: stored.id) == nil)
        // Origin provenance: apple-podcast agent + pasted episode URL + numeric ID.
        let origin = try #require(try store.sourceOrigin(sourceID: stored.id))
        #expect(origin.agentName == "apple-podcast")
        #expect(origin.plan == Self.chinaTalkURL)
        #expect(origin.externalIdentity == "1000774368453")
    }

    @Test func pastingSameEpisodeTwiceDedupsAsByteless() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        _ = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

        // Second paste of the same episode URL → duplicate (byteless dedup on
        // external_identity).
        await #expect(throws: WikiStoreError.self) {
            try await model.addURL(
                Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)
        }
        // Only one source was created.
        let sources = try store.listSources()
        #expect(sources.count == 1)
    }

    // MARK: - AC.16: Transcribe throws a clear error when the helper is missing

    /// Issue #799 PR4 AC.16 — the Transcribe trigger throws
    /// `PodcastTranscriptError.signatureUnavailable` when the signing helper
    /// is unavailable. Pre-PR4 this check fired AT INGEST (because ingest
    /// fetched the transcript); post-PR4 ingest succeeds (byteless only) and
    /// the check fires here, in `transcribePodcast(sourceID:fetcher:)`. The
    /// View-level predicate (`store.isSourceRefreshable(for:)` returns `false`
    /// for `.applePodcast` when `ApplePodcastTranscriptService.bundled()` is
    /// nil) hides the button, so this throw is unreachable in production UI
    /// — but the model stays honest for callers that bypass the predicate.
    @Test func transcribePodcastThrowsSignatureUnavailableWithoutHelper() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // Ingest SUCCEEDS without a helper (PR4 contract: byteless only).
        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: nil)
        #expect(outcome.kind == .audioEmbed)

        // But transcribe MUST throw — there's no helper.
        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        await #expect(throws: PodcastTranscriptError.self) {
            _ = try await model.transcribePodcast(sourceID: stored.id, fetcher: nil)
        }
        // No transcript was written (the throw happened before
        // `appendProcessedMarkdown`).
        #expect(try store.processedMarkdownHead(sourceID: stored.id) == nil)
    }

    @Test func nonPodcastURLStillUsesHTMLFetcher() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)

        // A normal URL must NOT touch the podcast path; a fetcher returning HTML
        // proves the ordinary route still runs (and the exploding podcast fetcher
        // is never consulted).
        struct HTMLFetcher: URLFetchService.URLResourceFetcher {
            func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
                URLFetchService.FetchResponse(
                    data: Data("<title>Hi</title><p>x</p>".utf8),
                    contentType: "text/html", finalURL: url)
            }
        }
        let outcome = try await model.addURL(
            "https://example.com/article", fetcher: HTMLFetcher(), podcastFetcher: nil)
        #expect(outcome.kind == .html)  // #599: HTML now preserved, outcome kind .html
    }

    /// Phase 4b routing-precedence: an Apple Podcasts episode URL must still
    /// route to `.audioEmbed` (apple-podcast stays FIRST) even though the new
    /// media recognizers are now wired in `addURL`. A `podcasts.apple.com`
    /// URL is not a recognized media-provider URL, but the order is pinned so a
    /// future recognizer can't accidentally shadow it.
    @Test func podcastURLStaysFirstInRoutingPrecedence() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)
        #expect(outcome.kind == .audioEmbed)
        // The fetcher is NOT consulted at ingest (PR4 contract); the
        // `podcastURLStaysFirstInRoutingPrecedence` check is about routing
        // precedence, not transcript fetch.
        #expect(podcast.requestedEpisodeID == nil)
    }

    /// Issue #621: the source's display name must be the un-slugified episode
    /// title (written via `setSourceDisplayName`, mirroring the oEmbed title
    /// step for YouTube/Vimeo/Spotify/SoundCloud) — NOT the slugified filename
    /// `chinatalk-1000774368453`.
    @Test func episodeURLSetsDisplayTitleFromSlug() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

        // Re-fetch (the in-memory `summary` came back BEFORE the
        // setSourceDisplayName write). `effectiveName` reads displayName first
        // and falls back to filename only when unset — so the title shows up as
        // the source's effective name everywhere in the UI.
        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.displayName == "Chinatalk")
        #expect(stored.effectiveName == "Chinatalk")
    }

    /// Issue #621: an episode URL with a multi-word slug resolves a real
    /// title-cased display name (small words kept lowercase) instead of the
    /// slug filename.
    @Test func multiWordSlugResolvesTitleCasedDisplayName() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        // The issue's driving example episode URL — the slug is the entire
        // episode title as Apple generates it for an episode link.
        let url = "https://podcasts.apple.com/us/podcast/"
            + "if-you-care-about-food-you-have-to-care-about-land/"
            + "id1728932037?i=1000714478537"
        let outcome = try await model.addURL(
            url, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.displayName
                == "If You Care About Food You Have to Care About Land")
        #expect(stored.effectiveName
                == "If You Care About Food You Have to Care About Land")
    }

    /// Issue #621 edge case: an episode URL with no `/podcast/<slug>/` path
    /// (an unusual but parseable episode URL) leaves the display name unset —
    /// the slug → title helper returns nil and the synthetic filename display
    /// name stays in place, mirroring the oEmbed-nil discipline.
    @Test func sluglessEpisodeURLLeavesFilenameDisplayName() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher()

        let url = "https://podcasts.apple.com/us?i=1000774368453"
        let outcome = try await model.addURL(
            url, fetcher: ExplodingFetcher(), podcastFetcher: podcast)

        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        #expect(stored.displayName == nil)
        // `effectiveName` falls through to the synthetic filename.
        #expect(stored.effectiveName == stored.filename)
    }

    // MARK: - AC.15: Transcribe trigger creates the transcript HEAD

    /// Issue #799 PR4 AC.15 — tapping Transcribe on an un-transcribed podcast
    /// source triggers `PodcastTranscriptFetching.transcript(for:)` and creates
    /// a transcript processed-markdown version (HEAD, `.transcript` origin,
    /// `"apple-ttml"` technique). Proves the Transcribe trigger fires on a
    /// fresh byteless source ingested post-PR4 (no transcript at ingest).
    @Test func transcribePodcastWritesTranscriptAlternative() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher(markdown: "SPEAKER_1: First transcript.")

        // 1. Ingest — byteless only, no transcript.
        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)
        #expect(outcome.kind == .audioEmbed)
        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        // Sanity: no transcript at ingest (the PR4 invariant).
        #expect(try store.processedMarkdownHead(sourceID: stored.id) == nil)

        // 2. Transcribe — the user clicks the Transcribe button.
        let head = try #require(
            try await model.transcribePodcast(sourceID: stored.id, fetcher: podcast))

        // The fetcher was consulted, with the episode ID reconstructed from
        // `origin.plan` (the pasted URL stored as provenance).
        #expect(podcast.requestedEpisodeID == "1000774368453")
        // The transcript markdown is the new HEAD.
        #expect(head.origin == .transcript)
        #expect(head.technique == "apple-ttml")
        #expect(head.content == "SPEAKER_1: First transcript.")
        // Re-read from the store to confirm persistence.
        let persisted = try #require(try store.processedMarkdownHead(sourceID: stored.id))
        #expect(persisted.content == "SPEAKER_1: First transcript.")
        #expect(persisted.origin == .transcript)
        #expect(persisted.technique == "apple-ttml")
    }

    // MARK: - Defensive guard: non-podcast source

    /// A defensive guard: calling `transcribePodcast(sourceID:)` on a
    /// non-podcast source (e.g. a local-file source) throws
    /// `SourceRefreshService.RefreshError.notRefreshable`. The View-level
    /// predicate `isSourceRefreshable(for:)` already returns `false` for
    /// non-`.applePodcast` sources, so the button doesn't render — this test
    /// pins the model-level guard that backstops a caller bypassing the
    /// predicate (a headless API, a future wikictl verb).
    @Test func transcribeNonPodcastSourceThrowsNotRefreshable() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // A local-file source has no apple-podcast provenance.
        _ = try store.addSource(
            filename: "notes.txt", data: Data("hello".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: nil)
        let source = try #require(try store.listSources().first)

        await #expect(throws: SourceRefreshService.RefreshError.self) {
            _ = try await model.transcribePodcast(sourceID: source.id, fetcher: FakePodcastFetcher())
        }
    }

    // MARK: - Re-transcribe appends coexisting alternative

    /// Issue #799 PR4 — `transcribePodcast(sourceID:)` always appends a new
    /// processed-markdown version (never clobbers). The first call creates the
    /// HEAD; subsequent calls append coexisting alternatives. So a re-
    /// transcribe creates an alternative the provenance chip + Re-transcribe
    /// with menu surface for the user to pick. Mirrors the HTML
    /// `reExtractHtmlAppendsCoexistingAlternative` (PR2): same method, same
    /// write path (`appendProcessedMarkdown`), same append semantic.
    @Test func reTranscribeAppendsCoexistingAlternative() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let podcast = FakePodcastFetcher(markdown: "SPEAKER_1: v1 transcript.")

        // Ingest + transcribe v1.
        let outcome = try await model.addURL(
            Self.chinaTalkURL, fetcher: ExplodingFetcher(), podcastFetcher: podcast)
        let sources = try store.listSources()
        let stored = try #require(sources.first { $0.filename == outcome.filename })
        _ = try await model.transcribePodcast(sourceID: stored.id, fetcher: podcast)
        let historyAfterV1 = try store.processedMarkdownHistory(sourceID: stored.id)
        #expect(historyAfterV1.count == 1)
        let v1 = try #require(try store.processedMarkdownHead(sourceID: stored.id))
        #expect(v1.content == "SPEAKER_1: v1 transcript.")

        // Swap the canned transcript + transcribe v2.
        podcast.markdown = "SPEAKER_1: v2 transcript."
        _ = try await model.transcribePodcast(sourceID: stored.id, fetcher: podcast)

        // A new version was appended (no clobber of v1).
        let historyAfterV2 = try store.processedMarkdownHistory(sourceID: stored.id)
        #expect(historyAfterV2.count == 2)
        let v2 = try #require(try store.processedMarkdownHead(sourceID: stored.id))
        #expect(v2.content == "SPEAKER_1: v2 transcript.")
        #expect(v1.id != v2.id)
        // v1 is still in the history (it's an alternative now).
        #expect(historyAfterV2.contains(where: { $0.id == v1.id }))
    }
}
#endif
