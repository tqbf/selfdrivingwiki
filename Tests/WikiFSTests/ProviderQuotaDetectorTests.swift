#if os(macOS)
import Foundation
import Testing
import ACPModel
@testable import WikiFSEngine

/// #727: tests for the pure `ProviderQuotaDetector` — the detection logic that
/// inspects a `ClientError.agentError(JSONRPCError)` for a quota signal.
///
/// The detector operates ONLY on `JSONRPCError.code`/`.message`/`.data` — the
/// ACP SDK is stdio JSON-RPC (no HTTP body/status/headers).
@Suite("ProviderQuotaDetector")
struct ProviderQuotaDetectorTests {

    // MARK: - Claude text heuristic

    @Test("Claude session limit detected")
    func testClaudeSessionLimitDetected() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "Your Claude session limit has been reached. Please try again later.",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "claude-acp", error: error)
        #expect(signal != nil)
        #expect(signal?.providerId == "claude-acp")
        #expect(signal?.kind == .claudeSession)
        #expect(signal?.resetTime != nil)
    }

    @Test("Claude weekly limit detected with 7-day default")
    func testClaudeWeeklyLimitDetected() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "You have exceeded your weekly limit for Opus.",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "claude-acp", error: error)
        #expect(signal != nil)
        #expect(signal?.kind == .claudeWeekly)
        if let signal, let reset = signal.resetTime {
            let interval = reset.timeIntervalSinceNow
            // Should be ~7 days (within 5 seconds tolerance)
            #expect(interval > 6.9 * 86400)
            #expect(interval < 7.1 * 86400)
        }
    }

    @Test("Claude Opus limit detected as session")
    func testClaudeOpusLimitDetected() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "Opus limit reached.",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "claude-acp", error: error)
        #expect(signal?.kind == .claudeSession)
    }

    @Test("Claude throughput 429 without quota phrases returns nil")
    func testClaudeThroughput429ReturnsNil() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "Too many requests. Please slow down.",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "claude-acp", error: error)
        #expect(signal == nil)
    }

    @Test("Claude usage limit reached detected as weekly")
    func testClaudeUsageLimitReached() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "Your usage limit has been reached.",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "claude-acp", error: error)
        #expect(signal?.kind == .claudeWeekly)
    }

    // MARK: - z.ai numeric code heuristic

    @Test("z.ai error code 1310 detected")
    func testZaiCode1310Detected() {
        let error = ClientError.agentError(JSONRPCError(
            code: 1310,
            message: "Quota exceeded",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal != nil)
        if let signal {
            #expect(signal.kind == .zaiErrorCode(1310))
            #expect(signal.resetTime != nil)
        }
    }

    @Test("z.ai error code 1316 detected")
    func testZaiCode1316Detected() {
        let error = ClientError.agentError(JSONRPCError(
            code: 1316,
            message: "Rate limit exceeded",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal?.kind == .zaiErrorCode(1316))
    }

    @Test("z.ai transient code 1302 NOT detected")
    func testZaiCode1302Excluded() {
        let error = ClientError.agentError(JSONRPCError(
            code: 1302,
            message: "Server busy, please try again",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal == nil)
    }

    @Test("z.ai transient code 1305 NOT detected")
    func testZaiCode1305Excluded() {
        let error = ClientError.agentError(JSONRPCError(
            code: 1305,
            message: "Internal error, retry",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal == nil)
    }

    @Test("z.ai transient code 1313 NOT detected")
    func testZaiCode1313Excluded() {
        let error = ClientError.agentError(JSONRPCError(
            code: 1313,
            message: "Service unavailable",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal == nil)
    }

    // MARK: - z.ai code from message text

    @Test("z.ai code parsed from message text")
    func testZaiCodeFromMessage() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "Request failed, error code: 1310. Please try later.",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal?.kind == .zaiErrorCode(1310))
    }

    @Test("z.ai code parsed from data string")
    func testZaiCodeFromDataString() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "Error",
            data: AnyCodable("error code=1317, retry after reset")
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal?.kind == .zaiErrorCode(1317))
    }

    @Test("z.ai code from data int")
    func testZaiCodeFromDataInt() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "Error",
            data: AnyCodable(1319)
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal?.kind == .zaiErrorCode(1319))
    }

    @Test("z.ai code from data dict")
    func testZaiCodeFromDataDict() throws {
        // AnyCodable decodes from JSON; build via JSON to get a [String: Any]
        // value at runtime (since `Any` != `Sendable`).
        let json = #"{"error_code": 1318}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        let anyCodable = try decoder.decode(AnyCodable.self, from: json)
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "Error",
            data: anyCodable
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal?.kind == .zaiErrorCode(1318))
    }

    // MARK: - z.ai reset time parsing

    @Test("z.ai next_flush_time parsed from data")
    func testZaiResetTimeParsing() throws {
        let futureDate = "2099-01-01T12:00:00Z"
        let json = #"{"next_flush_time": "\#(futureDate)"}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        let anyCodable = try decoder.decode(AnyCodable.self, from: json)
        let error = ClientError.agentError(JSONRPCError(
            code: 1310,
            message: "Quota exceeded",
            data: anyCodable
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        #expect(signal?.kind == .zaiErrorCode(1310))
        if let signal, let reset = signal.resetTime {
            let isoFormatter = ISO8601DateFormatter()
            let expected = isoFormatter.date(from: futureDate)!
            #expect(reset == expected)
        }
    }

    // MARK: - Non-quota errors return nil

    @Test("Non-agentError returns nil")
    func testNonAgentErrorReturnsNil() {
        struct SomeOtherError: Error {}
        let signal = ProviderQuotaDetector.detect(providerId: "claude-acp", error: SomeOtherError())
        #expect(signal == nil)
    }

    @Test("ClientError.invalidResponse returns nil")
    func testInvalidResponseReturnsNil() {
        let signal = ProviderQuotaDetector.detect(
            providerId: "claude-acp",
            error: ClientError.invalidResponse
        )
        #expect(signal == nil)
    }

    @Test("ClientError.connectionClosed returns nil")
    func testConnectionClosedReturnsNil() {
        let signal = ProviderQuotaDetector.detect(
            providerId: "claude-acp",
            error: ClientError.connectionClosed
        )
        #expect(signal == nil)
    }

    // MARK: - Unknown provider family

    @Test("Unknown provider family runs both heuristics — Claude match found")
    func testUnknownFamilyClaudeMatch() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "session limit reached",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "some-provider", error: error)
        #expect(signal?.kind == .claudeSession)
    }

    @Test("Unknown provider family runs both heuristics — z.ai match found")
    func testUnknownFamilyZaiMatch() {
        let error = ClientError.agentError(JSONRPCError(
            code: 1310,
            message: "quota exceeded",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "some-provider", error: error)
        #expect(signal?.kind == .zaiErrorCode(1310))
    }

    @Test("Unknown provider family with non-quota error returns nil")
    func testUnknownFamilyNonQuota() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "Internal server error",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "some-provider", error: error)
        #expect(signal == nil)
    }

    // MARK: - Provider family inference

    @Test("Provider family inference")
    func testProviderFamily() {
        #expect(ProviderQuotaDetector.providerFamily(forProviderId: "claude-acp") == .claude)
        #expect(ProviderQuotaDetector.providerFamily(forProviderId: "Claude") == .claude)
        #expect(ProviderQuotaDetector.providerFamily(forProviderId: "glm-4") == .zai)
        #expect(ProviderQuotaDetector.providerFamily(forProviderId: "zai-glm") == .zai)
        #expect(ProviderQuotaDetector.providerFamily(forProviderId: "z-ai-provider") == .zai)
        #expect(ProviderQuotaDetector.providerFamily(forProviderId: "gemini") == .unknown)
    }

    // MARK: - nil reset time defaults

    @Test("Claude session limit has 5-hour default reset")
    func testClaudeSessionDefaultReset() {
        let error = ClientError.agentError(JSONRPCError(
            code: -32603,
            message: "session limit reached",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "claude-acp", error: error)
        if let signal, let reset = signal.resetTime {
            let interval = reset.timeIntervalSinceNow
            #expect(interval > 4.9 * 3600)
            #expect(interval < 5.1 * 3600)
        }
    }

    @Test("z.ai code has 1-hour default reset when no timestamp")
    func testZaiDefaultReset() {
        let error = ClientError.agentError(JSONRPCError(
            code: 1308,
            message: "quota exceeded",
            data: nil
        ))
        let signal = ProviderQuotaDetector.detect(providerId: "glm-acp", error: error)
        if let signal, let reset = signal.resetTime {
            let interval = reset.timeIntervalSinceNow
            #expect(interval > 0.9 * 3600)
            #expect(interval < 1.1 * 3600)
        }
    }
}
#endif // os(macOS)
