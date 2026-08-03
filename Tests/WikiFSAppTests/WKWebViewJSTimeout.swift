#if os(macOS)
import Testing
import WebKit

/// Evaluate `js` against a live `WKWebView` and return the result coerced to a
/// `String`, or `nil` if the completion handler never fires within `timeout`.
///
/// `evaluateJavaScript`'s completion handler is delivered via a block on
/// Swift's cooperative thread pool. When `swift test` runs the full suite,
/// other suites in the SAME process can saturate that pool with synchronous
/// blocking calls (`DispatchSemaphore.wait()`, `Process.waitUntilExit()`, or
/// the same semaphore-style sync↔async bridges #925 removed from the Tantivy
/// menu path), leaving no thread free to deliver the reply. A raw
/// `withCheckedContinuation` then suspends forever —
/// a hang `.timeLimit` cannot interrupt, because cancelling the test's Task
/// does not resume an abandoned continuation. This is the exact failure mode
/// already named in `.github/workflows/ci.yml` / #664 / #732, which is why
/// `QuoteHighlightWebViewTests` and `YouTubeEmbedWebViewTests` are on CI's
/// skip list — but a bare local `swift test` still hits it (confirmed:
/// `hostedViewHighlightsQuoteFromPendingAnchor` passes in ~0.2s run alone via
/// `--filter`, but hangs indefinitely as part of the full suite).
///
/// Racing the continuation against a timeout turns that infinite hang into a
/// bounded, diagnosable failure instead. Both branches resume through `once`
/// so whichever fires second — the real completion arriving late, or the
/// timeout — safely no-ops rather than double-resuming.
@MainActor
func evaluateJavaScriptWithTimeout(
    _ webView: WKWebView,
    _ js: String,
    timeout: Duration = .seconds(15)
) async -> String? {
    final class Once: @unchecked Sendable {
        private var fired = false
        private let lock = NSLock()
        func fire(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !fired else { return }
            fired = true
            body()
        }
    }
    let once = Once()
    return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
        webView.evaluateJavaScript(js) { result, _ in
            once.fire { cont.resume(returning: result as? String) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            once.fire {
                let preview = js.prefix(80)
                Issue.record(
                    """
                    evaluateJavaScript timed out after \(timeout) — likely cooperative \
                    thread-pool starvation from a concurrently-running blocking suite \
                    (see #664/#732), not a bug in the JS itself. js=\(preview)
                    """
                )
                cont.resume(returning: nil)
            }
        }
    }
}
#endif
