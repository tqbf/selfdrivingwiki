import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstracts `URLSession.data(for:)` for the extraction HTTP clients, so the
/// Anthropic and Docling Serve clients (and their tests) share one trivially
/// fakeable network seam. Mirrors `ZoteroClient.RequestFetcher`: the fetcher
/// takes a fully-formed `URLRequest` (each client attaches its own auth headers)
/// and returns the body bytes + HTTP status. The fetcher stays auth-agnostic.
public protocol HTTPRequestFetcher: Sendable {
    func fetch(_ request: URLRequest) async throws -> (data: Data, statusCode: Int)
}

/// The production `HTTPRequestFetcher` — a thin wrapper over an ephemeral
/// `URLSession`. The app is un-sandboxed, so `URLSession` has full network
/// access with no entitlement. The default timeout is generous (10 minutes) so a
/// large-PDF model extraction that takes a few minutes doesn't time out.
public struct URLSessionRequestFetcher: HTTPRequestFetcher {
    private let session: URLSession

    public init(timeout: TimeInterval = 600) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout * 2, timeout + 60)
        self.session = URLSession(configuration: config)
    }

    public func fetch(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            return (data, http.statusCode)
        }
        return (data, 200)
    }
}

/// A test `HTTPRequestFetcher` that returns a queued `(data, statusCode)` per
/// call (FIFO), so a unit test can script a sequence of responses. Throws when
/// the queue is exhausted so a test fails loudly rather than blocking. An actor
/// because `fetch` is async — Swift 6 won't allow `NSLock` across an `await`.
public actor FakeHTTPFetcher: HTTPRequestFetcher {
    private var queue: [(data: Data, statusCode: Int)]

    public init(responses: [(data: Data, statusCode: Int)]) {
        self.queue = responses
    }

    /// Convenience: a single canned body at HTTP 200.
    public init(body: String, statusCode: Int = 200) {
        self.queue = [(Data(body.utf8), statusCode)]
    }

    public init(body: Data, statusCode: Int = 200) {
        self.queue = [(body, statusCode)]
    }

    public func fetch(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        guard !queue.isEmpty else {
            throw FakeHTTPFetcherError.queueExhausted
        }
        return queue.removeFirst()
    }
}

public enum FakeHTTPFetcherError: Error {
    case queueExhausted
}
