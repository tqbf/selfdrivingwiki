#if os(macOS)
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import WikiFS

/// Tests for the reader coordinator's identity-gated navigation terminal
/// events, the nil-load-seam failure path, and the retry trigger seam.
///
/// Hermetic by design: identities are MINTED directly as `NavigationIdentity`
/// values (`WKNavigation` has no public initializer), the load seam is
/// injected, and the internal terminal-event handlers are driven exactly as
/// the production `WKNavigation!` delegate adapters would. Only the thin
/// `WKNavigation` → identity conversion is excluded.
///
/// Per repo rules (#1051): no blocking waits — every wait races a bounded
/// `Task.sleep` poll, and deferred binding writes are awaited before
/// assertions.
///
/// Global `ReaderDocumentStaging` state is deliberately NOT reset here: this
/// suite `await`s, and another suite could run `resetForTesting()` in that
/// window. Every assertion is therefore session-scoped (`ownedTokens`,
/// captured identities, miss-tolerant `beginServing` checks) so concurrent
/// staging suites cannot flip an outcome. The staging/handler suites reset
/// the store, but they are synchronous `@MainActor` tests — they run
/// atomically and cannot interleave with these awaits mid-test.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ReaderNavigationFailureTests {

    private let documentHTML = "<!doctype html><html><body>nav-failure-test</body></html>"

    /// Mutable box standing in for SwiftUI `@State` under a test `Binding`.
    private final class ValueBox<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Load seam that records every request and mints a fresh identity per
    /// call — the success shape of the production `webView.load` wrapper.
    @MainActor
    private final class MintingLoader {
        private(set) var requestURLs: [URL] = []
        private(set) var identities: [NavigationIdentity] = []

        var seam: @MainActor (URLRequest) -> NavigationIdentity? {
            { [self] request in
                if let url = request.url { requestURLs.append(url) }
                let identity = NavigationIdentity.mint()
                identities.append(identity)
                return identity
            }
        }
    }

    /// Load seam that records requests but never starts a navigation — the
    /// production shape of `webView.load` returning `nil`.
    @MainActor
    private final class NilLoader {
        private(set) var requestURLs: [URL] = []

        var seam: @MainActor (URLRequest) -> NavigationIdentity? {
            { [self] request in
                if let url = request.url { requestURLs.append(url) }
                return nil
            }
        }
    }

    private func binding<T>(_ box: ValueBox<T>) -> Binding<T> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }

    /// Wires the coordinator's bindings exactly as `makeNSView` does and
    /// waits for the initial convert's dispatch through the injected seam.
    private func wireCoordinator(
        _ coordinator: WikiReaderRep.Coordinator,
        spinner: ValueBox<Bool>,
        failure: ValueBox<String?>
    ) async throws {
        coordinator.startLoad(
            markdown: "",
            documentIdentity: nil,
            isLoading: binding(spinner),
            loadFailure: binding(failure))
    }

    /// Bounded, non-blocking wait for a main-actor condition. The default
    /// budget is generous (the normal path resolves in milliseconds) so a
    /// fully loaded parallel test run cannot starve a deferred write past the
    /// deadline.
    @discardableResult
    private func waitFor(
        _ description: String,
        timeout: Duration = .seconds(15),
        _ condition: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(description)")
        return false
    }

    /// Yields to the main actor a few times so any deferred binding writes
    /// land before assertions.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// AC.4 — the CURRENT identity's failure, for both WebKit phases, sets
    /// the failure message and clears the spinner.
    @Test func provisionalAndCommittedDidFailSetFailureState() async throws {
        let loader = MintingLoader()
        let coordinator = WikiReaderRep.Coordinator(
            stagingSession: ReaderDocumentStagingSession(tokenProvider: { UUID() }, load: loader.seam))
        let spinner = ValueBox(true)
        let failure = ValueBox<String?>(nil)
        try await wireCoordinator(coordinator, spinner: spinner, failure: failure)
        try await waitFor("initial dispatch registered") { loader.identities.count >= 1 }

        // Two identities at the current generation, registered through the
        // injected loader seam (as the load-time recording does in production).
        let provisionalID = try #require(coordinator.dispatchStagedDocument(documentHTML))
        let committedID = try #require(coordinator.dispatchStagedDocument(documentHTML))
        #expect(provisionalID != committedID)

        coordinator.handleNavigationFailure(
            NSError(domain: "test", code: 1), identity: provisionalID, phase: "provisional")
        try await waitFor("provisional failure surfaced") { failure.value != nil }
        try await waitFor("spinner cleared") { spinner.value == false }

        failure.value = nil
        coordinator.handleNavigationFailure(
            NSError(domain: "test", code: 2), identity: committedID, phase: "committed")
        try await waitFor("committed failure surfaced") { failure.value != nil }
        #expect(spinner.value == false)
    }

    /// AC.4 — a mapped-stale identity's failure changes nothing (log only):
    /// no failure message, no spinner write, no page-loaded flip.
    @Test func staleNavigationFailureIgnored() async throws {
        let loader = MintingLoader()
        let coordinator = WikiReaderRep.Coordinator(
            stagingSession: ReaderDocumentStagingSession(tokenProvider: { UUID() }, load: loader.seam))
        let spinner = ValueBox(true)
        let failure = ValueBox<String?>(nil)
        try await wireCoordinator(coordinator, spinner: spinner, failure: failure)

        // Mapped at the current generation, then superseded by a fresh load.
        let staleID = try #require(coordinator.dispatchStagedDocument(documentHTML))
        coordinator.applyRetryTrigger(1)
        try await waitFor("superseding load dispatched") { loader.identities.count >= 2 }

        let failureBefore = failure.value
        let spinnerBefore = spinner.value
        let pageLoadedBefore = coordinator.pageLoaded

        coordinator.handleNavigationFailure(
            NSError(domain: "test", code: 3), identity: staleID, phase: "provisional")
        await settle()

        #expect(failure.value == failureBefore)
        #expect(spinner.value == spinnerBefore)
        #expect(coordinator.pageLoaded == pageLoadedBefore)
    }

    /// AC.4 — mapped-stale, unknown, and `nil` identities' finish events
    /// change nothing (log only): the page is not marked loaded and the
    /// spinner is not cleared by a navigation that is not the current load.
    @Test func staleDidFinishIgnored() async throws {
        let loader = MintingLoader()
        let coordinator = WikiReaderRep.Coordinator(
            stagingSession: ReaderDocumentStagingSession(tokenProvider: { UUID() }, load: loader.seam))
        let spinner = ValueBox(true)
        let failure = ValueBox<String?>(nil)
        try await wireCoordinator(coordinator, spinner: spinner, failure: failure)

        let staleID = try #require(coordinator.dispatchStagedDocument(documentHTML))
        coordinator.applyRetryTrigger(1)
        try await waitFor("superseding load dispatched") { loader.identities.count >= 2 }

        let webView = WKWebView(frame: .zero)
        coordinator.didFinishDocumentLoad(staleID, in: webView)
        coordinator.didFinishDocumentLoad(NavigationIdentity.mint(), in: webView)
        coordinator.didFinishDocumentLoad(nil, in: webView)
        await settle()

        #expect(coordinator.pageLoaded == false)
        #expect(spinner.value == true)
        #expect(failure.value == nil)
    }

    /// AC.4 — a `nil` load result is an immediate visible failure: the
    /// failure state is set (deferred write), the spinner is cleared, and the
    /// never-dispatched token is retired (staging misses afterwards).
    @Test func nilLoaderSurfacesFailure() async throws {
        let loader = NilLoader()
        let session = ReaderDocumentStagingSession(tokenProvider: { UUID() }, load: loader.seam)
        let coordinator = WikiReaderRep.Coordinator(stagingSession: session)
        let spinner = ValueBox(true)
        let failure = ValueBox<String?>(nil)
        try await wireCoordinator(coordinator, spinner: spinner, failure: failure)

        try await waitFor("load-initiation failure surfaced") { failure.value != nil }
        try await waitFor("spinner cleared") { spinner.value == false }

        let firstURL = try #require(loader.requestURLs.first)
        let token = try #require(WikiReaderDocumentOrigin.loadToken(from: firstURL))
        #expect(session.ownedTokens.isEmpty)
        #expect(ReaderDocumentStaging.beginServing(token: token) == nil)
    }

    /// AC.5 — `applyRetryTrigger` no-ops on an unchanged trigger; a changed
    /// trigger re-runs the load with the current props: fresh token staged,
    /// failure cleared (deferred write), generation advanced.
    @Test func retryAppliesTriggerAndRestages() async throws {
        let loader = MintingLoader()
        let session = ReaderDocumentStagingSession(tokenProvider: { UUID() }, load: loader.seam)
        let coordinator = WikiReaderRep.Coordinator(stagingSession: session)
        let spinner = ValueBox(true)
        let failure = ValueBox<String?>(nil)
        try await wireCoordinator(coordinator, spinner: spinner, failure: failure)
        try await waitFor("initial dispatch registered") { loader.identities.count >= 1 }

        // Current-generation failure first, so the retry visibly recovers.
        let failedID = loader.identities[0]
        coordinator.handleNavigationFailure(
            NSError(domain: "test", code: 6), identity: failedID, phase: "committed")
        try await waitFor("failure surfaced") { failure.value != nil }
        try await waitFor("spinner cleared") { spinner.value == false }

        // Unchanged trigger: a no-op.
        coordinator.applyRetryTrigger(0)
        await settle()
        #expect(loader.identities.count == 1)

        // Changed trigger: fresh token staged, failure cleared, spinner up.
        coordinator.applyRetryTrigger(1)
        try await waitFor("retry dispatched") { loader.identities.count >= 2 }
        try await waitFor("failure cleared by retry") { failure.value == nil }
        try await waitFor("spinner up again") { spinner.value == true }

        let ownedTokens = session.ownedTokens
        #expect(ownedTokens.count == 2)
        let firstURL = try #require(loader.requestURLs.first)
        let firstToken = try #require(WikiReaderDocumentOrigin.loadToken(from: firstURL))
        let lastURL = try #require(loader.requestURLs.last)
        let retryToken = try #require(WikiReaderDocumentOrigin.loadToken(from: lastURL))
        #expect(ownedTokens.contains(firstToken) && ownedTokens.contains(retryToken))
        #expect(firstToken != retryToken)

        // Generation advanced: the superseded load's identity can no longer
        // mutate state, while the retry's identity applies.
        coordinator.didFinishDocumentLoad(failedID, in: WKWebView(frame: .zero))
        await settle()
        #expect(coordinator.pageLoaded == false)

        let retryID = try #require(loader.identities.last)
        coordinator.didFinishDocumentLoad(retryID, in: WKWebView(frame: .zero))
        try await waitFor("retry identity marked the page loaded") { coordinator.pageLoaded == true }
    }

    /// AC.5 (separate teardown assertion) — `Coordinator.teardown()` invokes
    /// the session's `retireAll()`, and the retired tokens then miss.
    @Test func teardownRetiresAllOwnedTokens() async throws {
        let loader = MintingLoader()
        let session = ReaderDocumentStagingSession(tokenProvider: { UUID() }, load: loader.seam)
        let coordinator = WikiReaderRep.Coordinator(stagingSession: session)
        try await wireCoordinator(
            coordinator, spinner: ValueBox(true), failure: ValueBox<String?>(nil))
        try await waitFor("initial dispatch registered") { loader.identities.count >= 1 }

        let firstURL = try #require(loader.requestURLs.first)
        let token = try #require(WikiReaderDocumentOrigin.loadToken(from: firstURL))
        #expect(session.ownedTokens.isEmpty == false)
        #expect(session.retireAllCount == 0)

        coordinator.teardown()

        #expect(session.retireAllCount == 1)
        #expect(session.ownedTokens.isEmpty)
        #expect(ReaderDocumentStaging.beginServing(token: token) == nil)
    }
}
#endif
