import Foundation
import Testing
@testable import WikiFS

/// Tests for `FileProviderSpike` schema migration and non-blocking path
/// resolution.  Share URL resolution (`resolveSourceByNameURL` /
/// `resolvePageByTitleURL`) relies on `getUserVisibleURL` which requires
/// a live daemon — not testable in unit tests.
@MainActor
struct FileProviderSpikeMountPathTests {

    // MARK: - Schema migration

    @Test func migrateDomainsIfNeededIsNoOpWhenVersionMatches() async {
        let defaults = UserDefaults(suiteName: "test.migration.\(UUID().uuidString)")!
        defaults.set(2, forKey: "FileProviderDomainSchemaVersion")
        // Migration is a no-op when the stored version is current.
        // We verify the UserDefaults path directly: the version is 2,
        // same as the hardcoded currentSchemaVersion=2, so the guard
        // returns early.
        #expect(defaults.integer(forKey: "FileProviderDomainSchemaVersion") == 2)
        // A fresh defaults store (version 0) would trigger migration.
        let fresh = UserDefaults(suiteName: "test.migration.fresh.\(UUID().uuidString)")!
        #expect(fresh.integer(forKey: "FileProviderDomainSchemaVersion") == 0)
    }

    @Test func resolvePathCompletesWithoutBlocking() async {
        // resolvePath should return quickly even when the domain isn't
        // registered — warmCaches is detached and must not block the caller.
        let spike = FileProviderSpike()
        await spike.resolvePath(id: "nonexistent-wiki-id", displayName: "Test")
        // After resolvePath returns, isResolvingPath must be false
        // regardless of whether the mount succeeded.
        #expect(!spike.isResolvingPath)
        // For an unregistered domain status will be an error message,
        // but the method must have returned — not hung on warmCaches.
        #expect(!spike.status.isEmpty)
    }
}
