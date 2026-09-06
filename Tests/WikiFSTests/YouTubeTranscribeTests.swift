import Foundation
import Testing
@testable import WikiFSCore

/// YouTube transcription routing after the youtube-transcript package
/// packaging. `WikiStoreModel.transcribe(sourceID:)` is pure dispatch: every
/// transcript-capable provider (`.applePodcast`, `.podcast`, `.youtube`)
/// throws `.transcriptQueueRequired` so the caller enqueues the durable
/// extraction job, whose youtube-transcript package route performs the fetch
/// and writes installed-package provenance (covered by
/// `AppQueueExtractionProviderTests`).
///
/// This suite pins the model-side contract: the queue-required throw, the
/// no-write guarantee on that dispatch, the byteless ingest boundary, and
/// the typed `YouTubeSourceURL` resolution (plan URL first, canonical
/// watch URL from a legacy video ID, nil for unusable data).
@MainActor
struct YouTubeTranscribeTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-youtube-transcribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - Transcribe requires the durable extraction queue

    /// Transcribing a YouTube source throws `.transcriptQueueRequired`: the
    /// model has no direct fetch path anymore. The queue's package adapter
    /// resolves the transcript and writes exact installed-package provenance.
    @Test func transcribeRequiresTheExtractionQueue() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        _ = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: BytelessEmbedIntegrationTests.YouTubeFixtureFetcher())
        let stored = try #require(try store.listSources().first)

        await #expect(throws: SourceRefreshService.RefreshError.transcriptQueueRequired) {
            _ = try await model.transcribe(sourceID: stored.id)
        }
    }

    /// The queue-required dispatch writes nothing: the synthetic metadata
    /// page stays the head, and no `.youtubeCaptions` transcript version is
    /// created by the model path.
    @Test func queueRequiredDispatchWritesNoTranscriptVersion() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        _ = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: BytelessEmbedIntegrationTests.YouTubeFixtureFetcher())
        let stored = try #require(try store.listSources().first)

        _ = try? await model.transcribe(sourceID: stored.id)

        let alternatives = try store.processedMarkdownAlternatives(sourceID: stored.id)
        #expect(alternatives.allSatisfy { $0.version.technique != "youtube-captions" })
        let head = try #require(try store.processedMarkdownHead(sourceID: stored.id))
        #expect(head.technique == "byteless-oembed-synthetic")
    }

    /// Ingest stays byteless: no transcript content exists after `addURL`,
    /// only the synthetic metadata page.
    @Test func ingestRemainsBytelessAndTranscriptFree() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetcher: BytelessEmbedIntegrationTests.YouTubeFixtureFetcher())
        #expect(outcome.kind == .videoEmbed)

        let stored = try #require(try store.listSources().first)
        #expect(stored.byteSize == 0)
        let alternatives = try store.processedMarkdownAlternatives(sourceID: stored.id)
        #expect(alternatives.count == 1)
        #expect(alternatives.first?.version.technique == "byteless-oembed-synthetic")
        #expect(alternatives.first?.version.content.contains("Hello world") == false)
    }

    /// Non-transcript providers keep throwing `.notRefreshable`.
    @Test func nonTranscriptProvidersStayNotRefreshable() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        _ = try store.addBytelessSource(
            filename: "vimeo-1",
            mimeType: "video/vimeo",
            provenance: SourceProvenance(
                agentName: "vimeo", activityKind: "fetch",
                plan: "https://vimeo.com/1",
                externalRef: nil, externalIdentity: "1"),
            role: .primary)
        let stored = try #require(try store.listSources().first)

        await #expect(throws: SourceRefreshService.RefreshError.self) {
            _ = try await model.transcribe(sourceID: stored.id)
        }
    }

    // MARK: - YouTubeSourceURL resolution (the queue provider's input gate)

    /// The stored plan URL wins when it validates, preserving watch, short,
    /// Shorts, and embed source contracts.
    @Test func planURLWinsWhenItValidates() {
        #expect(
            YouTubeSourceURL.resolveOperationURL(
                plan: "https://youtu.be/dQw4w9WgXcQ",
                externalIdentity: "AAAAAAAAAAA") == URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        #expect(
            YouTubeSourceURL.resolveOperationURL(
                plan: "https://www.youtube.com/shorts/dQw4w9WgXcQ",
                externalIdentity: "dQw4w9WgXcQ") == URL(string: "https://www.youtube.com/shorts/dQw4w9WgXcQ"))
        #expect(
            YouTubeSourceURL.resolveOperationURL(
                plan: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90s",
                externalIdentity: "dQw4w9WgXcQ")?
                .absoluteString.contains("dQw4w9WgXcQ") == true)
    }

    /// A legacy row with a valid 11-char video ID but no usable plan URL
    /// resolves to the canonical watch URL.
    @Test func legacyIdentityResolvesToCanonicalWatchURL() {
        #expect(
            YouTubeSourceURL.resolveOperationURL(
                plan: nil,
                externalIdentity: "dQw4w9WgXcQ")
            == URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(
            YouTubeSourceURL.resolveOperationURL(
                plan: "not a url",
                externalIdentity: "dQw4w9WgXcQ")
            == URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    /// Invalid data never yields a URL: a malformed identity, a missing
    /// identity, or a non-YouTube plan with no identity all resolve to nil,
    /// so the queue provider never launches a package for them.
    @Test func invalidDataResolvesToNil() {
        #expect(YouTubeSourceURL.resolveOperationURL(plan: nil, externalIdentity: nil) == nil)
        #expect(YouTubeSourceURL.resolveOperationURL(plan: nil, externalIdentity: "short") == nil)
        #expect(YouTubeSourceURL.resolveOperationURL(plan: nil, externalIdentity: "has space!!") == nil)
        #expect(
            YouTubeSourceURL.resolveOperationURL(
                plan: "https://example.com/watch?v=dQw4w9WgXcQ",
                externalIdentity: nil) == nil)
        #expect(
            YouTubeSourceURL.resolveOperationURL(
                plan: "https://example.com/watch?v=dQw4w9WgXcQ",
                externalIdentity: "bad id") == nil)
    }

    /// The identity validator is ASCII-strict: an 11-character non-ASCII
    /// string (which `Character.isLetter` would accept) must not reconstruct
    /// a watch URL — the package's own pattern admits ASCII only, so such
    /// data must fail here instead of launching a package.
    @Test func nonASCIIIdentityResolvesToNil() {
        #expect(YouTubeSourceURL.resolveOperationURL(plan: nil, externalIdentity: "dQw4w9WgXcÉ") == nil)
        #expect(YouTubeSourceURL.resolveOperationURL(plan: nil, externalIdentity: "𝐝Qw4w9WgXcQ") == nil)
        #expect(MediaEmbedURL.isValidVideoID("dQw4w9WgXcÉ") == false)
        #expect(MediaEmbedURL.isValidVideoID("dQw4w9WgXcQ"))
    }
}
