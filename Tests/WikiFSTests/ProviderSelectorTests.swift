import Testing
import Foundation
import ACPModel
@testable import WikiFS
@testable import WikiFSCore

/// v1 provider-selector tests (#325): the `settingDefault(id:)` mutator on
/// `AgentProvidersConfig` (the single-default invariant), the
/// `enabledProviders` view the selector binds to, and the round-trip through
/// the launcher's `setDefaultProvider(id:)` → `resolveSelectedProvider` (the
/// wiring the composer selector relies on so a picked provider becomes the next
/// session's backend). Pure logic only — no live agent subprocess.
@Suite struct ProviderSelectorDefaultTests {

    // MARK: - settingDefault (single-default invariant)

    /// Setting a provider as default demotes every other provider — exactly one
    /// default survives.
    @Test func settingDefaultDemotesOthers() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: true, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: true, isDefault: false),
            AgentProvider(id: "hermes", label: "Hermes", backend: .acp, command: ["hermes", "acp"], enabled: true, isDefault: false),
        ])

        let updated = config.settingDefault(id: "gemini")

        #expect(updated.defaultProvider.id == "gemini")
        // Single-default invariant: exactly one.
        let defaults = updated.providers.filter(\.isDefault)
        #expect(defaults.count == 1)
        // The previous default (Claude) lost it.
        #expect(updated.provider(id: "claude")?.isDefault == false)
        #expect(updated.provider(id: "hermes")?.isDefault == false)
        // selectedProvider() now resolves to the picked one (it's enabled).
        #expect(updated.selectedProvider().id == "gemini")
    }

    /// Switching the default twice returns to the original: the mutator is
    /// idempotent w.r.t. the invariant and reversible.
    @Test func settingDefaultIsReversible() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: true, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])

        let switched = config.settingDefault(id: "gemini")
        #expect(switched.defaultProvider.id == "gemini")

        let back = switched.settingDefault(id: "claude")
        #expect(back.defaultProvider.id == "claude")
        #expect(back.provider(id: "gemini")?.isDefault == false)
    }

    /// Setting an UNKNOWN id as default does not collapse to zero defaults —
    /// normalization keeps exactly one (Claude), so the selector never strands
    /// the launcher with no provider.
    @Test func settingDefaultUnknownIdKeepsInvariant() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: true, isDefault: true),
        ])

        let updated = config.settingDefault(id: "does-not-exist")

        let defaults = updated.providers.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(updated.defaultProvider.id == "claude")
    }

    /// The mutator is PURE: the original config is untouched (returns a new
    /// value). This is what lets the selector bind a fresh @State without
    /// mutating the source.
    @Test func settingDefaultIsPure() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: true, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])

        _ = config.settingDefault(id: "gemini")

        // Original unchanged: Claude is still default.
        #expect(config.defaultProvider.id == "claude")
        #expect(config.provider(id: "gemini")?.isDefault == false)
    }

    // MARK: - enabledProviders (the selector's pickable list)

    /// `enabledProviders` excludes disabled providers, matching the launcher's
    /// `selectedProvider()` fallback (it never launches a disabled one). The
    /// selector menu must agree, or it could show a provider that won't run.
    @Test func enabledProvidersExcludesDisabled() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: true, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: false, isDefault: false),
            AgentProvider(id: "hermes", label: "Hermes", backend: .acp, command: ["hermes", "acp"], enabled: true, isDefault: false),
        ])

        let ids = config.enabledProviders.map(\.id)
        #expect(ids == ["claude", "hermes"])
        #expect(!ids.contains("gemini"))
    }

    // MARK: - Persist + re-read (the launcher reads what the selector wrote)

    /// Setting a default, persisting, and re-loading via `loadOrSeed` returns
    /// the picked provider as default + as `selectedProvider()`. This is the
    /// round-trip the composer selector + the launcher rely on: the selector
    /// writes via `save`, the launcher reads via `resolveSelectedProvider`.
    @Test func settingDefaultPersistsAcrossLoad() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-selector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed the config (Claude default + a discovered agent), then switch.
        var config = AgentProvidersConfig.loadOrSeed(from: tmp, discover: {
            [DiscoveredACPAgent(
                agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]),
                resolvedPath: "/usr/local/bin/gemini")]
        })
        #expect(config.defaultProvider.id == "claude")

        config = config.settingDefault(id: "gemini")
        try config.save(to: tmp)

        // Re-read from disk — the launcher's resolveSelectedProvider path.
        let reloaded = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(reloaded.defaultProvider.id == "gemini")
        #expect(reloaded.selectedProvider().id == "gemini")
        // Single-default invariant survived the round-trip.
        #expect(reloaded.providers.filter(\.isDefault).count == 1)
    }

    // MARK: - Launcher wiring (setDefaultProvider → resolveSelectedProvider)

    /// The launcher's `setDefaultProvider(id:)` persists the pick and the very
    /// next `resolveSelectedProvider()` call returns it — the contract the
    /// composer selector depends on (pick a provider → the next chat uses it,
    /// with no launcher change). Uses a temp container + injected resolvers so
    /// it never touches the real App Group container.
    @MainActor
    @Test func launcherSetDefaultIsReadByResolveSelectedProvider() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let launcher = AgentLauncher()
        launcher.resolveProvidersContainerDirectory = { tmp }
        launcher.resolveSelectedProvider = {
            AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] }).selectedProvider()
        }

        // Seed: Claude default + Gemini (discovered).
        let seed = AgentProvidersConfig.seed(discovered: [
            DiscoveredACPAgent(
                agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]),
                resolvedPath: "/usr/local/bin/gemini"),
        ])
        try seed.save(to: tmp)
        #expect(launcher.resolveSelectedProvider().id == "claude")

        // The composer selector's action: set + persist.
        let updated = launcher.setDefaultProvider(id: "gemini")
        #expect(updated.defaultProvider.id == "gemini")
        // Single-default invariant holds.
        #expect(updated.providers.filter(\.isDefault).count == 1)

        // The launcher now picks up the persisted default for the next session.
        #expect(launcher.resolveSelectedProvider().id == "gemini")
    }

    /// Default = Claude when nothing is picked (the zero-behavior-change
    /// guarantee): a freshly-seeded launcher resolves to Claude without the
    /// selector ever having run.
    @MainActor
    @Test func launcherDefaultsToClaudeWhenUnpicked() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-launcher-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let launcher = AgentLauncher()
        launcher.resolveProvidersContainerDirectory = { tmp }
        launcher.resolveSelectedProvider = {
            AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] }).selectedProvider()
        }

        // providersConfig() seeds + persists on first read; no pick made.
        let config = launcher.providersConfig()
        #expect(config.defaultProvider.id == "claude")
        #expect(launcher.resolveSelectedProvider().id == "claude")
    }
}
