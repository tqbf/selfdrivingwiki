import Foundation
import Testing
@testable import WikiFSCore

struct ChatDiagnosticTypesTests {
    @Test func envelopeRoundTripsWithTypedCorrelationAndRedaction() throws {
        let event = ChatDiagnosticEventEnvelope(
            process: .init(source: .daemon, instanceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            sequence: .init(7),
            timestamp: Date(timeIntervalSince1970: 100),
            stage: .providerTranslation,
            payload: .init(correlation: .init(
                chat: .init(rawValue: "chat-1"),
                generation: .init(rawValue: "generation-1"),
                updateSequence: .init(3),
                turn: .init(rawValue: "turn-1"),
                durableItem: .init(rawValue: "message-1"),
                displayRow: .init(rawValue: "message-1"),
                tool: .init(rawValue: "tool-1"),
                cursor: .init(rawValue: "4"),
                rendererRevision: .init(2),
                eventKind: .init(rawValue: "assistant"),
                content: .init(digest: "deadbeef", length: 12)
            )),
            outcome: .accepted
        )
        let decoded = try JSONDecoder().decode(ChatDiagnosticEventEnvelope.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
        #expect(decoded.redaction == .identifiersAndKeyedFingerprintOnly)
    }

    @Test func keyedFingerprintsCorrelateOnlyInsideOneTraceKey() {
        let first = ChatDiagnosticFingerprintKey()
        let second = ChatDiagnosticFingerprintKey()
        let text = "sensitive message text"
        let a = first.fingerprint(for: text)
        #expect(a == first.fingerprint(for: text))
        #expect(a != second.fingerprint(for: text))
        #expect(a.length == text.utf8.count)
        #expect(a.digest != text)
    }

    @Test func versionValidationRejectsUnsupportedRequestAndSnapshot() {
        #expect(throws: ChatDiagnosticVersionError.unsupported(99)) {
            try ChatDiagnosticSnapshotRequest(version: 99).validatingVersion()
        }
        #expect(throws: ChatDiagnosticVersionError.unsupported(99)) {
            try ChatDiagnosticSnapshotEnvelope(
                version: 99,
                process: .init(source: .app),
                events: []
            ).validatingVersion()
        }
    }
}
