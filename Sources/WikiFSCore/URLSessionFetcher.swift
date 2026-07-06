import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The production `URLResourceFetcher` — a thin wrapper over `URLSession`.
///
/// The app is un-sandboxed (no app-sandbox entitlement), so `URLSession` has full
/// network access with no entitlement and no macOS prompt. We:
/// - follow redirects (the default `URLSession` behavior) and report the FINAL URL,
///   so the filename derives from where we landed;
/// - send a desktop browser `User-Agent` so sites that 403 unknown agents serve us;
/// - use a bounded timeout so a dead host fails cleanly instead of hanging the sheet;
/// - translate a non-2xx status into `FetchError.httpStatus` and a transport error
///   into `FetchError.network`, both with user-readable messages.
public struct URLSessionFetcher: URLFetchService.URLResourceFetcher {

    /// A current desktop Safari UA — generic enough that content sites serve full
    /// HTML rather than a bot challenge.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: config)
    }

    public func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
        // Rewrite recognized file-share preview links (e.g. a Dropbox `www.dropbox.com`
        // share URL) to their direct-download host BEFORE the request — otherwise the
        // host serves a non-browser an HTML JS interstitial instead of the file. Pure +
        // conservative: an unrecognized URL passes through unchanged. See
        // `ShareLinkNormalizer`.
        let fetchURL = ShareLinkNormalizer.normalize(url)

        var request = URLRequest(url: fetchURL)
        request.httpMethod = "GET"
        // Be explicit about what we accept; some servers vary content by Accept.
        request.setValue(
            "text/html,application/xhtml+xml,application/pdf,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw URLFetchService.FetchError.network(
                "Couldn't reach that URL: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            // Non-HTTP (e.g. file://) — accept the bytes as-is.
            return URLFetchService.FetchResponse(
                data: data,
                contentType: response.mimeType,
                finalURL: response.url ?? fetchURL
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            throw URLFetchService.FetchError.httpStatus(http.statusCode)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
        return URLFetchService.FetchResponse(
            data: data,
            contentType: contentType,
            finalURL: http.url ?? fetchURL
        )
    }
}
