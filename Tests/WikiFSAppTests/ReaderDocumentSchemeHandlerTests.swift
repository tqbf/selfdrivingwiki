#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import WikiFS

/// Tests for `WikiReaderDocumentSchemeHandler` serving from the token-keyed
/// staging store. Encodes the operator requirement behind the blank-page fix:
/// a task for a token with no staged document fails with an error and serves
/// **no** bytes — there is no empty-document fallback in the serving path.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ReaderDocumentSchemeHandlerTests {

    /// A `WKURLSchemeTask` recorder capturing every callback the handler
    /// makes, so tests can assert exact serving/failure behavior.
    private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        private(set) var receivedResponse: URLResponse?
        private(set) var body = Data()
        private(set) var didFinishCalled = false
        private(set) var failures: [any Error] = []

        init(url: URL) {
            self.request = URLRequest(url: url)
            super.init()
        }

        func didReceive(_ response: URLResponse) { receivedResponse = response }
        func didReceive(_ data: Data) { body.append(data) }
        func didFinish() { didFinishCalled = true }
        func didFailWithError(_ error: any Error) { failures.append(error) }
    }

    private func start(_ url: URL) -> FakeSchemeTask {
        let task = FakeSchemeTask(url: url)
        WikiReaderDocumentSchemeHandler.shared.webView(WKWebView(frame: .zero), start: task)
        return task
    }

    /// AC.6 — the normal single-load flow is unchanged: the handler serves
    /// the exact staged bytes as `text/html` and finishes the task.
    @Test func servesStagedBytesForToken() {
        ReaderDocumentStaging.resetForTesting()
        let html = "<!doctype html><html><body>hello reader</body></html>"
        let token = UUID()
        ReaderDocumentStaging.stage(html, token: token)

        let task = start(WikiReaderDocumentOrigin.url(loadToken: token))

        #expect(task.failures.isEmpty)
        #expect(task.body == Data(html.utf8))
        #expect(task.didFinishCalled)
        #expect(task.receivedResponse?.mimeType == "text/html")
    }

    /// AC.2 — a task for an unregistered token fails exactly once with an
    /// error and never receives a response, bytes, or finish. No code path
    /// may serve a silent empty document.
    @Test func unknownTokenFailsTaskWithError() throws {
        ReaderDocumentStaging.resetForTesting()
        let token = UUID()  // never staged
        let url = WikiReaderDocumentOrigin.url(loadToken: token)

        let task = start(url)

        #expect(task.failures.count == 1)
        #expect(task.receivedResponse == nil)
        #expect(task.body.isEmpty)
        #expect(task.didFinishCalled == false)
        let failure = try #require(task.failures.first as? NSError)
        #expect(failure.domain == "WikiReaderDocument")
    }

    /// AC.3 — a served token re-serves identical bytes if the same navigation
    /// task is re-issued (idempotent consume / re-request resilience).
    @Test func sameTokenSecondTaskReservesIdempotently() {
        ReaderDocumentStaging.resetForTesting()
        let html = "<!doctype html><html><body>idempotent</body></html>"
        let token = UUID()
        ReaderDocumentStaging.stage(html, token: token)
        let url = WikiReaderDocumentOrigin.url(loadToken: token)

        let first = start(url)
        let second = start(url)

        #expect(first.failures.isEmpty && second.failures.isEmpty)
        #expect(first.body == Data(html.utf8))
        #expect(second.body == first.body)
        #expect(first.didFinishCalled && second.didFinishCalled)
    }
}
#endif
