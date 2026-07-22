#if os(macOS)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// #813: tests for `QuotaFallbackCoordinator` quota state persistence.
/// Verifies that dead-provider state survives a simulated app restart and
/// that revival timestamps are respected.
@MainActor
@Suite("QuotaFallbackCoordinatorPersistence")
struct QuotaFallbackCoordinatorPersistenceTests {

    /// Unique temp URL per test so quota-state.json doesn't pollute across tests.
    private func makeQuotaURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-persist-\(UUID().uuidString).json")
    }

    // MARK: - AC.1: Dead state survives a simulated restart

    @Test("Provider dead state survives a simulated restart")
    func testDeadStateSurvivesRestart() {
        let url = makeQuotaURL()
        let reset = Date(timeIntervalSinceNow: 3600) // 1 hour from now

        // Simulate first run: mark a provider dead, which persists to JSON.
        let coord1 = QuotaFallbackCoordinator(quotaStateURL: url)
        coord1.markExhausted("claude-acp", resetTime: reset, kind: .claudeSession)
        #expect(coord1.isExhausted("claude-acp"))

        // Simulate app restart: create a new coordinator with the same URL.
        let coord2 = QuotaFallbackCoordinator(quotaStateURL: url)
        // The provider should still be dead — state was loaded from JSON.
        #expect(coord2.isExhausted("claude-acp"))
    }

    @Test("Multiple providers survive a simulated restart")
    func testMultipleProvidersSurviveRestart() {
        let url = makeQuotaURL()
        let reset1 = Date(timeIntervalSinceNow: 3600)
        let reset2 = Date(timeIntervalSinceNow: 7200)

        // Simulate first run: mark two providers dead.
        let coord1 = QuotaFallbackCoordinator(quotaStateURL: url)
        coord1.markExhausted("claude-acp", resetTime: reset1, kind: .claudeSession)
        coord1.markExhausted("glm-acp", resetTime: reset2, kind: .zaiErrorCode(1310))
        #expect(coord1.isExhausted("claude-acp"))
        #expect(coord1.isExhausted("glm-acp"))

        // Simulate app restart.
        let coord2 = QuotaFallbackCoordinator(quotaStateURL: url)
        #expect(coord2.isExhausted("claude-acp"))
        #expect(coord2.isExhausted("glm-acp"))
    }

    @Test("Revived provider stays revived across restart")
    func testRevivedProviderStaysRevived() {
        let url = makeQuotaURL()

        // Simulate first run: mark dead, then auto-revive (past date).
        let coord1 = QuotaFallbackCoordinator(quotaStateURL: url)
        let pastDate = Date(timeIntervalSince1970: 0)
        coord1.markExhausted("claude-acp", resetTime: pastDate, kind: .claudeSession)
        // isExhausted auto-revives and saves (entry removed).
        #expect(!coord1.isExhausted("claude-acp"))

        // Simulate app restart.
        let coord2 = QuotaFallbackCoordinator(quotaStateURL: url)
        // Provider should still be revived (not in the persisted state).
        #expect(!coord2.isExhausted("claude-acp"))
    }

    // MARK: - AC.2: Revival timestamps are respected

    @Test("Provider marked dead for 5 min is still dead at 4 min")
    func testStillDeadBeforeExpiry() {
        let url = makeQuotaURL()

        // Mark dead for ~5 minutes (300 seconds).
        let reset = Date(timeIntervalSinceNow: 300)
        let coord = QuotaFallbackCoordinator(quotaStateURL: url)
        coord.markExhausted("claude-acp", resetTime: reset, kind: .claudeSession)

        // Simulate checking at 4 minutes (240 seconds — still within the window).
        // Since the reset is 300s from now and we check immediately, the
        // provider should still be dead (real time hasn't advanced 300s).
        #expect(coord.isExhausted("claude-acp"))
    }

    @Test("Provider marked dead for 5 min is alive at 6 min")
    func testAliveAfterExpiry() {
        let url = makeQuotaURL()

        // Mark dead with a past expiry (simulating 6 min elapsed on a 5 min window).
        let pastExpiry = Date(timeIntervalSinceNow: -60) // expired 1 minute ago
        let coord = QuotaFallbackCoordinator(quotaStateURL: url)
        coord.markExhausted("claude-acp", resetTime: pastExpiry, kind: .claudeSession)

        // Should auto-revive because the revival time has passed.
        #expect(!coord.isExhausted("claude-acp"))
    }

    @Test("Expired entries are pruned on load after restart")
    func testExpiredEntriesPrunedOnLoad() {
        let url = makeQuotaURL()

        // Write a JSON file with an expired entry directly.
        let expiredEntry: [String: Any] = [
            "version": 1,
            "providers": [
                [
                    "providerId": "claude-acp",
                    "deadUntil": ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -3600)),
                    "kind": ["type": "claudeSession"] as [String: Any]
                ] as [String: Any]
            ]
        ]

        let tempURL = url.appendingPathExtension("write-tmp")
        let data = try! JSONSerialization.data(withJSONObject: expiredEntry, options: .prettyPrinted)
        try! data.write(to: tempURL, options: .atomic)
        try! FileManager.default.moveItem(at: tempURL, to: url)

        // Create coordinator — should load and prune the expired entry.
        let coord = QuotaFallbackCoordinator(quotaStateURL: url)
        #expect(!coord.isExhausted("claude-acp"))
    }

    // MARK: - AC.3: Kind survives round-trip

    @Test("Quota signal kind survives persistence round-trip")
    func testKindSurvivesRoundTrip() {
        let url = makeQuotaURL()

        // Mark with zaiErrorCode(1310).
        let coord1 = QuotaFallbackCoordinator(quotaStateURL: url)
        coord1.markExhausted("glm-acp", resetTime: Date(timeIntervalSinceNow: 3600), kind: .zaiErrorCode(1310))

        // Simulate restart and verify the JSON decoded correctly (the provider
        // is still dead, meaning the kind enum decoded without error).
        let coord2 = QuotaFallbackCoordinator(quotaStateURL: url)
        #expect(coord2.isExhausted("glm-acp"))
    }

    @Test("Missing quota state file starts with empty state")
    func testMissingFileStartsEmpty() {
        let url = makeQuotaURL()
        // No file exists yet — coordinator should start with empty state.
        let coord = QuotaFallbackCoordinator(quotaStateURL: url)
        #expect(!coord.isExhausted("claude-acp"))
        #expect(!coord.isExhausted("glm-acp"))
    }
}
#endif // os(macOS)
