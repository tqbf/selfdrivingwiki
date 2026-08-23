#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine

@Suite("Extraction plugin boot", .serialized, .timeLimit(.minutes(1)))
struct ExtractionPluginBootTests {
    @Test("fixture-safe adapters register and unload")
    func adaptersRegisterAndUnload() async throws {
        let http = FakeHTTPFetcher(body: Data(), statusCode: 200)
        let configuration = ExtractionConfig()
        let entries = [
            Entry(id: EntryID("extraction"), plugin: ExtractionPlugin.id),
            Entry(id: EntryID("pdf2md"), plugin: Pdf2mdExtractionPlugin.id),
            Entry(id: EntryID("acp"), plugin: ACPExtractionPlugin.id),
            Entry(
                id: EntryID("anthropic"),
                plugin: AnthropicExtractionPlugin.id,
                config: [
                    "model": .string("fixture-anthropic"),
                    "baseURL": .string("https://example.invalid/anthropic"),
                ]),
            Entry(
                id: EntryID("gemini"),
                plugin: GeminiExtractionPlugin.id,
                config: [
                    "model": .string("fixture-gemini"),
                    "baseURL": .string("https://example.invalid/gemini"),
                ]),
            Entry(
                id: EntryID("docling"),
                plugin: DoclingExtractionPlugin.id,
                config: ["endpoint": .string("https://example.invalid/docling")]),
            Entry(id: EntryID("defuddle"), plugin: DefuddleExtractionPlugin.id),
            Entry(id: EntryID("youtube"), plugin: YouTubeTranscriptPlugin.id),
            Entry(id: EntryID("rss-podcast"), plugin: RSSPodcastTranscriptPlugin.id),
            Entry(id: EntryID("apple-podcast"), plugin: ApplePodcastTranscriptPlugin.id),
        ]
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                ExtractionPlugin.definition,
                Pdf2mdExtractionPlugin.definition { FixturePDFExtractor() },
                ACPExtractionPlugin.definition(
                    configuration: configuration,
                    resolve: { _ in FixturePDFExtractor() },
                    fallback: { FixturePDFExtractor() }),
                AnthropicExtractionPlugin.definition(readCredential: { _ in nil }, fetcher: http),
                GeminiExtractionPlugin.definition(readCredential: { _ in nil }, fetcher: http),
                DoclingExtractionPlugin.definition(readCredential: { _ in nil }, fetcher: http),
                DefuddleExtractionPlugin.definition { FixtureHTMLExtractor() },
                YouTubeTranscriptPlugin.definition { FixtureYouTubeFetcher() },
                RSSPodcastTranscriptPlugin.definition { FixtureRSSPodcastFetcher() },
                ApplePodcastTranscriptPlugin.definition { FixtureApplePodcastFetcher() },
            ]),
            layers: [PatchFile(entries: entries)]))

        let registry = try #require(try await booted.context.find(ExtractionServiceKeys.backends))
        #expect(await registry.keys() == [
            ACPExtractionPlugin.key,
            AnthropicExtractionPlugin.key,
            ApplePodcastTranscriptPlugin.key,
            DefuddleExtractionPlugin.key,
            DoclingExtractionPlugin.key,
            GeminiExtractionPlugin.key,
            Pdf2mdExtractionPlugin.key,
            RSSPodcastTranscriptPlugin.key,
            YouTubeTranscriptPlugin.key,
        ].sorted { $0.description < $1.description })

        try await booted.tree.update(to: entries.filter { $0.id != EntryID("gemini") })
        #expect(await registry.resolve(GeminiExtractionPlugin.key) == nil)
        #expect(await registry.resolve(Pdf2mdExtractionPlugin.key) != nil)

        try await booted.shutdown()
    }
}

private struct FixturePDFExtractor: MarkdownExtractor {
    let displayName = "fixture"
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "fixture" }
}

private struct FixtureHTMLExtractor: HtmlMarkdownExtractor {
    func extract(html: String) async -> HtmlExtractionResult? {
        HtmlExtractionResult(markdown: "fixture")
    }
}

private struct FixtureYouTubeFetcher: YouTubeTranscriptFetching {
    func transcript(forVideoID videoID: String) async throws -> YouTubeTranscript {
        YouTubeTranscript(videoID: videoID, title: "fixture", markdown: "fixture", filename: "fixture.md")
    }
}

private struct FixtureRSSPodcastFetcher: RSSFeedTranscriptFetching {
    func transcript(forFeedURL url: URL) async throws -> PodcastTranscript {
        PodcastTranscript(episodeID: "fixture", markdown: "fixture", filename: "fixture.md")
    }
}

private struct FixtureApplePodcastFetcher: PodcastTranscriptFetching {
    func transcript(for episode: PodcastEpisodeURL.EpisodeRef) async throws -> PodcastTranscript {
        PodcastTranscript(episodeID: episode.id, markdown: "fixture", filename: "fixture.md")
    }
}
#endif
