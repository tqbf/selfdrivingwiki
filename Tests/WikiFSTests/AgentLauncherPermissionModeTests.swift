#if os(macOS)
import Testing
import Foundation
import WikiFSEngine
@testable import WikiFSEngine

/// Per-operation permission policy tests. Chat always bypasses client-side
/// permission prompts. Ingest and lint keep independent Settings preferences.
/// The legacy chat preference key remains for one-time migration compatibility.
/// See `plans/acp-permissions.md` §5.1, §5.2, §5.3, §8.2.
@Suite @MainActor struct AgentLauncherPermissionModeTests {

    /// A fresh, isolated defaults suite (unique per call so tests never observe
    /// each other's writes). Mirrors `AppStorageMigrationTests`'s shape.
    private func makeDefaults() -> UserDefaults {
        let suite = "AgentLauncherPermissionModeTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create UserDefaults suite")
            return .standard
        }
        return defaults
    }

    /// A launcher whose `resolvePermissionMode` closure reads from an injected
    /// `UserDefaults` (not `.standard`) so tests don't pollute the real app's
    /// defaults or see cross-test interference.
    private func makeLauncher(defaults: UserDefaults) -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolvePermissionMode = { op in
            switch op {
            case .chat: return PermissionPolicy.bypass
            case .ingest:
                let raw = defaults.string(forKey: AgentLauncher.PermissionModeKey.ingest) ?? ""
                return PermissionPolicy(rawValue: raw) ?? .bypass
            case .lint:
                let raw = defaults.string(forKey: AgentLauncher.PermissionModeKey.lint) ?? ""
                return PermissionPolicy(rawValue: raw) ?? .bypass
            }
        }
        return launcher
    }

    /// #7 — The diagnosed-bug state from #607, now fixed: chat=`alwaysAsk`,
    /// ingest=`bypass`. `resolvePermissionMode(for: .ingest)` MUST return
    /// `.bypass` — independent of the chat setting. Pre-split, both read the
    /// same key and the wrong policy reached the unattended ingest.
    @Test func ingestReadsOwnKeyNotChat() {
        let defaults = makeDefaults()
        defaults.set(PermissionPolicy.alwaysAsk.rawValue, forKey: AgentLauncher.PermissionModeKey.chat)
        defaults.set(PermissionPolicy.bypass.rawValue,     forKey: AgentLauncher.PermissionModeKey.ingest)

        let launcher = makeLauncher(defaults: defaults)

        #expect(launcher.resolvePermissionMode(.ingest) == .bypass)
    }

    /// Chats always bypass client-side permission prompts, even when the legacy
    /// chat preference contains `alwaysAsk`. Ingest keeps its own setting.
    @Test func chatPolicyAlwaysBypassesRegardlessOfStoredPreference() {
        let defaults = makeDefaults()
        defaults.set(PermissionPolicy.alwaysAsk.rawValue, forKey: AgentLauncher.PermissionModeKey.chat)
        defaults.set(PermissionPolicy.alwaysAsk.rawValue, forKey: AgentLauncher.PermissionModeKey.ingest)

        let launcher = makeLauncher(defaults: defaults)

        #expect(launcher.resolvePermissionMode(.chat) == .bypass)
        #expect(launcher.resolvePermissionMode(.ingest) == .alwaysAsk)
        #expect(launcher.resolvePermissionMode(.lint) == .bypass)
    }

    /// #9 — One-time migration: legacy `agentPermissionMode` →
    /// `chatPermissionMode`. Idempotent: the second `migrateOnce()` is a no-op
    /// (the guard predicate `object(forKey:) == nil` fails after the first run
    /// because the new key is now written).
    @Test func legacyKeyMigratesIntoChatOnce() {
        let defaults = makeDefaults()
        defaults.set(PermissionPolicy.alwaysAsk.rawValue, forKey: "agentPermissionMode")

        // Pre-migration: chat key is unset (object == nil). The legacy key is set.
        #expect(defaults.object(forKey: AgentLauncher.PermissionModeKey.chat) == nil)

        PermissionModeMigration.migrateOnce(in: defaults)

        // Chat key copies the legacy value.
        #expect(defaults.string(forKey: AgentLauncher.PermissionModeKey.chat) == PermissionPolicy.alwaysAsk.rawValue)
        // Copy, not move — the legacy key is left in place (orphaned, like
        // sandbox-config.json — see plans/acp-permissions.md §5.3).
        #expect(defaults.string(forKey: "agentPermissionMode") == PermissionPolicy.alwaysAsk.rawValue)

        // Second run is a no-op — the chat key is already set, so the guard
        // fails. (The legacy key is NOT re-copied; the chat key is NOT overwritten.)
        PermissionModeMigration.migrateOnce(in: defaults)
        #expect(defaults.string(forKey: AgentLauncher.PermissionModeKey.chat) == PermissionPolicy.alwaysAsk.rawValue)
    }

    /// #9b — Idempotent guard predicate is `object(forKey:) == nil`, NOT
    /// `string(forKey:) == nil`. The two are indistinguishable for "key present
    /// but empty string" — `object(forKey:)` is the only correct key-presence
    /// check. A user who manually cleared the chat key to "" must not have it
    /// overwritten by a re-migration.
    @Test func migrationGuardUsesObjectForKeyNotNilString() {
        let defaults = makeDefaults()
        // Chat key is PRESENT but EMPTY (string == nil distinguishes nothing;
        // object != nil distinguishes presence).
        defaults.set("", forKey: AgentLauncher.PermissionModeKey.chat)
        // Legacy key is also set with a valid value.
        defaults.set(PermissionPolicy.alwaysAsk.rawValue, forKey: "agentPermissionMode")

        PermissionModeMigration.migrateOnce(in: defaults)

        // Guard correctly rejected: chat key is still "" (NOT overwritten with
        // "alwaysAsk") because `object(forKey: chatKey)` is non-nil. The legacy
        // value is left in place too (no migration).
        #expect(defaults.string(forKey: AgentLauncher.PermissionModeKey.chat) == "")
        #expect(defaults.string(forKey: "agentPermissionMode") == PermissionPolicy.alwaysAsk.rawValue)
    }

    /// #10 — Fresh install defaults: every kind resolves to `.bypass` when no
    /// keys are set. The §5.2 read-time `?? fallback` is the second line of
    /// defense; `@AppStorage`'s default (in Settings + ChatDetailView) is the first.
    @Test func defaultsWhenUnset() {
        let defaults = makeDefaults()
        let launcher = makeLauncher(defaults: defaults)

        #expect(launcher.resolvePermissionMode(.chat) == .bypass)
        #expect(launcher.resolvePermissionMode(.ingest) == .bypass)
        #expect(launcher.resolvePermissionMode(.lint) == .bypass)
    }
}
#endif // os(macOS)
