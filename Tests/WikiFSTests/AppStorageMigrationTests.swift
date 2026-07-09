import Testing
import Foundation
import WikiFSCore

/// Unit tests for the renamed `@AppStorage` zoom-key migration (AC.3). Each test
/// uses a throwaway `UserDefaults(suiteName:)` (unique per run) so the app's real
/// `.standard` defaults are never touched.
struct AppStorageMigrationTests {

    /// A fresh, isolated defaults suite. The suite name is unique per call so tests
    /// never observe each other's writes.
    private func makeDefaults() -> UserDefaults {
        let suite = "AppStorageMigrationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create UserDefaults suite")
            return .standard
        }
        return defaults
    }

    /// A returning user with a previously-set `conversation.zoom` keeps their zoom.
    @Test func migratesOldKeyToNewKeyWhenNewKeyUnset() {
        let defaults = makeDefaults()
        defaults.set(1.5, forKey: "conversation.zoom")
        #expect(defaults.object(forKey: "chat.zoom") == nil)

        AppStorageMigration.migrateZoomKey(in: defaults)

        #expect(defaults.double(forKey: "chat.zoom") == 1.5)
        // Copy, not move: the old key is left in place.
        #expect(defaults.object(forKey: "conversation.zoom") != nil)
    }

    /// A user who already has `chat.zoom` set is never overwritten.
    @Test func doesNotOverwriteWhenNewKeyAlreadySet() {
        let defaults = makeDefaults()
        defaults.set(1.5, forKey: "conversation.zoom")
        defaults.set(2.0, forKey: "chat.zoom")

        AppStorageMigration.migrateZoomKey(in: defaults)

        #expect(defaults.double(forKey: "chat.zoom") == 2.0)
    }

    /// A fresh install (no old key) is a no-op to the default.
    @Test func noOpWhenOldKeyUnsetFreshInstall() {
        let defaults = makeDefaults()

        AppStorageMigration.migrateZoomKey(in: defaults)

        #expect(defaults.object(forKey: "chat.zoom") == nil)
        #expect(defaults.object(forKey: "conversation.zoom") == nil)
    }

    /// Safe to run on every launch.
    @Test func idempotentRunningTwice() {
        let defaults = makeDefaults()
        defaults.set(1.25, forKey: "conversation.zoom")

        AppStorageMigration.migrateZoomKey(in: defaults)
        AppStorageMigration.migrateZoomKey(in: defaults)

        #expect(defaults.double(forKey: "chat.zoom") == 1.25)
    }
}
