import Foundation
import Testing
@testable import WikiFS

/// Tests for the defuddle HTML extraction service.
///
/// These tests run the REAL bundled bun + defuddle script (no mocks). They
/// **skip gracefully** if `DefuddleExtractionService.resolve()` returns nil
/// (CI, clean dev before `make build`) — defuddle is opt-in until the script is
/// bundled via `build.sh`. See `plans/defuddle-extraction.md` §5.
@Suite struct DefuddleExtractionServiceTests {

    /// Whether bun + the defuddle script are resolvable on this machine.
    private var resolved: (bun: URL, script: URL)? {
        DefuddleExtractionService.resolve()
    }

    // MARK: - End-to-end extraction (real subprocess)

    @Test func extractsMarkdownAndMetadata() async throws {
        guard let _ = resolved else { return }  // skip if unbundled
        let html = #"""
        <html><head>
        <title>Sample Article: A Test Page</title>
        <meta name="author" content="Jane Doe">
        <meta name="description" content="A test article">
        <meta property="article:published_time" content="2024-03-15T10:00:00Z">
        </head><body>
        <nav><a href="/">Home</a> | <a href="/about">About</a></nav>
        <article>
        <h1>Main Content</h1>
        <p>The <strong>main content</strong> paragraph.</p>
        <p>Second paragraph with a <a href="https://example.com">link</a>.</p>
        </article>
        <footer>Copyright 2024. All rights reserved.</footer>
        </body></html>
        """#
        let result = try #require(await DefuddleExtractionService.extract(html: html))

        // Markdown contains the article body.
        #expect(result.markdown.contains("main content"))
        #expect(result.markdown.contains("Second paragraph"))

        // Nav/footer boilerplate stripped (site-specific readability extraction).
        #expect(!result.markdown.contains("Home"))
        #expect(!result.markdown.contains("Copyright"))
        #expect(!result.markdown.contains("About"))

        // Metadata parsed.
        #expect(result.title == "Sample Article: A Test Page")
        #expect(result.author == "Jane Doe")
        #expect(result.published == "2024-03-15T10:00:00Z")

        // Word count is positive.
        #expect((result.wordCount ?? 0) > 0)
    }

    @Test func extractsSimpleArticle() async throws {
        guard let _ = resolved else { return }
        let html = #"<html><head><title>Simple</title></head><body><article><p>Hello world.</p></article></body></html>"#
        let result = try #require(await DefuddleExtractionService.extract(html: html))
        #expect(result.markdown.contains("Hello world."))
        #expect(result.title == "Simple")
    }

    // MARK: - Fallback: SPA / empty body → nil

    @Test func returnsNilForSPAEmptyBody() async {
        guard let _ = resolved else { return }
        let html = #"<html><head><title>SPA</title></head><body><div id="app"></div></body></html>"#
        let result = await DefuddleExtractionService.extract(html: html)
        #expect(result == nil)  // fallback trigger — caller uses tag-based
    }

    @Test func returnsNilForEmptyInput() async {
        guard let _ = resolved else { return }
        #expect(await DefuddleExtractionService.extract(html: "") == nil)
    }

    // MARK: - Binary resolution

    @Test func resolvesBunAndScript() {
        guard resolved != nil else { return }
        let r = DefuddleExtractionService.resolve()
        #expect(r != nil)
        #expect(r?.bun.lastPathComponent == "bun")
        #expect(r?.script.lastPathComponent == "defuddle")
    }

    // MARK: - OutputBuffer

    @Test func outputBufferAccumulatesAndTakes() {
        let buf = DefuddleExtractionService.OutputBuffer()
        buf.append(Data("hello ".utf8))
        buf.append(Data("world".utf8))
        let taken = buf.take()
        #expect(String(data: taken, encoding: .utf8) == "hello world")
    }

    @Test func outputBufferTakeReturnsEmptyWhenNothingAppended() {
        let buf = DefuddleExtractionService.OutputBuffer()
        #expect(buf.take().isEmpty)
    }

    @Test func outputBufferIsConcurrentSafe() async {
        let buf = DefuddleExtractionService.OutputBuffer()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { buf.append(Data("chunk\(i) ".utf8)) }
            }
        }
        let taken = buf.take()
        // All 100 chunks should be present (order not guaranteed).
        for i in 0..<100 {
            #expect(String(data: taken, encoding: .utf8)?.contains("chunk\(i)") == true)
        }
    }

    // MARK: - ProcessRegistry

    @Test func processRegistryTracksAndUntracks() {
        let reg = DefuddleExtractionService.ProcessRegistry()
        let p = Process()
        reg.track(p)
        reg.untrack(p)
    }

    @Test func processRegistryTerminatesTracked() {
        let reg = DefuddleExtractionService.ProcessRegistry()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["999"]
        try? p.run()
        #expect(p.isRunning)

        reg.track(p)
        reg.terminateAllForTesting()
        p.waitUntilExit()
        #expect(!p.isRunning)
        #expect(p.terminationStatus != 0)
    }
}
