import Testing
import Foundation
@testable import WikiFSCore

/// Phase 4 pure/async tests for `WebsiteSnapshotExtractor`.
/// Covers AC.2 (relative srcs incl. absolute normalization), AC.3 (collision
/// disambiguation), AC.6 (caps). Uses an injected fake fetcher — no network.
struct WebsiteSnapshotExtractorTests {

    // MARK: - Test doubles

    /// A fake fetcher that maps absolute URL strings to canned responses.
    struct MultiURLFetcher: URLFetchService.URLResourceFetcher {
        var responses: [String: URLFetchService.FetchResponse]
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            if let r = responses[url.absoluteString] { return r }
            throw URLFetchService.FetchError.network("no fake response for \(url)")
        }
    }

    /// Minimal valid PNG bytes (8-byte header + IHDR start) so ContentSniff
    /// detects `image/png`.
    private let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    ])

    private func pngResponse(url: String) -> URLFetchService.FetchResponse {
        URLFetchService.FetchResponse(
            data: pngBytes, contentType: "image/png",
            finalURL: URL(string: url)!)
    }

    private let provenance = SourceProvenance(
        agentName: "website", activityKind: "fetch",
        plan: "https://example.com/page",
        externalRef: "https://example.com/page",
        externalIdentity: "https://example.com/page")

    private let dummyPlan = FormatPlan(
        filename: "Page.md", data: Data("placeholder".utf8), format: .htmlConverted)

    // MARK: - AC.2: relative srcs + absolute normalization (D4)

    @Test func convertedMarkdownCarriesRelativeSrcs() async throws {
        // HTML with one relative and one absolute image src.
        let html = """
        <html><head><title>Page</title></head><body>
        <article>
        <p>Text</p>
        <img src="images/foo.png" alt="foo">
        <img src="https://cdn.example.com/assets/bar.png" alt="bar">
        </article></body></html>
        """
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/images/foo.png": pngResponse(url: "https://example.com/images/foo.png"),
            "https://cdn.example.com/assets/bar.png": pngResponse(url: "https://cdn.example.com/assets/bar.png"),
        ])
        let snapshot = try await WebsiteSnapshotExtractor.snapshot(
            html: html, finalURL: URL(string: "https://example.com/page")!,
            fetcher: fetcher, filename: "Page.md",
            provenance: provenance, plan: dummyPlan)

        let md = String(data: snapshot.page.data, encoding: .utf8) ?? ""
        // The relative src is unchanged; the absolute src is normalized to its
        // relative original_path (D4).
        #expect(md.contains("](images/foo.png)"))
        #expect(md.contains("](assets/bar.png)"))
        #expect(!md.contains("cdn.example.com"))
        #expect(snapshot.images.count == 2)
    }

    // MARK: - AC.3: collision disambiguation

    @Test func collisionDisambiguatesPaths() async throws {
        // Two different hosts, same path component → collision.
        let html = """
        <html><body><article>
        <img src="https://a.example.com/images/foo.png">
        <img src="https://b.example.com/images/foo.png">
        </article></body></html>
        """
        let fetcher = MultiURLFetcher(responses: [
            "https://a.example.com/images/foo.png": pngResponse(url: "https://a.example.com/images/foo.png"),
            "https://b.example.com/images/foo.png": pngResponse(url: "https://b.example.com/images/foo.png"),
        ])
        let snapshot = try await WebsiteSnapshotExtractor.snapshot(
            html: html, finalURL: URL(string: "https://example.com/page")!,
            fetcher: fetcher, filename: "Page.md",
            provenance: provenance, plan: dummyPlan)

        let paths = snapshot.images.map(\.originalPath).sorted()
        #expect(paths == ["images/foo-1.png", "images/foo.png"])
    }

    // MARK: - AC.6: caps skip over-limit image

    @Test func overCapImageSkippedSnapshotCompletes() async throws {
        // One normal image + one over-cap (21 MB > 20 MB).
        let bigBytes = Data(repeating: 0x00, count: 21 * 1024 * 1024)
        let html = """
        <html><body><article>
        <img src="images/small.png">
        <img src="images/huge.png">
        </article></body></html>
        """
        let fetcher = MultiURLFetcher(responses: [
            "https://example.com/images/small.png": pngResponse(url: "https://example.com/images/small.png"),
            "https://example.com/images/huge.png": URLFetchService.FetchResponse(
                data: bigBytes, contentType: "image/png",
                finalURL: URL(string: "https://example.com/images/huge.png")!),
        ])
        let snapshot = try await WebsiteSnapshotExtractor.snapshot(
            html: html, finalURL: URL(string: "https://example.com/page")!,
            fetcher: fetcher, filename: "Page.md",
            provenance: provenance, plan: dummyPlan)

        // The small image is stored; the huge one is skipped (not fatal).
        #expect(snapshot.images.count == 1)
        #expect(snapshot.images.first?.originalPath == "images/small.png")
    }
}
