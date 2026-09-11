#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

/// Tests for `ReaderDocumentStaging` — the token-keyed staging store that
/// replaced the single process-wide pending slot. The single slot let two
/// overlapping reader loads cross-consume each other's HTML (one webview
/// rendered the other's document; the loser got a silent empty page). These
/// tests pin the deterministic interleavings that used to race, plus the
/// two-tier retention contract: pending entries are never evicted, served
/// entries are bounded by an oldest-served LRU cap, and there is no
/// forget-on-restage.
///
/// These tests are synchronous `@MainActor` functions, so each runs
/// atomically on the main actor: `resetForTesting()` at the start cannot
/// interleave with another suite mid-test, which is what makes the
/// served-cap determinism safe despite the process-global store.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ReaderDocumentStagingTests {

    private func html(_ name: String) -> String {
        "<!doctype html><html><body>\(name)</body></html>"
    }

    /// AC.1 — the regression test for the reported bug: two documents staged
    /// before either is consumed must each resolve to their own bytes.
    /// Fails against the old single-slot store (stage B overwrote A, so
    /// `beginServing(aToken)` returned B's bytes or missed).
    @Test func interleavedStagingConsumesOwnDocument() {
        ReaderDocumentStaging.resetForTesting()
        let aToken = UUID()
        let bToken = UUID()
        let htmlA = html("A")
        let htmlB = html("B")

        ReaderDocumentStaging.stage(htmlA, token: aToken)
        ReaderDocumentStaging.stage(htmlB, token: bToken)

        #expect(ReaderDocumentStaging.beginServing(token: aToken) == Data(htmlA.utf8))
        #expect(ReaderDocumentStaging.beginServing(token: bToken) == Data(htmlB.utf8))
    }

    /// AC.6 — the no-forget-on-restage contract: staging a newer document
    /// must not retire a prior token. A superseded navigation's scheme task
    /// may dispatch late; forget-on-restage would starve it back into the
    /// silent-blank failure mode.
    @Test func supersededTokenStillServes() {
        ReaderDocumentStaging.resetForTesting()
        let aToken = UUID()
        let bToken = UUID()
        let htmlA = html("A")
        let htmlB = html("B")

        ReaderDocumentStaging.stage(htmlA, token: aToken)
        // No retire between: the newer load replaces the older one in flight.
        ReaderDocumentStaging.stage(htmlB, token: bToken)

        #expect(ReaderDocumentStaging.beginServing(token: aToken) == Data(htmlA.utf8))
        #expect(ReaderDocumentStaging.beginServing(token: bToken) == Data(htmlB.utf8))
    }

    /// AC.6 — the teardown contract: `retireAll()` on the owning session
    /// makes `beginServing` miss for every owned token, and nothing else.
    @Test func retireAllRemovesOwnedTokens() {
        ReaderDocumentStaging.resetForTesting()
        var nextToken = 0
        let tokens = [UUID(), UUID()]
        let session = ReaderDocumentStagingSession(
            tokenProvider: {
                defer { nextToken += 1 }
                return tokens[nextToken]
            },
            load: { _ in NavigationIdentity.mint() })

        let stagedA = session.stageAndLoad(html: html("A"))
        let stagedB = session.stageAndLoad(html: html("B"))
        #expect(session.ownedTokens.count == 2)

        session.retireAll()

        #expect(session.ownedTokens.isEmpty)
        #expect(session.retireAllCount == 1)
        #expect(ReaderDocumentStaging.beginServing(token: stagedA.token) == nil)
        #expect(ReaderDocumentStaging.beginServing(token: stagedB.token) == nil)
    }

    /// AC.6 — pending entries are never evicted, even beyond the served LRU
    /// cap: a not-yet-dispatched navigation cannot be starved. Serving each
    /// in turn must return every document's exact bytes.
    @Test func pendingLoadsBeyondCapRemainServiceable() {
        ReaderDocumentStaging.resetForTesting()
        let count = ReaderDocumentStaging.servedCapacity + 4
        var tokens: [UUID] = []
        var bodies: [Data] = []
        for index in 0..<count {
            let body = Data(html("doc-\(index)").utf8)
            let token = UUID()
            ReaderDocumentStaging.stage(html("doc-\(index)"), token: token)
            tokens.append(token)
            bodies.append(body)
        }

        for (token, body) in zip(tokens, bodies) {
            #expect(ReaderDocumentStaging.beginServing(token: token) == body)
        }
    }

    /// AC.6 — served entries are bounded by an oldest-served LRU cap, driven
    /// through `beginServing` itself (the real pending→served transition, not
    /// a test-only mutation). The oldest served entry's re-serve misses after
    /// eviction; pending entries are untouched; newer served entries survive.
    @Test func servedLruCapEvictsOldestServed() {
        ReaderDocumentStaging.resetForTesting()
        let count = ReaderDocumentStaging.servedCapacity + 4
        var tokens: [UUID] = []
        var bodies: [Data] = []
        for index in 0..<count {
            let body = html("doc-\(index)")
            let token = UUID()
            ReaderDocumentStaging.stage(body, token: token)
            tokens.append(token)
            bodies.append(Data(body.utf8))
        }

        // Serve capacity + 1 entries: the oldest served (tokens[0]) is evicted.
        for token in tokens[...(ReaderDocumentStaging.servedCapacity)] {
            #expect(ReaderDocumentStaging.beginServing(token: token) != nil)
        }

        // The oldest served entry is gone; its re-serve misses loudly.
        #expect(ReaderDocumentStaging.beginServing(token: tokens[0]) == nil)
        // The remaining served entries still re-serve identical bytes.
        for index in 1...ReaderDocumentStaging.servedCapacity {
            #expect(ReaderDocumentStaging.beginServing(token: tokens[index]) == bodies[index])
        }
        // Entries never served are still pending and untouched by eviction.
        for index in (ReaderDocumentStaging.servedCapacity + 1)..<count {
            #expect(ReaderDocumentStaging.beginServing(token: tokens[index]) == bodies[index])
        }
    }
}
#endif
