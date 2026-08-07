#if os(macOS)
import AppKit
import CryptoKit
import Security
import WebKit

/// pattern: Imperative Shell
///
/// A real-window WebKit harness for renderer security hosted tests. It is kept
/// deliberately permissive so it can serve as the prerequisite positive
/// control before future restrictive-session tests exercise the same receivers.
@MainActor
final class RendererHostedWebKitHarness {
    enum HarnessError: LocalizedError {
        case navigationFailed(String)
        case timeout(description: String)

        var errorDescription: String? {
            switch self {
            case let .navigationFailed(description): "hosted WebKit navigation failed: \(description)"
            case let .timeout(description): "timed out waiting for \(description)"
            }
        }
    }

    private enum Metrics {
        static let waitPollInterval: Duration = .milliseconds(10)
        static let navigationTimeout: Duration = .seconds(15)
        static let titleTimeout: Duration = .seconds(15)
        static let javascriptTimeout: Duration = .seconds(1)
        static let windowSize = NSSize(width: 640, height: 480)
    }

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    let webView: WKWebView

    var diagnostics: String {
        navigationRecorder.diagnostics
    }

    private let window: NSWindow
    private let navigationRecorder = NavigationRecorder()
    private var lease: HostedAppKitTestGate.Lease?
    private var isClosed = false

    private init(lease: HostedAppKitTestGate.Lease, configuration: WKWebViewConfiguration) {
        self.lease = lease
        _ = Self.app
        webView = WKWebView(frame: NSRect(origin: .zero, size: Metrics.windowSize), configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentView = webView
        webView.navigationDelegate = navigationRecorder
        window.orderFront(nil)
    }

    /// Creates the intentionally permissive configuration used only by the
    /// live-receiver health check. Production renderer sessions must not use it.
    static func permissive() async throws -> RendererHostedWebKitHarness {
        let lease = await HostedAppKitTestGate.shared.acquire()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return RendererHostedWebKitHarness(lease: lease, configuration: configuration)
    }

    func loadHTML(_ html: String, baseURL: URL = URL(string: "https://renderer-positive-control.invalid")!) async throws {
        guard !isClosed else { throw HarnessError.navigationFailed("harness is closed") }
        navigationRecorder.reset()
        webView.navigationDelegate = navigationRecorder
        webView.loadHTMLString(html, baseURL: baseURL)
        try await waitForNavigation()
    }

    func loadURL(_ url: URL) async throws {
        guard !isClosed else { throw HarnessError.navigationFailed("harness is closed") }
        navigationRecorder.reset()
        webView.navigationDelegate = navigationRecorder
        webView.load(URLRequest(url: url))
        try await waitForNavigation()
    }

    func waitForDocumentTitle(_ expectedTitle: String, timeout: Duration = Metrics.titleTimeout) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard !isClosed else { throw HarnessError.navigationFailed("harness is closed") }
            if webView.title == expectedTitle { return expectedTitle }
            try Task.checkCancellation()
            try await Task.sleep(for: Metrics.waitPollInterval)
        }
        throw HarnessError.timeout(description: "document title \(expectedTitle)")
    }

    /// Waits for a browser-side signal written by the hosted document. These
    /// signals let integration tests observe network completion without
    /// guessing how long WebKit needs to schedule a callback.
    func waitForJavaScriptString(
        _ javaScript: String,
        expectedValue: String,
        description: String,
        timeout: Duration = Metrics.titleTimeout
    ) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard !isClosed else { throw HarnessError.navigationFailed("harness is closed") }
            let value = await evaluateJavaScriptWithTimeout(webView, javaScript, timeout: Metrics.javascriptTimeout) ?? ""
            if value == expectedValue { return value }
            try Task.checkCancellation()
            try await Task.sleep(for: Metrics.waitPollInterval)
        }
        throw HarnessError.timeout(description: description)
    }

    func readJavaScriptString(_ javaScript: String) async -> String? {
        await evaluateJavaScriptWithTimeout(webView, javaScript, timeout: Metrics.javascriptTimeout)
    }

    /// Runs one browser action and verifies its acknowledgement. Tests use this
    /// to establish a happens-before edge between receiver readiness and an
    /// action that initiates network traffic.
    func executeJavaScript(
        _ javaScript: String,
        expectedValue: String,
        description: String,
        timeout: Duration = Metrics.javascriptTimeout
    ) async throws {
        guard !isClosed else { throw HarnessError.navigationFailed("harness is closed") }
        let value = await evaluateJavaScriptWithTimeout(webView, javaScript, timeout: timeout)
        guard value == expectedValue else { throw HarnessError.timeout(description: description) }
    }

    /// Explicit, idempotent test teardown. It releases both WebKit and the
    /// shared AppKit host gate after removing the delegate and stopping loads.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.orderOut(nil)
        window.contentView = nil
        let lease = lease
        self.lease = nil
        lease?.release()
    }

    private func waitForNavigation(timeout: Duration = Metrics.navigationTimeout) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let failure = navigationRecorder.failureDescription {
                throw HarnessError.navigationFailed(failure)
            }
            if navigationRecorder.didFinish { return }
            guard !isClosed else { throw HarnessError.navigationFailed("harness is closed") }
            try Task.checkCancellation()
            try await Task.sleep(for: Metrics.waitPollInterval)
        }
        throw HarnessError.timeout(description: "hosted WebKit navigation")
    }

    private final class NavigationRecorder: NSObject, WKNavigationDelegate {
        var didFinish = false
        var failureDescription: String?
        private(set) var serverTrustChallengeCount = 0
        private(set) var lastServerTrustChallenge = "none"

        var diagnostics: String {
            "navigationFinished=\(didFinish), navigationFailure=\(failureDescription ?? "none"), "
                + "serverTrustChallenges=\(serverTrustChallengeCount), "
                + "lastServerTrustChallenge=\(lastServerTrustChallenge)"
        }

        func reset() {
            didFinish = false
            failureDescription = nil
            serverTrustChallengeCount = 0
            lastServerTrustChallenge = "none"
        }

        // swiftlint:disable:next implicitly_unwrapped_optional
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinish = true
        }

        // swiftlint:disable:next implicitly_unwrapped_optional
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failureDescription = error.localizedDescription
        }

        // swiftlint:disable:next implicitly_unwrapped_optional
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failureDescription = error.localizedDescription
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            serverTrustChallengeCount += 1
            let protectionSpace = challenge.protectionSpace
            guard protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  protectionSpace.host == "127.0.0.1",
                  let trust = protectionSpace.serverTrust,
                  let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  certificateFingerprint(certificate) == Self.trustedLoopbackCertificateSHA1,
                  SecTrustEvaluateWithError(trust, nil)
            else {
                lastServerTrustChallenge = "rejected:\(protectionSpace.host):\(protectionSpace.authenticationMethod)"
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            lastServerTrustChallenge = "accepted:\(protectionSpace.host)"
            completionHandler(.performDefaultHandling, nil)
        }

        private func certificateFingerprint(_ certificate: SecCertificate) -> Data {
            Data(Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data))
        }

        private static let trustedLoopbackCertificateSHA1 = Data([
            0x7C, 0x0B, 0x00, 0x95, 0x4A, 0x87, 0x64, 0x87, 0x62, 0x0B,
            0xE7, 0xB2, 0xE2, 0xD0, 0xFD, 0xEC, 0x54, 0xB8, 0xEF, 0x08,
        ])

    }
}
#endif
