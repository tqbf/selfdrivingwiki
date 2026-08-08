#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

/// Live WebKit checks for the session-owned browser-storage and file-navigation
/// boundaries. This suite is opt-in because it owns real AppKit windows.
@Suite(
    "Renderer session isolation",
    .disabled(
        if: ProcessInfo.processInfo.environment["WIKIFS_RENDERER_SESSION_ISOLATION_TESTS"] == nil,
        "Set WIKIFS_RENDERER_SESSION_ISOLATION_TESTS=1 to run hosted renderer isolation checks."
    ),
    .serialized,
    .timeLimit(.minutes(2))
)
@MainActor
struct RendererSessionIsolationTests {
    @Test("fresh sessions isolate cookies and local storage, and close discards them")
    func sessionsIsolateTransientBrowserStorage() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let token = UUID().uuidString
        let cookieName = "renderer_session_cookie"
        do {
            let provider = SessionIsolationResourceProvider()
            let permits = RendererWebViewSessionPermitPool(maximumPermits: 2)
            let first = WikiAppWebViewSession(
                entryURL: try Self.entryURL(),
                resourceProvider: provider,
                permits: permits
            )
            let second = WikiAppWebViewSession(
                entryURL: try Self.entryURL(),
                resourceProvider: provider,
                permits: permits
            )
            first.start()
            second.start()
            let host = try Self.host([first, second])
            defer {
                Self.tearDown(sessions: [first, second], host: host)
            }

            do {
                let firstWebView = try #require(first.webView)
                let secondWebView = try #require(second.webView)
                #expect(firstWebView.configuration.websiteDataStore !== secondWebView.configuration.websiteDataStore)
                try await Self.waitUntilReady(first, description: "first renderer session")
                try await Self.waitUntilReady(second, description: "second renderer session")

                let cookie = try #require(HTTPCookie(properties: [
                    .domain: "renderer-session-isolation.test",
                    .path: "/",
                    .name: cookieName,
                    .value: token,
                ]))
                let firstCookieStore = firstWebView.configuration.websiteDataStore.httpCookieStore
                let secondCookieStore = secondWebView.configuration.websiteDataStore.httpCookieStore
                await firstCookieStore.setCookie(cookie)
                try await Self.waitForCookie(cookie, in: firstCookieStore, description: "first renderer session cookie")
                let secondCookies = await Self.cookies(in: secondCookieStore)
                #expect(secondCookies?.contains(where: { $0.name == cookieName && $0.value == token }) == false)

                let firstLocalStorage = await evaluateJavaScriptWithTimeout(firstWebView, """
                (function() {
                    localStorage.setItem('renderer-session-local-storage', '\(token)');
                    return localStorage.getItem('renderer-session-local-storage');
                })()
                """)
                #expect(firstLocalStorage == token)

                let secondLocalStorage = await evaluateJavaScriptWithTimeout(secondWebView, """
                (function() {
                    return localStorage.getItem('renderer-session-local-storage') || 'empty';
                })()
                """)
                #expect(secondLocalStorage == "empty")
            }

            first.close()
            #expect(first.webView == nil)
        }

        do {
            let replacement = WikiAppWebViewSession(
                entryURL: try Self.entryURL(),
                resourceProvider: SessionIsolationResourceProvider(),
                permits: RendererWebViewSessionPermitPool(maximumPermits: 1)
            )
            replacement.start()
            let host = try Self.host([replacement])
            defer {
                Self.tearDown(sessions: [replacement], host: host)
            }

            do {
                let replacementWebView = try #require(replacement.webView)
                try await Self.waitUntilReady(replacement, description: "replacement renderer session")

                let replacementCookies = await Self.cookies(in: replacementWebView.configuration.websiteDataStore.httpCookieStore)
                #expect(replacementCookies?.contains(where: { $0.name == cookieName && $0.value == token }) == false)

                let replacementLocalStorage = await evaluateJavaScriptWithTimeout(replacementWebView, """
                (function() {
                    return localStorage.getItem('renderer-session-local-storage') || 'empty';
                })()
                """)
                #expect(replacementLocalStorage == "empty")
            }
        }
    }

    @Test("sessions reject file entries, navigation, and content exposure")
    func sessionsRejectFileNavigationAndContentExposure() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let marker = "renderer-session-file-marker-\(UUID().uuidString)"
        let fileURL = try Self.makeSecretFile(containing: marker)
        defer {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                Issue.record("Failed to remove renderer session isolation test file: \(error.localizedDescription)")
            }
        }

        let invalidEntrySession = WikiAppWebViewSession(
            entryURL: fileURL,
            resourceProvider: SessionIsolationResourceProvider()
        )
        invalidEntrySession.start()
        defer { invalidEntrySession.close() }
        #expect(invalidEntrySession.state == .failed(.init(
            sessionID: invalidEntrySession.state.sessionID,
            kind: .invalidEntryURL
        )))
        #expect(invalidEntrySession.webView == nil)

        let provider = SessionIsolationResourceProvider()
        let permits = RendererWebViewSessionPermitPool(maximumPermits: 1)
        let session = WikiAppWebViewSession(
            entryURL: try Self.entryURL(),
            resourceProvider: provider,
            permits: permits
        )
        session.start()
        let host = try Self.host([session])
        defer {
            Self.tearDown(sessions: [session], host: host)
        }

        let webView = try #require(session.webView)
        try await Self.waitUntilReady(session, description: "renderer session before file navigation")

        _ = await evaluateJavaScriptWithTimeout(webView, """
        (function() {
            location.href = '\(fileURL.absoluteString)';
        })()
        """)
        _ = await evaluateJavaScriptWithTimeout(webView, """
        (function() {
            window.rendererSessionFileProbe = 'pending';
            fetch('\(fileURL.absoluteString)')
                .then(function(response) { return response.text(); })
                .then(function(text) {
                    window.rendererSessionFileProbe = text.includes('\(marker)') ? 'exposed' : 'unexpected-content';
                })
                .catch(function() { window.rendererSessionFileProbe = 'rejected'; });
        })()
        """)
        let fileProbe = try await Self.waitForFileProbe(in: webView)
        #expect(fileProbe == "rejected")
        #expect(session.state == .ready(session.state.sessionID))
        #expect(webView.url?.scheme == RendererPackageScheme.name)
    }

    private static func entryURL() throws -> URL {
        guard let url = URL(string: "renderer-package://package/org.example.session-isolation/1.0.0/index.html") else {
            throw RendererSessionIsolationError.invalidEntryURL
        }
        return url
    }

    private static func host(_ sessions: [WikiAppWebViewSession]) throws -> NSWindow {
        let webViews = try sessions.map { try #require($0.webView) }
        let size = NSSize(width: 640, height: 480)
        let stack = NSStackView(views: webViews)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.frame = NSRect(origin: .zero, size: size)
        stack.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        prepareApplication()
        window.contentView = stack
        window.orderFront(nil)
        return window
    }

    private static func prepareApplication() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
    }

    private static func tearDown(sessions: [WikiAppWebViewSession], host: NSWindow) {
        sessions.forEach { $0.close() }
        host.orderOut(nil)
        host.contentView = nil
    }

    private static func waitUntilReady(
        _ session: WikiAppWebViewSession,
        description: String,
        timeout: Duration = .seconds(15)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while session.state != .ready(session.state.sessionID) {
            guard ContinuousClock.now < deadline else {
                throw RendererSessionIsolationError.timeout(description: description)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func waitForFileProbe(
        in webView: WKWebView,
        timeout: Duration = .seconds(15)
    ) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let probe = await evaluateJavaScriptWithTimeout(webView, "String(window.rendererSessionFileProbe || 'pending')")
            if let probe, probe != "pending" { return probe }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RendererSessionIsolationError.timeout(description: "file content probe")
    }

    private static func waitForCookie(
        _ expected: HTTPCookie,
        in store: WKHTTPCookieStore,
        description: String,
        timeout: Duration = .seconds(15)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let cookies = await cookies(in: store)
            if cookies?.contains(where: { $0.name == expected.name && $0.value == expected.value }) == true {
                return
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RendererSessionIsolationError.timeout(description: description)
    }

    private static func cookies(
        in store: WKHTTPCookieStore,
        timeout: Duration = .seconds(1)
    ) async -> [HTTPCookie]? {
        /// The lock makes the single-resume flag safe across the WebKit callback
        /// queue and the timeout task. Both paths call `fire` before resuming.
        // swiftlint:disable:next unchecked_sendable
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var didFire = false

            func fire(_ action: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard didFire == false else { return }
                didFire = true
                action()
            }
        }

        let once = Once()
        return await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                once.fire { continuation.resume(returning: cookies) }
            }
            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                once.fire { continuation.resume(returning: nil) }
            }
        }
    }

    private static func makeSecretFile(containing marker: String) throws -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("renderer-session-isolation-\(UUID().uuidString).txt")
        try Data(marker.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }
}

