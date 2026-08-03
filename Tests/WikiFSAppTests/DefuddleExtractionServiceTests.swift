#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

/// Tests for the defuddle HTML extraction service.
///
/// These tests run the REAL bundled bun + defuddle script (no mocks). They
/// **skip gracefully** if `DefuddleExtractionService.resolve()` returns nil
/// (CI, clean dev before `make build`) — defuddle is opt-in until the script is
/// bundled via `build.sh`. See `plans/defuddle-extraction.md` §5.
@Suite(.timeLimit(.minutes(2))) struct DefuddleExtractionServiceTests {

    private enum ProcessExitWaitError: Error {
        case timedOut
    }

    private final class ProcessExitWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            let result: Result<Void, Error>?
            lock.lock()
            if let storedResult = self.result {
                result = storedResult
            } else {
                self.continuation = continuation
                result = nil
            }
            lock.unlock()
            if let result {
                continuation.resume(with: result)
            }
        }

        @discardableResult
        func finish(_ result: Result<Void, Error>) -> Bool {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return false
            }
            self.result = result
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }

    /// Whether bun + the defuddle script are resolvable on this machine.
    private var resolved: (bun: URL, script: URL)? {
        DefuddleExtractionService.resolve()
    }

    /// Wait for a process to exit without blocking the cooperative thread
    /// pool. `Process.waitUntilExit()` is synchronous and parks the calling
    /// thread; under `swift test`'s shared pool that starves every other
    /// suite scheduled onto it (#732, same fix as `PdfExtractionServiceTests`).
    /// Use `terminationHandler` + `CheckedContinuation` instead — same
    /// semantics, non-blocking.
    ///
    /// The 30s timeout (issue #1051) is a safety net: if the `terminationHandler`
    /// completion is starved off the cooperative pool, a bare
    /// `withCheckedContinuation` hangs forever. The timeout produces a fast,
    /// diagnosed failure instead of an infinite hang.
    private func asyncWaitUntilExit(_ process: Process, timeout: Duration = .seconds(30)) async throws {
        let waiter = ProcessExitWaiter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        waiter.install(cont)
                        process.terminationHandler = { _ in
                            waiter.finish(.success(()))
                        }
                        if !process.isRunning {
                            waiter.finish(.success(()))
                        }
                    }
                } onCancel: {
                    if waiter.finish(.failure(CancellationError())), process.isRunning {
                        process.terminate()
                    }
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard waiter.finish(.failure(ProcessExitWaitError.timedOut)) else { return }
                if process.isRunning {
                    process.terminate()
                }
                throw ProcessExitWaitError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
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

    @Test func processRegistryTerminatesTracked() async throws {
        let reg = DefuddleExtractionService.ProcessRegistry()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["999"]
        try? p.run()
        #expect(p.isRunning)

        reg.track(p)
        reg.terminateAllForTesting()
        try await asyncWaitUntilExit(p)
        #expect(!p.isRunning)
        #expect(p.terminationStatus != 0)
    }
}
#endif
