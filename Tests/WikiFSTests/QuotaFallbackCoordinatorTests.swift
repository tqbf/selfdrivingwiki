#if os(macOS)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// #727: tests for `QuotaFallbackCoordinator` — the dead-provider map + chain
/// walk.
@MainActor
@Suite("QuotaFallbackCoordinator")
struct QuotaFallbackCoordinatorTests {

    private func makeProvider(_ id: String, enabled: Bool = true) -> AgentProvider {
        AgentProvider(id: id, label: id.capitalized, command: [id], enabled: enabled)
    }

    /// #813: unique temp URL per test so quota-state.json doesn't pollute
    /// across tests (each coordinator reads/writes its own file).
    private func makeQuotaURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-test-\(UUID().uuidString).json")
    }

    // MARK: - markExhausted / isExhausted

    @Test("markExhausted marks provider as dead")
    func testMarkExhausted() {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        let reset = Date(timeIntervalSinceNow: 3600)
        coord.markExhausted("claude-acp", resetTime: reset, kind: .claudeSession)
        #expect(coord.isExhausted("claude-acp"))
    }

    @Test("isExhausted returns false for unknown provider")
    func testUnknownProviderNotExhausted() {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        #expect(!coord.isExhausted("nonexistent"))
    }

    // MARK: - Auto-revival

    @Test("Auto-revival after reset time")
    func testAutoRevival() {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        let pastDate = Date(timeIntervalSince1970: 0)  // already past
        coord.markExhausted("claude-acp", resetTime: pastDate, kind: .claudeSession)
        // Should auto-revive (now >= reset) → not exhausted.
        #expect(!coord.isExhausted("claude-acp"))
    }

    // MARK: - firstLive

    @Test("firstLive returns the first non-exhausted provider")
    func testFirstLive() {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        let chain = [
            makeProvider("claude-acp"),
            makeProvider("glm-acp"),
            makeProvider("gemini")
        ]
        // No dead providers → first.
        #expect(coord.firstLive(in: chain)?.id == "claude-acp")

        // Mark claude dead → glm is first.
        coord.markExhausted("claude-acp", resetTime: Date(timeIntervalSinceNow: 3600), kind: .claudeSession)
        #expect(coord.firstLive(in: chain)?.id == "glm-acp")

        // Mark glm dead too → gemini is first.
        coord.markExhausted("glm-acp", resetTime: Date(timeIntervalSinceNow: 3600), kind: .zaiErrorCode(1310))
        #expect(coord.firstLive(in: chain)?.id == "gemini")
    }

    @Test("firstLive returns nil when all providers exhausted")
    func testAllExhausted() {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        let chain = [
            makeProvider("claude-acp"),
            makeProvider("glm-acp")
        ]
        coord.markExhausted("claude-acp", resetTime: Date(timeIntervalSinceNow: 3600), kind: .claudeSession)
        coord.markExhausted("glm-acp", resetTime: Date(timeIntervalSinceNow: 3600), kind: .zaiErrorCode(1310))
        #expect(coord.firstLive(in: chain) == nil)
    }

    @Test("firstLive with empty chain returns nil")
    func testEmptyChain() {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        #expect(coord.firstLive(in: []) == nil)
    }

    // MARK: - Longer window wins

    @Test("Marking exhausted twice keeps the longer window")
    func testLongerWindowWins() {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        let longReset = Date(timeIntervalSinceNow: 7 * 86400)  // 7 days
        let shortReset = Date(timeIntervalSinceNow: 3600)      // 1 hour
        coord.markExhausted("claude-acp", resetTime: longReset, kind: .claudeWeekly)
        coord.markExhausted("claude-acp", resetTime: shortReset, kind: .claudeSession)
        // The longer window (7 days) should still be in effect.
        #expect(coord.isExhausted("claude-acp"))
    }

    // MARK: - Default reset time when nil

    @Test("Nil reset time applies conservative default")
    func testNilResetTimeDefault() {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        coord.markExhausted("claude-acp", resetTime: nil, kind: .claudeSession)
        // Should be dead with a 5-hour default.
        #expect(coord.isExhausted("claude-acp"))
    }

    // MARK: - Planner tracking

    @Test("recordPlanner sets plannerProviderId")
    func testRecordPlanner() {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        let backend = FakeAgentBackend()
        coord.recordPlanner(providerId: "glm-acp", backend: backend)
        #expect(coord.plannerProviderId == "glm-acp")
    }

    // MARK: - Backend teardown

    @Test("finishFallbackBackends cancels non-primary backends")
    func testFinishFallbackBackends() async {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        let primary = FakeAgentBackend()
        let fallback = FakeAgentBackend()
        coord.recordBackend(primary, forProvider: "claude-acp")
        coord.recordBackend(fallback, forProvider: "glm-acp")
        await coord.finishFallbackBackends(excludingPrimaryProvider: "claude-acp")
        // Primary should be retained; fallback removed.
        #expect(coord.backends["claude-acp"] != nil)
        #expect(coord.backends["glm-acp"] == nil)
        // Fallback backend should have been cancelled.
        #expect(await fallback.cancelCount == 1)
    }

    @Test("finishFallbackBackends with nil primary cancels all")
    func testFinishAllBackends() async {
        let coord = QuotaFallbackCoordinator(quotaStateURL: makeQuotaURL())
        let backend1 = FakeAgentBackend()
        let backend2 = FakeAgentBackend()
        coord.recordBackend(backend1, forProvider: "claude-acp")
        coord.recordBackend(backend2, forProvider: "glm-acp")
        await coord.finishFallbackBackends(excludingPrimaryProvider: nil)
        #expect(coord.backends.isEmpty)
        #expect(await backend1.cancelCount == 1)
        #expect(await backend2.cancelCount == 1)
    }
}
#endif // os(macOS)
