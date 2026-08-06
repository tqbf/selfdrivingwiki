#if os(macOS)
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

@MainActor
struct WikiAppWebViewSessionTests {
    @Test("configuration factory creates fresh ephemeral components")
    func configurationFactoryCreatesFreshComponents() {
        let provider = StubResourceProvider()
        let factory = WikiAppWebViewConfigurationFactory()

        let first = factory.makeConfiguration(resourceProvider: provider)
        let second = factory.makeConfiguration(resourceProvider: provider)

        #expect(first.webViewConfiguration !== second.webViewConfiguration)
        #expect(first.dataStore !== second.dataStore)
        #expect(first.userContentController !== second.userContentController)
        #expect(first.schemeHandler !== second.schemeHandler)
    }

    @Test("timeout closes the session and releases its permit")
    func timeoutClosesSessionAndReleasesPermit() {
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

        #expect(session.state == .closed(sessionID))
        #expect(scheduler.handle.cancelled)
        #expect(permits.activePermitCount == 0)
        #expect(session.webView == nil)
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
