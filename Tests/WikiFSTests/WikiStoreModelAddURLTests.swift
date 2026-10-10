import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.addURL` lands a fetched resource through the SAME
/// store path as `addFiles`, so it appears under `sources` immediately and
/// is byte-correct. Uses a fake fetcher — no real network.
@MainActor
struct WikiStoreModelAddURLTests {

    // MARK: - Issue #1379 (revised): claim + route-policy auto-transcript signal

    /// Claims fixture: one transcript-extractor registration claiming the
    /// given MIME (the shape `registeredExtractionInputs()` builds from the
    /// active installed registrations).
    private static func claims(_ mimeType: String, kind: ExtractorKind = .youtubeTranscript) -> RegisteredExtractionInputs {
        RegisteredExtractionInputs(claims: [
            .init(kind: kind, mimeTypes: [mimeType], filenameExtensions: []),
        ])
    }

    /// Caption routes auto-transcribe at import: a YouTube URL import with
    /// an active registration queues the standard extraction job (the
    /// bundled import-transcription policy covers the YouTube route).
    @Test func youTubeURLQueuesTranscriptExtractionFromRoutePolicy() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        model.registeredExtractionInputs = Self.claims("video/youtube")
        let fetcher = FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data(), contentType: nil,
            finalURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))

        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ", fetcher: fetcher)

        #expect(outcome.kind == .videoEmbed)
        #expect(outcome.transcriptExtractionWanted)
        #expect(outcome.sourceID != nil)
        // The created source's MIME is what the claim matched. The byteless
        // path reloads async off the bus — reload explicitly for the read.
        model.reloadFromStore()
        let source = try #require(model.sources.first(where: { $0.id == outcome.sourceID }))
        #expect(source.mimeType == "video/youtube")
    }

    @Test func applePodcastsURLStillWantsTranscriptExtractionFromRoutePolicy() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        model.registeredExtractionInputs = Self.claims(
            "audio/apple-podcast", kind: .applePodcastTranscript)
        let episodeURL =
            "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453"

        let outcome = try await model.addURL(episodeURL)

        #expect(outcome.kind == .audioEmbed)
        #expect(outcome.transcriptExtractionWanted)
        #expect(outcome.sourceID != nil)
        model.reloadFromStore()
        let source = try #require(model.sources.first(where: { $0.id == outcome.sourceID }))
        #expect(source.mimeType == "audio/apple-podcast")
    }

    @Test func rssPodcastURLWantsTranscriptExtractionFromRoutePolicy() async throws {
        // The RSS podcast route keeps its existing import policy: claim +
        // policy entry → the signal flips and the importing UI enqueues the
        // extraction. Feeds enter through the dedicated podcast entry point.
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        model.registeredExtractionInputs = Self.claims(
            "audio/podcast", kind: .podcastTranscript)

        let outcome = try await model.addPodcastFeedURL(
            "https://feeds.example.com/show.xml")

        #expect(outcome.kind == .audioEmbed)
        #expect(outcome.transcriptExtractionWanted)
        #expect(outcome.sourceID != nil)
    }

    @Test func claimedMIMEWithoutRoutePolicyEntryReportsNotWanted() async throws {
        // A registration claims the MIME, but the claimed (kind, MIME) route
        // has no bundled import-transcription entry: the claim alone does
        // not flip the signal. Claiming the Apple Podcasts MIME with the
        // YouTube kind builds exactly that unclaimed-route shape without
        // naming any policy branch in the test.
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        model.registeredExtractionInputs = Self.claims(
            "audio/apple-podcast", kind: .youtubeTranscript)
        let episodeURL =
            "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453"

        let outcome = try await model.addURL(episodeURL)

        #expect(outcome.kind == .audioEmbed)
        #expect(outcome.transcriptExtractionWanted == false)
    }

    @Test func bytelessSourceWithNoClaimedMIMEReportsNotWanted() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // Only YouTube/Podcasts are claimed; nothing claims Vimeo.
        model.registeredExtractionInputs = Self.claims("video/youtube")
        let fetcher = FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data(), contentType: nil,
            finalURL: URL(string: "https://vimeo.com/76979871")!))

        let outcome = try await model.addURL("https://vimeo.com/76979871", fetcher: fetcher)

        #expect(outcome.kind == .videoEmbed)
        #expect(outcome.transcriptExtractionWanted == false)
        #expect(outcome.sourceID != nil)
    }

    @Test func unregisteredClaimsSetReportsNotWantedForEveryProvider() async throws {
        // No installed registrations at all: no provider reports wanted.
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let fetcher = FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data(), contentType: nil,
            finalURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))

        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ", fetcher: fetcher)

        #expect(outcome.transcriptExtractionWanted == false)
    }

    // MARK: - Fixtures

    actor FetchCallCounter {
        private(set) var count = 0
        func record() { count += 1 }
    }

    struct FakeFetcher: URLFetchService.URLResourceFetcher {
        let response: URLFetchService.FetchResponse
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse { response }
    }

    struct CountingFetcher: URLFetchService.URLResourceFetcher {
        let response: URLFetchService.FetchResponse
        let counter: FetchCallCounter
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            await counter.record()
            return response
        }
    }

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-addurl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    @Test func htmlURLLandsVerbatimWithoutMarkdownSidecar() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let model = WikiStoreModel(store: store)
        let recorder = SignalRecorder()
        store.eventBus?.subscribe(nil) { recorder.append($0) }

        let fetcher = FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data("<title>My Doc</title><body><h1>Heading</h1><p>Body.</p></body>".utf8),
            contentType: "text/html",
            finalURL: URL(string: "https://example.com/doc")!))

        let outcome = try await model.addURL("example.com/doc", fetcher: fetcher)
        model.reloadFromStore()

        // Issue #599 (issue #799 PR3 post-state): HTML sources preserve the
        // original HTML bytes as the source blob. The extracted-markdown
        // sidecar is NO LONGER written at ingest — `FormatMaterializer.dispatch`
        // returns `extractedMarkdown: nil` for HTML (PR3), so
        // `appendExtractedMarkdown` is a no-op. The user triggers extraction
        // via the Extract button (PR2). The format is still tagged `.html`
        // and the filename still uses the document `<title>`
        // (via `HTMLToMarkdown.titleOnly`) — only the markdown body
        // computation is skipped.
        #expect(outcome.kind == .html)
        #expect(outcome.filename == "My Doc.html")
        #expect(model.sources.count == 1)
        #expect(model.sources.first?.filename == "My Doc.html")
        #expect(model.sources.first?.ext == "html")
        try await recorder.awaitNonEmpty()
        #expect(recorder.count > 0, "the store write still fires a change event")

        // The source bytes ARE the original HTML.
        let id = model.sources.first!.id
        let bytes = try store.sourceContent(id: id)
        #expect(String(data: bytes, encoding: .utf8) == "<title>My Doc</title><body><h1>Heading</h1><p>Body.</p></body>")

        // PR3 AC.9: NO extracted-markdown sidecar lands — no
        // `source_markdown_versions` row exists for this source after ingest.
        // The user triggers extraction via the Extract button (see
        // `WikiStoreModelHtmlExtractionTests.extractHtmlWorksOnUnextractedURLIngest`).
        #expect(try store.processedMarkdownHead(sourceID: id) == nil,
               "PR3: non-snapshot HTML URL ingest must NOT auto-extract markdown")
        // History is also empty (no sidecar = no HEAD, no alternatives).
        #expect(try store.processedMarkdownHistory(sourceID: id).isEmpty)
    }

    @Test func pdfURLLandsVerbatim() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        var pdf = Data("%PDF-1.7".utf8)
        pdf.append(contentsOf: [0x00, 0xFF, 0x10])
        let fetcher = FakeFetcher(response: URLFetchService.FetchResponse(
            data: pdf, contentType: "application/pdf",
            finalURL: URL(string: "https://example.com/files/paper.pdf")!))

        let outcome = try await model.addURL("https://example.com/files/paper.pdf", fetcher: fetcher)
        model.reloadFromStore()
        #expect(outcome.kind == .pdf)
        #expect(model.sources.first?.filename == "paper.pdf")
        let id = model.sources.first!.id
        #expect(try store.sourceContent(id: id) == pdf)  // byte-identical
    }

    @Test func errorLeavesListUnchanged() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let fetcher = FakeFetcher(response: URLFetchService.FetchResponse(
            data: Data(), contentType: "text/html",
            finalURL: URL(string: "https://example.com")!))
        await #expect(throws: URLFetchService.FetchError.empty) {
            try await model.addURL("https://example.com", fetcher: fetcher)
        }
        #expect(model.sources.isEmpty)
    }

    @Test func duplicateURLIsRejectedBeforeFetchingAndCanBeExplicitlyOverridden() async throws {
        let store = try tempStore()
        let existing = try store.addSource(
            filename: "existing.html", data: Data("first".utf8),
            externalItemKey: nil, externalItemTitle: nil, mimeType: "text/html",
            provenance: SourceProvenance(
                agentName: "website", activityKind: "fetch",
                plan: "https://example.com/article", externalRef: "https://example.com/article#saved"))
        let model = WikiStoreModel(store: store)
        let counter = FetchCallCounter()
        let fetcher = CountingFetcher(response: URLFetchService.FetchResponse(
            data: Data("changed content".utf8), contentType: "text/plain",
            finalURL: URL(string: "https://example.com/article")!), counter: counter)

        do {
            _ = try await model.addURL("HTTPS://EXAMPLE.com/article#new", fetcher: fetcher)
            Issue.record("expected a URL duplicate")
        } catch WikiStoreError.duplicateURL(let matched) {
            #expect(matched.id == existing.id)
        }
        #expect(await counter.count == 0)
        #expect(try store.listSources().count == 1)

        _ = try await model.addURL(
            "https://example.com/article", fetcher: fetcher, allowDuplicateURL: true)
        #expect(await counter.count == 1)
        #expect(try store.listSources().count == 2)
    }
}
