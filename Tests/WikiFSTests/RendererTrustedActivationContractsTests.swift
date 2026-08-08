import Foundation
import Testing
@testable import WikiFSCore

struct RendererTrustedActivationContractsTests {
    @Test("external destinations normalize hosts and default ports")
    func normalizesExternalDestinations() throws {
        let normalizedURL = try #require(URL(string: "HTTPS://Example.COM:443/path?q=one#two"))
        let destination = try #require(RendererExternalDestination(url: normalizedURL))
        #expect(destination.url.absoluteString == "https://example.com/path?q=one#two")
        let credentialedURL = try #require(URL(string: "https://user:pass@example.com"))
        #expect(RendererExternalDestination(url: credentialedURL) == nil)
        let fileURL = try #require(URL(string: "file:///tmp/test"))
        #expect(RendererExternalDestination(url: fileURL) == nil)
    }

    @Test("a trusted activation redeems exactly once for its normalized destination")
    func redeemsOnce() throws {
        var authorizer = authorizer()
        let context = context()
        let destination = try makeDestination("https://EXAMPLE.com:443/docs")
        let nonce = authorizer.recordTrustedActivation(destination: destination, context: context)

        #expect(try authorizer.redeem(nonce: nonce, destination: try makeDestination("https://example.com/docs"), context: context) == destination)
        #expect(throws: RendererExternalActivationError.replayedNonce) {
            try authorizer.redeem(nonce: nonce, destination: destination, context: context)
        }
    }

    @Test("absent expired and substituted destinations are rejected")
    func rejectsAbsentExpiredAndSubstitutedDestinations() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        var authorizer = authorizer(clock: clock)
        let context = context()
        let destination = try makeDestination("https://example.com/one")
        #expect(throws: RendererExternalActivationError.absentNonce) {
            try authorizer.redeem(nonce: nil, destination: destination, context: context)
        }
        let expired = authorizer.recordTrustedActivation(destination: destination, context: context)
        clock.currentDate = clock.currentDate.addingTimeInterval(WikiAppWebViewPolicy.externalActivationNonceLifetime.timeInterval + 1)
        #expect(throws: RendererExternalActivationError.expiredNonce) {
            try authorizer.redeem(nonce: expired, destination: destination, context: context)
        }

        let substituted = authorizer.recordTrustedActivation(destination: destination, context: context)
        #expect(throws: RendererExternalActivationError.destinationMismatch) {
            try authorizer.redeem(nonce: substituted, destination: try makeDestination("https://example.com/redirected"), context: context)
        }
        #expect(throws: RendererExternalActivationError.destinationMismatch) {
            try authorizer.redeem(nonce: substituted, destination: destination, context: context)
        }
    }

    @Test("a nonce expires at its injected clock deadline")
    func expiresAtDeadline() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        var authorizer = authorizer(clock: clock)
        let context = context()
        let destination = try makeDestination("https://example.com/deadline")
        let nonce = authorizer.recordTrustedActivation(destination: destination, context: context)

        clock.currentDate = clock.currentDate.addingTimeInterval(
            WikiAppWebViewPolicy.externalActivationNonceLifetime.timeInterval
        )

        #expect(throws: RendererExternalActivationError.expiredNonce) {
            try authorizer.redeem(nonce: nonce, destination: destination, context: context)
        }
    }

    @Test("system nonces are URL-safe 256-bit opaque values")
    func systemNoncesAreOpaqueAndURLSafe() {
        let generator = SystemRendererActivationNonceGenerator()
        let nonces = Set((0..<8).map { _ in generator.makeNonce().rawValue })

        #expect(nonces.count == 8)
        #expect(nonces.allSatisfy { $0.count == 43 })
        #expect(nonces.allSatisfy { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } })
    }

    @Test("session frame window navigation failure and close invalidate pending nonces")
    func invalidatesAllHostLifecycleBoundaries() throws {
        let destination = try makeDestination("https://example.com")
        let base = context()

        var frameAuthorizer = authorizer()
        let frameNonce = frameAuthorizer.recordTrustedActivation(destination: destination, context: base)
        var childFrame = base
        childFrame = .init(sessionID: base.sessionID, windowID: base.windowID, frameID: UUID(), mainFrameID: base.mainFrameID, navigationID: base.navigationID)
        #expect(throws: RendererExternalActivationError.nonMainFrame) { try frameAuthorizer.redeem(nonce: frameNonce, destination: destination, context: childFrame) }

        var windowAuthorizer = authorizer()
        let windowNonce = windowAuthorizer.recordTrustedActivation(destination: destination, context: base)
        let wrongWindow = RendererExternalActivationContext(sessionID: base.sessionID, windowID: UUID(), frameID: base.frameID, mainFrameID: base.mainFrameID, navigationID: base.navigationID)
        #expect(throws: RendererExternalActivationError.wrongWindow) { try windowAuthorizer.redeem(nonce: windowNonce, destination: destination, context: wrongWindow) }

        var sessionAuthorizer = authorizer()
        let sessionNonce = sessionAuthorizer.recordTrustedActivation(destination: destination, context: base)
        let wrongSession = RendererExternalActivationContext(sessionID: .init(rawValue: UUID()), windowID: base.windowID, frameID: base.frameID, mainFrameID: base.mainFrameID, navigationID: base.navigationID)
        #expect(throws: RendererExternalActivationError.wrongSession) { try sessionAuthorizer.redeem(nonce: sessionNonce, destination: destination, context: wrongSession) }

        var navigationAuthorizer = authorizer()
        let navigationNonce = navigationAuthorizer.recordTrustedActivation(destination: destination, context: base)
        let wrongNavigation = RendererExternalActivationContext(sessionID: base.sessionID, windowID: base.windowID, frameID: base.frameID, mainFrameID: base.mainFrameID, navigationID: base.navigationID + 1)
        #expect(throws: RendererExternalActivationError.navigationInvalidated) {
            try navigationAuthorizer.redeem(nonce: navigationNonce, destination: destination, context: wrongNavigation)
        }
        #expect(throws: RendererExternalActivationError.navigationInvalidated) {
            try navigationAuthorizer.redeem(nonce: navigationNonce, destination: destination, context: base)
        }

        for reason in [RendererExternalActivationError.navigationInvalidated, .sessionFailed, .sessionClosed] {
            var invalidated = authorizer()
            let nonce = invalidated.recordTrustedActivation(destination: destination, context: base)
            invalidated.invalidateAll(reason: reason)
            #expect(throws: reason) { try invalidated.redeem(nonce: nonce, destination: destination, context: base) }
        }
    }

    @Test("bounded activation state evicts the oldest pending nonce without authorizing it")
    func boundsPendingActivationState() throws {
        var authorizer = authorizer()
        let context = context()
        let destination = try makeDestination("https://example.com/bounded")
        let first = authorizer.recordTrustedActivation(destination: destination, context: context)

        for _ in 1 ... WikiAppWebViewPolicy.maximumPendingExternalActivationNonces {
            _ = authorizer.recordTrustedActivation(destination: destination, context: context)
        }

        #expect(throws: RendererExternalActivationError.capacityEvictedNonce) {
            try authorizer.redeem(nonce: first, destination: destination, context: context)
        }
    }

    @Test("bounded invalidation history never restores authorization")
    func boundsInvalidatedActivationState() throws {
        var authorizer = authorizer()
        let context = context()
        let destination = try makeDestination("https://example.com/tombstone")
        let first = authorizer.recordTrustedActivation(destination: destination, context: context)
        #expect(try authorizer.redeem(nonce: first, destination: destination, context: context) == destination)

        for _ in 0 ..< WikiAppWebViewPolicy.maximumInvalidatedExternalActivationNonces {
            let nonce = authorizer.recordTrustedActivation(destination: destination, context: context)
            #expect(try authorizer.redeem(nonce: nonce, destination: destination, context: context) == destination)
        }

        #expect(throws: RendererExternalActivationError.absentNonce) {
            try authorizer.redeem(nonce: first, destination: destination, context: context)
        }
    }

    private func authorizer(clock: TestClock = TestClock(now: .now)) -> RendererExternalActivationAuthorizer {
        RendererExternalActivationAuthorizer(clock: clock, nonceGenerator: TestNonceGenerator())
    }

    private func context() -> RendererExternalActivationContext {
        let frame = UUID()
        return .init(sessionID: .init(rawValue: UUID()), windowID: UUID(), frameID: frame, mainFrameID: frame, navigationID: 1)
    }

    private func makeDestination(_ rawValue: String) throws -> RendererExternalDestination {
        let url = try #require(URL(string: rawValue))
        return try #require(RendererExternalDestination(url: url))
    }
}

private final class TestClock: RendererActivationClock {
    var currentDate: Date
    init(now: Date) { currentDate = now }

    func now() -> Date { currentDate }
}

private struct TestNonceGenerator: RendererActivationNonceGenerating {
    func makeNonce() -> RendererExternalActivationNonce { .init(rawValue: UUID().uuidString) }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
