import Foundation
import Testing
@testable import WikiFSCore

/// #727: `TurnFailureReason.quotaExhausted` is Codable (persisted in
/// `chat_messages.event_json`). Verify forward-compatible round-trip of the
/// new case.
@Suite("TurnFailureReason Codable")
struct TurnFailureReasonCodableTests {

    @Test("quotaExhausted with resetTime round-trips")
    func testQuotaExhaustedRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1753000000)
        let reason = TurnFailureReason.quotaExhausted(provider: "claude-acp", resetTime: date)

        let encoder = JSONEncoder()
        let data = try encoder.encode(reason)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TurnFailureReason.self, from: data)

        #expect(decoded == reason)
    }

    @Test("quotaExhausted with nil resetTime round-trips")
    func testQuotaExhaustedNilResetTime() throws {
        let reason = TurnFailureReason.quotaExhausted(provider: "glm-acp", resetTime: nil)

        let encoder = JSONEncoder()
        let data = try encoder.encode(reason)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TurnFailureReason.self, from: data)

        #expect(decoded == reason)
    }

    @Test("Old cases still round-trip")
    func testExistingCasesRoundTrip() throws {
        let cases: [TurnFailureReason] = [
            .stalled(idleSeconds: 42),
            .ceilingExceeded(totalSeconds: 1800),
            .agentError("some error")
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for reason in cases {
            let data = try encoder.encode(reason)
            let decoded = try decoder.decode(TurnFailureReason.self, from: data)
            #expect(decoded == reason)
        }
    }

    @Test("Description and label render correctly")
    func testDescriptionAndLabel() {
        let date = Date(timeIntervalSince1970: 1753000000)
        let reason = TurnFailureReason.quotaExhausted(provider: "claude-acp", resetTime: date)
        #expect(reason.label == "Provider quota exhausted.")
        #expect(reason.description.contains("claude-acp"))
        #expect(reason.description.contains("quota exhausted"))

        let noReset = TurnFailureReason.quotaExhausted(provider: "glm-acp", resetTime: nil)
        #expect(noReset.description.contains("glm-acp"))
        #expect(!noReset.description.contains("until"))
    }
}
