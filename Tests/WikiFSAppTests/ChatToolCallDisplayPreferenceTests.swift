#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

/// Pure preference resolution and migration coverage. Every case runs against
/// a throwaway `UserDefaults(suiteName:)` so the app's real defaults are never
/// touched (mirrors `AppStorageMigrationTests`).
struct ChatToolCallDisplayPreferenceTests {
    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "ChatToolCallDisplayPreferenceTests-\(name)-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("unable to create test defaults suite \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func migratesLegacyValuesAndDefaultsToSummary() {
        // Legacy true → hidden.
        let hiddenDefaults = isolatedDefaults()
        hiddenDefaults.set(true, forKey: ChatToolCallDisplayPreference.legacyHideToolCallsKey)
        ChatToolCallDisplayPreference.migrate(in: hiddenDefaults)
        #expect(hiddenDefaults.string(forKey: ChatToolCallDisplayPreference.storageKey) == "hidden")

        // Legacy false → summary.
        let shownDefaults = isolatedDefaults()
        shownDefaults.set(false, forKey: ChatToolCallDisplayPreference.legacyHideToolCallsKey)
        ChatToolCallDisplayPreference.migrate(in: shownDefaults)
        #expect(shownDefaults.string(forKey: ChatToolCallDisplayPreference.storageKey) == "summary")

        // Both keys absent (fresh install) → summary.
        let freshDefaults = isolatedDefaults()
        ChatToolCallDisplayPreference.migrate(in: freshDefaults)
        #expect(freshDefaults.string(forKey: ChatToolCallDisplayPreference.storageKey) == "summary")
    }

    @Test func preservesExistingNewPreference() {
        let defaults = isolatedDefaults()
        defaults.set("detailed", forKey: ChatToolCallDisplayPreference.storageKey)
        defaults.set(true, forKey: ChatToolCallDisplayPreference.legacyHideToolCallsKey)

        ChatToolCallDisplayPreference.migrate(in: defaults)
        // The new preference wins; the legacy Boolean cannot overwrite it,
        // even though the legacy key is still present.
        #expect(defaults.string(forKey: ChatToolCallDisplayPreference.storageKey) == "detailed")

        // Idempotent: repeated launches keep the value.
        ChatToolCallDisplayPreference.migrate(in: defaults)
        #expect(defaults.string(forKey: ChatToolCallDisplayPreference.storageKey) == "detailed")
    }

    @Test func invalidStoredValueResolvesToSummary() {
        #expect(ChatToolCallDisplayMode.resolving(raw: "nonsense") == .summary)
        #expect(ChatToolCallDisplayMode.resolving(raw: nil) == .summary)
        #expect(ChatToolCallDisplayMode.resolving(raw: "") == .summary)

        let defaults = isolatedDefaults()
        defaults.set("not-a-mode", forKey: ChatToolCallDisplayPreference.storageKey)
        #expect(ChatToolCallDisplayPreference.resolve(in: defaults) == .summary)
    }

    @Test func legacyKeyIsOrphanedAfterMigration() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: ChatToolCallDisplayPreference.legacyHideToolCallsKey)
        ChatToolCallDisplayPreference.migrate(in: defaults)
        // The legacy key stays as a compatibility value (never deleted), but
        // the resolver only reads the new key.
        #expect(defaults.object(forKey: ChatToolCallDisplayPreference.legacyHideToolCallsKey) != nil)
        defaults.set(false, forKey: ChatToolCallDisplayPreference.legacyHideToolCallsKey)
        #expect(ChatToolCallDisplayPreference.resolve(in: defaults) == .hidden)
    }

    @Test func freshResolverReadsEachStoredMode() {
        for mode in ChatToolCallDisplayMode.allCases {
            let defaults = isolatedDefaults()
            defaults.set(mode.rawValue, forKey: ChatToolCallDisplayPreference.storageKey)
            // A fresh resolver (not a cached wrapper) against the same
            // isolated suite reads exactly what was stored.
            #expect(ChatToolCallDisplayPreference.resolve(in: defaults) == mode)
        }
    }
}
#endif
