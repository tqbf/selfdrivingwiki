#if os(macOS)
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

@Suite(.serialized)
@MainActor
struct WikiAppWebViewSessionTests {
    @Test("configuration factory creates fresh ephemeral components")
    func configurationFactoryCreatesFreshComponents() {
        let provider = StubResourceProvider()
        let factory = WikiAppWebViewConfigurationFactory()

        let first = factory.makeConfiguration(sessionID: RendererSessionID(rawValue: UUID()), resourceProvider: provider)
        let second = factory.makeConfiguration(sessionID: RendererSessionID(rawValue: UUID()), resourceProvider: provider)

        #expect(first.webViewConfiguration !== second.webViewConfiguration)
        #expect(first.dataStore !== second.dataStore)
        #expect(first.userContentController !== second.userContentController)
        #expect(first.contentWorld !== second.contentWorld)
        #expect(first.contentWorld.name != second.contentWorld.name)
        #expect(first.schemeHandler !== second.schemeHandler)
    }

    @Test("timeout records a failure and releases its resources")
    func timeoutFailureIsObservableAndReleasesResources() {
        let scheduler = ManualTimeoutScheduler()
        let permits = RendererWebViewSessionPermitPool(maximumPermits: 1)
        let sessionID = RendererSessionID(rawValue: UUID())
        guard let entryURL = rendererEntryURL() else {
            Issue.record("Test renderer package URL must be valid.")
            return
        }
        let session = WikiAppWebViewSession(
            sessionID: sessionID,
            entryURL: entryURL,
            resourceProvider: StubResourceProvider(),
            timeoutScheduler: scheduler,
            permits: permits
        )

        session.start()
        scheduler.fire()

        #expect(session.state == .failed(.init(sessionID: sessionID, kind: .loadTimedOut)))
        #expect(scheduler.handle.cancelled)
        #expect(permits.activePermitCount == 0)
        #expect(session.webView == nil)
        session.close()
        #expect(session.state == .closed(sessionID))
    }

    @Test("invalid entry URL fails without creating a WebView")
    func invalidEntryURLFailsClosed() {
        let sessionID = RendererSessionID(rawValue: UUID())
        guard let invalidURL = URL(string: "https://example.invalid/index.html") else {
            Issue.record("Test URL must be valid.")
            return
        }
        let session = WikiAppWebViewSession(
            sessionID: sessionID,
            entryURL: invalidURL,
            resourceProvider: StubResourceProvider()
        )

        session.start()

        #expect(session.state == .failed(.init(sessionID: sessionID, kind: .invalidEntryURL)))
        #expect(session.webView == nil)
    }

    @Test("close cancels timeout and releases its permit")
    func closeIsTerminalAndReleasesPermit() {
        let scheduler = ManualTimeoutScheduler()
        let permits = RendererWebViewSessionPermitPool(maximumPermits: 1)
        let sessionID = RendererSessionID(rawValue: UUID())
        guard let entryURL = rendererEntryURL() else {
            Issue.record("Test renderer package URL must be valid.")
            return
        }
        let session = WikiAppWebViewSession(
            sessionID: sessionID,
            entryURL: entryURL,
            resourceProvider: StubResourceProvider(),
            timeoutScheduler: scheduler,
            permits: permits
        )

        session.start()
        session.close()
        session.close()

        #expect(session.state == .closed(sessionID))
        #expect(scheduler.handle.cancelled)
        #expect(permits.activePermitCount == 0)
        #expect(session.webView == nil)
    }

