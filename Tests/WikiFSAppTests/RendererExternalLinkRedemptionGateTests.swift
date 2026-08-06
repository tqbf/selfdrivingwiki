#if os(macOS)
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

@MainActor
struct RendererExternalLinkRedemptionGateTests {
    @Test("only successful redemption reaches the external opener")
    func opensOnlySuccessfullyRedeemedDestination() throws {
        let opener = RecordingExternalURLOpener()
        let gate = RendererExternalLinkRedemptionGate(opener: opener, nonceGenerator: FixedNonceGenerator())
        let context = activationContext()
        let destination = try #require(RendererExternalDestination(url: URL(string: "https://example.com/docs")!))

        #expect(throws: RendererExternalActivationError.absentNonce) {
            try gate.redeem(nonce: nil, destination: destination, context: context)
        }
        #expect(opener.destinations.isEmpty)

        let nonce = gate.recordTrustedActivation(destination: destination, context: context)
        let redirected = try #require(RendererExternalDestination(url: URL(string: "https://example.com/redirect")!))
        #expect(throws: RendererExternalActivationError.destinationMismatch) {
            try gate.redeem(
                nonce: nonce,
                destination: redirected,
                context: context
            )
        }
        #expect(opener.destinations.isEmpty)

        let validNonce = gate.recordTrustedActivation(destination: destination, context: context)
        #expect(try gate.redeem(nonce: validNonce, destination: destination, context: context) == destination.url)
        #expect(opener.destinations == [destination.url])
        #expect(throws: RendererExternalActivationError.replayedNonce) {
            try gate.redeem(nonce: validNonce, destination: destination, context: context)
        }
        #expect(opener.destinations == [destination.url])
    }

    @Test("every rejected redemption leaves the external opener untouched")
    func rejectedRedemptionsNeverReachTheExternalOpener() throws {
        let context = activationContext()
        let destination = try externalDestination("https://example.com/docs")
        let substituted = try externalDestination("https://example.com/redirect")

        let absentOpener = RecordingExternalURLOpener()
        let absentGate = RendererExternalLinkRedemptionGate(opener: absentOpener, nonceGenerator: FixedNonceGenerator())
        #expect(throws: RendererExternalActivationError.absentNonce) {
            try absentGate.redeem(nonce: nil, destination: destination, context: context)
        }
        #expect(absentOpener.destinations.isEmpty)

        let substitutedOpener = RecordingExternalURLOpener()
        let substitutedGate = RendererExternalLinkRedemptionGate(opener: substitutedOpener, nonceGenerator: FixedNonceGenerator())
        let substitutedNonce = substitutedGate.recordTrustedActivation(destination: destination, context: context)
        #expect(throws: RendererExternalActivationError.destinationMismatch) {
            try substitutedGate.redeem(nonce: substitutedNonce, destination: substituted, context: context)
        }
        #expect(substitutedOpener.destinations.isEmpty)

        let contextOpener = RecordingExternalURLOpener()
        let contextGate = RendererExternalLinkRedemptionGate(opener: contextOpener, nonceGenerator: FixedNonceGenerator())
        let contextNonce = contextGate.recordTrustedActivation(destination: destination, context: context)
        let wrongWindow = RendererExternalActivationContext(sessionID: context.sessionID, windowID: UUID(), frameID: context.frameID, mainFrameID: context.mainFrameID, navigationID: context.navigationID)
        #expect(throws: RendererExternalActivationError.wrongWindow) {
            try contextGate.redeem(nonce: contextNonce, destination: destination, context: wrongWindow)
        }
        #expect(contextOpener.destinations.isEmpty)

        let sessionOpener = RecordingExternalURLOpener()
        let sessionGate = RendererExternalLinkRedemptionGate(opener: sessionOpener, nonceGenerator: FixedNonceGenerator())
        let sessionNonce = sessionGate.recordTrustedActivation(destination: destination, context: context)
        let wrongSession = RendererExternalActivationContext(sessionID: .init(rawValue: UUID()), windowID: context.windowID, frameID: context.frameID, mainFrameID: context.mainFrameID, navigationID: context.navigationID)
        #expect(throws: RendererExternalActivationError.wrongSession) {
            try sessionGate.redeem(nonce: sessionNonce, destination: destination, context: wrongSession)
        }
        #expect(sessionOpener.destinations.isEmpty)

        let frameOpener = RecordingExternalURLOpener()
        let frameGate = RendererExternalLinkRedemptionGate(opener: frameOpener, nonceGenerator: FixedNonceGenerator())
        let frameNonce = frameGate.recordTrustedActivation(destination: destination, context: context)
        let childFrame = RendererExternalActivationContext(sessionID: context.sessionID, windowID: context.windowID, frameID: UUID(), mainFrameID: context.mainFrameID, navigationID: context.navigationID)
        #expect(throws: RendererExternalActivationError.nonMainFrame) {
            try frameGate.redeem(nonce: frameNonce, destination: destination, context: childFrame)
        }
        #expect(frameOpener.destinations.isEmpty)

        let navigationOpener = RecordingExternalURLOpener()
        let navigationGate = RendererExternalLinkRedemptionGate(opener: navigationOpener, nonceGenerator: FixedNonceGenerator())
        let navigationNonce = navigationGate.recordTrustedActivation(destination: destination, context: context)
        let wrongNavigation = RendererExternalActivationContext(sessionID: context.sessionID, windowID: context.windowID, frameID: context.frameID, mainFrameID: context.mainFrameID, navigationID: context.navigationID + 1)
        #expect(throws: RendererExternalActivationError.navigationInvalidated) {
            try navigationGate.redeem(nonce: navigationNonce, destination: destination, context: wrongNavigation)
        }
        #expect(navigationOpener.destinations.isEmpty)

        let expiryClock = TestClock(now: Date(timeIntervalSince1970: 0))
        let expiredOpener = RecordingExternalURLOpener()
        let expiredGate = RendererExternalLinkRedemptionGate(opener: expiredOpener, clock: expiryClock, nonceGenerator: FixedNonceGenerator())
        let expiredNonce = expiredGate.recordTrustedActivation(destination: destination, context: context)
        expiryClock.currentDate = expiryClock.currentDate.addingTimeInterval(WikiAppWebViewPolicy.externalActivationNonceLifetime.timeInterval)
        #expect(throws: RendererExternalActivationError.expiredNonce) {
            try expiredGate.redeem(nonce: expiredNonce, destination: destination, context: context)
        }
        #expect(expiredOpener.destinations.isEmpty)

        let invalidatedOpener = RecordingExternalURLOpener()
        let invalidatedGate = RendererExternalLinkRedemptionGate(opener: invalidatedOpener, nonceGenerator: FixedNonceGenerator())
        let invalidatedNonce = invalidatedGate.recordTrustedActivation(destination: destination, context: context)
        invalidatedGate.invalidateAll(reason: .sessionClosed)
        #expect(throws: RendererExternalActivationError.sessionClosed) {
            try invalidatedGate.redeem(nonce: invalidatedNonce, destination: destination, context: context)
        }
        #expect(invalidatedOpener.destinations.isEmpty)
    }

    @Test("the isolated observer redeems directly without publishing a nonce to page state")
    func observationScriptKeepsNonceOutOfPageVisibleWindowState() {
        let contentWorld = WKContentWorld.world(name: "RendererExternalLinkRedemptionGateTests")
        let source = RendererTrustedActivationScriptMessageHandler.observationScript(contentWorld: contentWorld).source

        #expect(source.contains("window.postMessage") == false)
        #expect(source.contains("rendererExternalActivation") == false)
        #expect(source.contains("renderer-external-link") == true)
    }

    private func activationContext() -> RendererExternalActivationContext {
        let frame = UUID()
        return .init(sessionID: .init(rawValue: UUID()), windowID: UUID(), frameID: frame, mainFrameID: frame, navigationID: 1)
    }

    private func externalDestination(_ rawValue: String) throws -> RendererExternalDestination {
        let url = try #require(URL(string: rawValue))
        return try #require(RendererExternalDestination(url: url))
    }
}

@MainActor
private final class RecordingExternalURLOpener: RendererExternalURLOpening {
    private(set) var destinations: [URL] = []
    func open(_ destination: URL) { destinations.append(destination) }
}

private struct FixedNonceGenerator: RendererActivationNonceGenerating {
    func makeNonce() -> RendererExternalActivationNonce { .init(rawValue: UUID().uuidString) }
}

private final class TestClock: RendererActivationClock {
    var currentDate: Date

    init(now: Date) { currentDate = now }

    func now() -> Date { currentDate }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
#endif
