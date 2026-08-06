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

    @Test("installed session timeout records its exact package reservation once")
    func installedTimeoutRecordsOnce() async throws {
        let scheduler = ManualTimeoutScheduler()
        let recorder = RecordedSessionFailures()
        let sessionID = RendererSessionID(rawValue: UUID())
        let session = try makeInstalledSession(
            sessionID: sessionID,
            timeoutScheduler: scheduler,
            recorder: recorder
        )

        session.start()
        scheduler.fire()
        scheduler.fire()
        session.close()

        let failures = try await recorder.waitingForCount(1)
        #expect(failures == [
            .init(
                failure: .init(sessionID: sessionID, kind: .loadTimedOut),
                reservation: try rendererPackageReservation()
            ),
        ])
    }

    @Test("installed entry navigation failure records its exact package reservation")
    func entryNavigationFailureRecordsOnce() async throws {
        let recorder = RecordedSessionFailures()
        let sessionID = RendererSessionID(rawValue: UUID())
        let session = try makeInstalledSession(sessionID: sessionID, recorder: recorder)
        session.start()
        let webView = try #require(session.webView)

        session.webView(webView, didFailProvisionalNavigation: nil, withError: NSError(domain: "test", code: 1))
        session.webView(webView, didFail: nil, withError: NSError(domain: "test", code: 2))

        let failures = try await recorder.waitingForCount(1)
        #expect(failures == [
            .init(
                failure: .init(sessionID: sessionID, kind: .navigationFailed),
                reservation: try rendererPackageReservation()
            ),
        ])
    }

    @Test("bridge bootstrap failure records its exact package reservation")
    func bridgeBootstrapFailureRecordsOnce() async throws {
        let recorder = RecordedSessionFailures()
        let sessionID = RendererSessionID(rawValue: UUID())
        let session = try makeInstalledSession(
            sessionID: sessionID,
            recorder: recorder,
            bridgeFactory: { _ in throw BridgeBootstrapError.failed }
        )

        session.start()

        let failures = try await recorder.waitingForCount(1)
        #expect(failures == [
            .init(
                failure: .init(sessionID: sessionID, kind: .bridgeBootstrapFailed),
                reservation: try rendererPackageReservation()
            ),
        ])
        #expect(session.webView == nil)
    }

    @Test("installed renderer process termination after ready records its exact package reservation")
    func processTerminationAfterReadyRecordsOnce() async throws {
        let recorder = RecordedSessionFailures()
        let sessionID = RendererSessionID(rawValue: UUID())
        let session = try makeInstalledSession(sessionID: sessionID, recorder: recorder)
        session.start()
        let webView = try #require(session.webView)
        session.webView(webView, didFinish: nil)

        session.webViewWebContentProcessDidTerminate(webView)
        session.webViewWebContentProcessDidTerminate(webView)
        session.close()

        let failures = try await recorder.waitingForCount(1)
        #expect(failures == [
            .init(
                failure: .init(sessionID: sessionID, kind: .webContentProcessTerminated),
                reservation: try rendererPackageReservation()
            ),
        ])
    }

    @Test("entry validation and sessions without an installed reservation do not record failures")
    func nonInstalledOrInvalidSessionsDoNotRecordFailures() async throws {
        let recorder = RecordedSessionFailures()
        let invalidSession = WikiAppWebViewSession(
            entryURL: try #require(URL(string: "https://example.invalid/index.html")),
            resourceProvider: StubResourceProvider(),
            installedPackage: try rendererPackageReservation(),
            failureRecorder: recorder.makeRecorder()
        )
        let unboundSession = WikiAppWebViewSession(
            entryURL: try #require(rendererEntryURL()),
            resourceProvider: StubResourceProvider(),
            failureRecorder: recorder.makeRecorder()
        )

        invalidSession.start()
        unboundSession.start()
        let webView = try #require(unboundSession.webView)
        unboundSession.webView(webView, didFail: nil, withError: NSError(domain: "test", code: 1))

        await Task.yield()
        let failures = await recorder.failures()
        #expect(failures.isEmpty)
    }

    @Test("reservation mismatch and host close do not record failures")
    func reservationMismatchAndHostCloseDoNotRecordFailures() async throws {
        let recorder = RecordedSessionFailures()
        let mismatch = RendererPackageReservation(
            packageID: try #require(RendererPackageID(rawValue: "org.example.session")),
            version: try #require(RendererPackageVersion(rawValue: "2.0.0"))
        )
        let mismatchedSession = WikiAppWebViewSession(
            entryURL: try #require(rendererEntryURL()),
            resourceProvider: StubResourceProvider(),
            installedPackage: mismatch,
            failureRecorder: recorder.makeRecorder()
        )
        let scheduler = ManualTimeoutScheduler()
        let closedSession = try makeInstalledSession(
            sessionID: .init(rawValue: UUID()),
            timeoutScheduler: scheduler,
            recorder: recorder
        )

        mismatchedSession.start()
        closedSession.start()
        closedSession.close()
        scheduler.fire()
        try await Task.sleep(for: .milliseconds(20))

        #expect(mismatchedSession.webView == nil)
        #expect(closedSession.state == .closed(closedSession.state.sessionID))
        let failures = await recorder.failures()
        #expect(failures.isEmpty)
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

private enum BridgeBootstrapError: Error {
    case failed
}

private struct RecordedSessionFailure: Equatable, Sendable {
    let failure: RendererSessionFailure
    let reservation: RendererPackageReservation
}

private actor RecordedSessionFailures {
    private enum Timing {
        static let maximumPolls = 50
        static let pollDelay: Duration = .milliseconds(10)
    }

    private var values: [RecordedSessionFailure] = []

    nonisolated func makeRecorder() -> RendererSessionFailureRecording {
        { [self] failure, reservation in
            await record(failure: failure, reservation: reservation)
        }
    }

    func record(failure: RendererSessionFailure, reservation: RendererPackageReservation) {
        values.append(.init(failure: failure, reservation: reservation))
    }

    func failures() -> [RecordedSessionFailure] { values }

    func waitingForCount(_ expectedCount: Int) async throws -> [RecordedSessionFailure] {
        for _ in 0 ..< Timing.maximumPolls {
            if values.count == expectedCount { return values }
            try await Task.sleep(for: Timing.pollDelay)
        }
        throw RecordedSessionFailuresError.timedOut(expectedCount: expectedCount)
    }
}

private enum RecordedSessionFailuresError: Error {
    case timedOut(expectedCount: Int)
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

private func rendererPackageReservation() throws -> RendererPackageReservation {
    .init(
        packageID: try #require(RendererPackageID(rawValue: "org.example.session")),
        version: try #require(RendererPackageVersion(rawValue: "1.0.0"))
    )
}

@MainActor
private func makeInstalledSession(
    sessionID: RendererSessionID,
    timeoutScheduler: any RendererWebViewLoadTimeoutScheduling = SystemRendererWebViewLoadTimeoutScheduler(),
    recorder: RecordedSessionFailures,
    bridgeFactory: ((RendererSessionID) throws -> RendererContentWorldBroker)? = nil
) throws -> WikiAppWebViewSession {
    WikiAppWebViewSession(
        sessionID: sessionID,
        entryURL: try #require(rendererEntryURL()),
        resourceProvider: StubResourceProvider(),
        timeoutScheduler: timeoutScheduler,
        installedPackage: try rendererPackageReservation(),
        failureRecorder: recorder.makeRecorder(),
        bridgeFactory: bridgeFactory
    )
}
#endif
