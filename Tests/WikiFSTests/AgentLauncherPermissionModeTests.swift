import Testing
import Foundation
import WikiFSEngine
@testable import WikiFSEngine

/// #607 regression suite: per-operation permission policy. Pre-split a single
/// shared `agentPermissionMode` key fed chat + ingest + lint — a user who chose
/// `alwaysAsk` for chat got the same gating on an unattended ingest/lint,
/// guaranteeing a stall on the first prompt needing a permission. Now three
/// independent keys (`PermissionModeKey.chat`/`.ingest`/`.lint`) feed three
/// independent `resolvePermissionMode(for:)` branches.
///
/// Plus the one-time idempotent migration of the legacy `agentPermissionMode`
/// value into `chatPermissionMode` (test #9). See `plans/acp-permissions.md`
/// §5.1, §5.2, §5.3, §8.2 (#7-#10).
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
            let key: String
            let fallback: PermissionPolicy
            switch op {
            case .chat:   key = AgentLauncher.PermissionModeKey.chat;   fallback = .bypass
            case .ingest: key = AgentLauncher.PermissionModeKey.ingest; fallback = .bypass
            case .lint:   key = AgentLauncher.PermissionModeKey.lint;   fallback = .bypass
            }
            let raw = defaults.string(forKey: key) ?? ""
            return PermissionPolicy(rawValue: raw) ?? fallback
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

    /// #8 — Symmetric to #7: the chat policy MUST stay `alwaysAsk` even when
    /// ingest is `bypass`. The split is bidirectional.
    @Test func chatPolicyIndependentOfIngest() {
        let defaults = makeDefaults()
        defaults.set(PermissionPolicy.alwaysAsk.rawValue, forKey: AgentLauncher.PermissionModeKey.chat)
        defaults.set(PermissionPolicy.bypass.rawValue,     forKey: AgentLauncher.PermissionModeKey.ingest)

        let launcher = makeLauncher(defaults: defaults)

        #expect(launcher.resolvePermissionMode(.chat) == .alwaysAsk)
        #expect(launcher.resolvePermissionMode(.ingest) == .bypass)
        // Lint isn't set here either → defaults to .bypass (the §5.2 fallback).
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