private enum RendererSessionIsolationError: LocalizedError {
    case timeout(description: String)
    case invalidEntryURL

    var errorDescription: String? {
        switch self {
        case let .timeout(description): "timed out waiting for \(description)"
        case .invalidEntryURL: "failed to construct renderer package entry URL"
        }
    }
}

private final class SessionIsolationResourceProvider: RendererPackageResourceProviding {
    private let entryDocument = Data("""
    <!doctype html>
    <html><head><meta charset="utf-8"><title>renderer-session-isolation</title></head>
    <body>renderer session isolation</body></html>
    """.utf8)

    func resource(for url: URL) throws -> RendererPackageResource {
        let request = try RendererPackageScheme.request(from: url)
        guard request.path.rawValue == "index.html" else {
            throw RendererPackageResourceError.undeclaredAsset
        }
        guard let mimeType = RendererMIMEType(rawValue: "text/html") else {
            preconditionFailure("text/html must be a valid renderer MIME type")
        }
        return RendererPackageResource(
            data: entryDocument,
            mimeType: mimeType,
            isEntryDocument: true
        )
    }
}

private extension WikiAppWebViewSessionState {
    var sessionID: RendererSessionID {
        switch self {
        case let .idle(value), let .loading(value), let .ready(value), let .closed(value): value
        case let .failed(failure): failure.sessionID
        }
    }
}
#endif