    @Test("default sessions share the global capacity limit")
    func defaultSessionsShareTheGlobalCapacityLimit() {
        guard let entryURL = rendererEntryURL() else {
            Issue.record("Test renderer package URL must be valid.")
            return
        }
        let sessions = (0...WikiAppWebViewPolicy.maximumConcurrentSessions).map { _ in
            WikiAppWebViewSession(entryURL: entryURL, resourceProvider: StubResourceProvider())
        }
        defer { sessions.forEach { $0.close() } }

        sessions.forEach { $0.start() }

        #expect(WikiAppWebViewPolicy.maximumConcurrentSessions > 0)
        for session in sessions.prefix(WikiAppWebViewPolicy.maximumConcurrentSessions) {
            #expect(session.state == .loading(session.state.sessionID))
            #expect(session.webView != nil)
        }
        let rejectedSession = sessions[WikiAppWebViewPolicy.maximumConcurrentSessions]
        #expect(rejectedSession.state == .failed(.init(
            sessionID: rejectedSession.state.sessionID,
            kind: .concurrencyLimitReached
        )))
    }

    @Test("a failed session releases references and capacity")
    func failedSessionReleasesReferencesAndCapacity() throws {
        let scheduler = ManualTimeoutScheduler()
        let permits = RendererWebViewSessionPermitPool(maximumPermits: 1)
        let sessionID = RendererSessionID(rawValue: UUID())
        let entryURL = try #require(rendererEntryURL())
        let session = WikiAppWebViewSession(
            sessionID: sessionID,
            entryURL: entryURL,
            resourceProvider: StubResourceProvider(),
            timeoutScheduler: scheduler,
            permits: permits
        )
        session.start()
        let webView = try #require(session.webView)

        session.webView(webView, didFail: nil, withError: NSError(domain: "test", code: 1))

        #expect(session.state == .failed(.init(sessionID: sessionID, kind: .navigationFailed)))
        #expect(session.webView == nil)
        #expect(permits.activePermitCount == 0)
    }

    @Test("a stale timeout does not change a ready session")
    func staleTimeoutDoesNotChangeReadySession() throws {
        let scheduler = ManualTimeoutScheduler()
        let permits = RendererWebViewSessionPermitPool(maximumPermits: 1)
        let sessionID = RendererSessionID(rawValue: UUID())
        let entryURL = try #require(rendererEntryURL())
        let session = WikiAppWebViewSession(
            sessionID: sessionID,
            entryURL: entryURL,
            resourceProvider: StubResourceProvider(),
            timeoutScheduler: scheduler,
            permits: permits
        )
        defer { session.close() }
        session.start()
        let webView = try #require(session.webView)

        session.webView(webView, didFinish: nil)
        scheduler.fire()

        #expect(session.state == .ready(sessionID))
        #expect(permits.activePermitCount == 1)
    }

    @Test("discarded loading sessions release their permit")
    func discardedLoadingSessionReleasesPermit() throws {
        let scheduler = ManualTimeoutScheduler()
        let permits = RendererWebViewSessionPermitPool(maximumPermits: 1)
        let entryURL = try #require(rendererEntryURL())
        weak var releasedSession: WikiAppWebViewSession?
        var session: WikiAppWebViewSession? = WikiAppWebViewSession(
            entryURL: entryURL,
            resourceProvider: StubResourceProvider(),
            timeoutScheduler: scheduler,
            permits: permits
        )
        session?.start()
        releasedSession = session
        session = nil

        #expect(releasedSession == nil)
        #expect(permits.activePermitCount == 0)
    }

    @Test("discarded failed sessions retain no WebView capacity")
    func discardedFailedSessionReleasesCapacity() throws {
        let scheduler = ManualTimeoutScheduler()
        let permits = RendererWebViewSessionPermitPool(maximumPermits: 1)
        let entryURL = try #require(rendererEntryURL())
        weak var releasedSession: WikiAppWebViewSession?
        var session: WikiAppWebViewSession? = WikiAppWebViewSession(
            entryURL: entryURL,
            resourceProvider: StubResourceProvider(),
            timeoutScheduler: scheduler,
            permits: permits
        )
        session?.start()
        let webView = try #require(session?.webView)
        session?.webView(webView, didFail: nil, withError: NSError(domain: "test", code: 1))
        releasedSession = session
        session = nil

        #expect(releasedSession == nil)
        #expect(permits.activePermitCount == 0)
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

private final class StubResourceProvider: RendererPackageResourceProviding {
    func resource(for url: URL) throws -> RendererPackageResource {
        throw RendererPackageResourceError.undeclaredAsset
    }
}

@MainActor
private final class ManualTimeoutScheduler: RendererWebViewLoadTimeoutScheduling {
    let handle = Handle()

    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> any RendererWebViewCancellable {
        handle.operation = operation
        return handle
    }

    func fire() { handle.operation?() }

    @MainActor
    final class Handle: RendererWebViewCancellable {
        var cancelled = false
        var operation: (@MainActor @Sendable () -> Void)?
        func cancel() { cancelled = true }
    }
}

private func rendererEntryURL() -> URL? {
    URL(string: "renderer-package://package/org.example.session/1.0.0/index.html")
}
#endif
