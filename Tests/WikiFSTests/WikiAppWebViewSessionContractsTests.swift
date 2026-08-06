import Foundation
import Testing
@testable import WikiFSCore

struct WikiAppWebViewSessionContractsTests {
    @Test("policy exposes named conservative limits")
    func policyUsesNamedLimits() {
        #expect(WikiAppWebViewPolicy.maximumConcurrentSessions > 0)
        #expect(WikiAppWebViewPolicy.maximumSourceByteCount > 0)
        #expect(WikiAppWebViewPolicy.maximumDecodedByteCount >= WikiAppWebViewPolicy.maximumSourceByteCount)
        #expect(WikiAppWebViewPolicy.maximumBridgeMessageByteCount > 0)
        #expect(WikiAppWebViewPolicy.loadTimeout > .zero)
    }

    @Test("state machine ignores late transitions after close")
    func closeIsTerminalAndIdempotent() {
        let sessionID = RendererSessionID(rawValue: UUID())
        var machine = WikiAppWebViewSessionStateMachine(sessionID: sessionID)

        let didStart = machine.start()
        #expect(didStart)
        let didClose = machine.close()
        #expect(didClose)
        machine.markReady(sessionID: sessionID)
        machine.fail(sessionID: sessionID, kind: .loadTimedOut)

        #expect(machine.state == .closed(sessionID))
        let didCloseAgain = machine.close()
        #expect(didCloseAgain == false)
    }

    @Test("failure belongs only to the loading session")
    func failureRequiresCurrentLoadingSession() {
        let sessionID = RendererSessionID(rawValue: UUID())
        let otherID = RendererSessionID(rawValue: UUID())
        var machine = WikiAppWebViewSessionStateMachine(sessionID: sessionID)
        let didStart = machine.start()
        #expect(didStart)
        machine.fail(sessionID: otherID, kind: .loadTimedOut)
        #expect(machine.state == .loading(sessionID))
        machine.fail(sessionID: sessionID, kind: .loadTimedOut)
        #expect(machine.state == .failed(.init(sessionID: sessionID, kind: .loadTimedOut)))
    }
}
