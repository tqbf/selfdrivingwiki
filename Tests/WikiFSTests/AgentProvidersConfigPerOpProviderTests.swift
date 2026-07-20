import Testing
import Foundation
@testable import WikiFSCore

/// per-op-provider: per-operation default-provider overrides. Pure-logic
/// tests for the three new fields (`chatProviderId` / `ingestProviderId` /
/// `lintProviderId`) + their resolution methods (`providerForChat/Ingest/Lint`)
/// + their setters (`settingChatProvider/Ingest/Lint`).
///
/// Covers:
/// - Resolution fall-back to `defaultProvider` when the pin is nil.
/// - Resolution fall-back when the pin points at a deleted provider (no
///   dangling reference — the diagnosed AC for "When a provider is deleted,
///   any operation referencing it falls back to defaultProvider").
/// - Setter round-trip + nil/whitespace normalization.
/// - Carry-through: existing setters preserve the per-op pins.
/// - Codable backward-compat: a pre-per-op-provider `agent-providers.json`
///   (no `chatProviderId` etc. keys) decodes to all-nil → every operation
///   falls back to `defaultProvider` (the legacy behavior). Round-trip
///   preserves the pins.
/// - `loadOrSeed` carries the pins through.
@Suite("AgentProvidersConfig per-op-provider")
struct AgentProvidersConfigPerOpProviderTests {

    // MARK: - Fixture

    /// Two providers so we can distinguish "pinned" from "default" in tests.
    /// `claude-acp` is default, `gemini` is an enabled non-default.
    private var fixture: AgentProvidersConfig {
        AgentProvidersConfig(providers: [
            AgentProvider(id: "claude-acp", label: "Claude", command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], enabled: true, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])
    }

    // MARK: - Resolution: nil falls back to defaultProvider

    @Test func providerForChatFallsBackToDefaultWhenNil() {
        let config = fixture
        #expect(config.chatProviderId == nil)
        #expect(config.providerForChat().id == "claude-acp")
    }

    @Test func providerForIngestFallsBackToDefaultWhenNil() {
        let config = fixture
        #expect(config.ingestProviderId == nil)
        #expect(config.providerForIngest().id == "claude-acp")
    }

    @Test func providerForLintFallsBackToDefaultWhenNil() {
        let config = fixture
        #expect(config.lintProviderId == nil)
        #expect(config.providerForLint().id == "claude-acp")
    }

    // MARK: - Resolution: pinned provider wins

    @Test func providerForChatReturnsPinnedProvider() {
        let config = fixture.settingChatProvider(id: "gemini")
        #expect(config.chatProviderId == "gemini")
        #expect(config.providerForChat().id == "gemini")
    }

    @Test func providerForIngestReturnsPinnedProvider() {
        let config = fixture.settingIngestProvider(id: "gemini")
        #expect(config.providerForIngest().id == "gemini")
    }

    @Test func providerForLintReturnsPinnedProvider() {
        let config = fixture.settingLintProvider(id: "gemini")
        #expect(config.providerForLint().id == "gemini")
    }

    // MARK: - Resolution: deleted provider falls back (no dangling refs)

    @Test func providerForChatFallsBackWhenPinnedProviderWasDeleted() {
        // chat is pinned to "gemini", but gemini was deleted from the config.
        // The resolver must NOT crash, NOT return nil, NOT return a stale
        // provider — it returns `defaultProvider`. This is the AC for "When a
        // provider is deleted, any operation referencing it falls back to
        // defaultProvider."
        let config = AgentProvidersConfig(
            providers: [.claudeAcpDefault],
            chatProviderId: "gemini")
        #expect(config.chatProviderId == "gemini")
        #expect(config.providerForChat().id == "claude-acp")
    }

    @Test func providerForIngestFallsBackWhenPinnedProviderWasDeleted() {
        let config = AgentProvidersConfig(
            providers: [.claudeAcpDefault],
            ingestProviderId: "deleted-id")
        #expect(config.providerForIngest().id == "claude-acp")
    }

    @Test func providerForLintFallsBackWhenPinnedProviderWasDeleted() {
        let config = AgentProvidersConfig(
            providers: [.claudeAcpDefault],
            lintProviderId: "deleted-id")
        #expect(config.providerForLint().id == "claude-acp")
    }

    // MARK: - Independent pins

    @Test func perOpPinsAreIndependent() {
        // Three operations, three different providers (one is a synthetic id
        // that doesn't exist — exercises the fallback path too).
        let other = AgentProvider(id: "kilo", label: "Kilo", command: ["kilo"], enabled: true, isDefault: false)
        let config = AgentProvidersConfig(
            providers: [.claudeAcpDefault, other],
            chatProviderId: "claude-acp",
            ingestProviderId: "kilo",
            lintProviderId: "deleted")
        #expect(config.providerForChat().id == "claude-acp")
        #expect(config.providerForIngest().id == "kilo")
        #expect(config.providerForLint().id == "claude-acp")  // deleted → fallback
    }

    // MARK: - Setters: round-trip + nil/whitespace normalization

    @Test func settingChatProviderClearsOnNil() {
        let config = fixture.settingChatProvider(id: "gemini").settingChatProvider(id: nil)
        #expect(config.chatProviderId == nil)
        #expect(config.providerForChat().id == "claude-acp")
    }

    @Test func settingIngestProviderClearsOnEmpty() {
        let config = fixture.settingIngestProvider(id: "gemini").settingIngestProvider(id: "")
        #expect(config.ingestProviderId == nil)
    }

    @Test func settingLintProviderClearsOnWhitespace() {
        // Whitespace-only is normalized to nil (trimming + empty check) so a
        // paste of "  " doesn't get treated as an id that never matches.
        let config = fixture.settingLintProvider(id: "   ")
        #expect(config.lintProviderId == nil)
    }

    @Test func settingChatProviderTrimsWhitespace() {
        let config = fixture.settingChatProvider(id: "  gemini  ")
        #expect(config.chatProviderId == "gemini")
        #expect(config.providerForChat().id == "gemini")
    }

    // MARK: - Carry-through: existing setters preserve the per-op pins

    @Test func settingDefaultPreservesPerOpPins() {
        // Changing the default provider does NOT clear the per-op pins — the
        // pin is the whole point. If chat was pinned to gemini and the user
        // changes the default to claude-acp, chat still routes to gemini.
        let config = fixture
            .settingChatProvider(id: "gemini")
            .settingIngestProvider(id: "gemini")
            .settingLintProvider(id: "gemini")
            .settingDefault(id: "claude-acp")
        #expect(config.chatProviderId == "gemini")
        #expect(config.ingestProviderId == "gemini")
        #expect(config.lintProviderId == "gemini")
        #expect(config.providerForChat().id == "gemini")
        #expect(config.providerForIngest().id == "gemini")
        #expect(config.providerForLint().id == "gemini")
    }

    @Test func settingSelectedModelPreservesPerOpPins() {
        let config = fixture
            .settingChatProvider(id: "gemini")
            .settingSelectedModel("sonnet", forProvider: "claude-acp")
        #expect(config.chatProviderId == "gemini")
        #expect(config.selectedModelId(forProvider: "claude-acp") == "sonnet")
    }

    @Test func settingCachedModelsPreservesPerOpPins() {
        let cached = [CachedModelInfo(modelId: "opus", name: "Opus", description: nil)]
        let config = fixture
            .settingLintProvider(id: "gemini")
            .settingCachedModels(cached, forProvider: "claude-acp")
        #expect(config.lintProviderId == "gemini")
        #expect(config.cachedModels(forProvider: "claude-acp").count == 1)
    }

    @Test func togglingFavoritePreservesPerOpPins() {
        let config = fixture
            .settingIngestProvider(id: "gemini")
            .togglingFavoriteModel("opus", forProvider: "claude-acp")
        #expect(config.ingestProviderId == "gemini")
        #expect(config.isFavoriteModel("opus", forProvider: "claude-acp"))
    }

    // MARK: - Codable backward-compat

    @Test func oldConfigWithoutPerOpFieldsDecodesAllNil() throws {
        // Hand-craft a JSON that omits the per-op fields (what a pre-per-op-
        // provider `agent-providers.json` looks like). It must decode with all
        // three pins nil → every operation routes to defaultProvider (the
        // legacy behavior, no migration).
        let json = """
        {
          "providers": [
            { "id": "claude-acp", "label": "Claude", "command": ["bun", "x", "@agentclientprotocol/claude-agent-acp"], "env": {}, "enabled": true, "isDefault": true }
          ],
          "providerModels": {},
          "selectedModelIds": { "claude-acp": "sonnet" },
          "favoriteModelIds": {},
          "maxConcurrent": {}
        }
        """
        let data = Data(json.utf8)
        let config = try JSONDecoder().decode(AgentProvidersConfig.self, from: data)
        #expect(config.chatProviderId == nil)
        #expect(config.ingestProviderId == nil)
        #expect(config.lintProviderId == nil)
        #expect(config.providerForChat().id == "claude-acp")
        #expect(config.providerForIngest().id == "claude-acp")
        #expect(config.providerForLint().id == "claude-acp")
    }

    @Test func perOpFieldsRoundTripThroughDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-perop-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = fixture
            .settingChatProvider(id: "gemini")
            .settingIngestProvider(id: "claude-acp")
            .settingLintProvider(id: "gemini")
        try original.save(to: tmp)

        let loaded = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(loaded.chatProviderId == "gemini")
        #expect(loaded.ingestProviderId == "claude-acp")
        #expect(loaded.lintProviderId == "gemini")
        // Sanity: the resolved providers match the pins (gemini exists).
        #expect(loaded.providerForChat().id == "gemini")
        #expect(loaded.providerForIngest().id == "claude-acp")
        #expect(loaded.providerForLint().id == "gemini")
    }

    // MARK: - loadOrSeed carries the pins through

    @Test func loadOrSeedPreservesPerOpPinsFromDisk() throws {
        // loadOrSeed re-wraps the decoded config to re-apply normalization +
        // the claude-acp model backfill. That re-wrap must NOT wipe the per-op
        // pins — the test pins all three, plus a stale pin pointing at a
        // deleted provider, to verify the stale id is preserved on disk (the
        // resolver falls back at READ time, not at load time).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-perop-loadorseed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "claude-acp", label: "Claude", command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], enabled: true, isDefault: true),
                AgentProvider(id: "gemini", label: "Gemini", command: ["gemini", "--acp"], enabled: true, isDefault: false),
            ],
            selectedModelIds: ["claude-acp": "sonnet"],
            chatProviderId: "gemini",
            ingestProviderId: "deleted-id",
            lintProviderId: nil)
        try original.save(to: tmp)

        let loaded = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(loaded.chatProviderId == "gemini")
        #expect(loaded.ingestProviderId == "deleted-id")
        #expect(loaded.lintProviderId == nil)
        // Resolution at read time:
        #expect(loaded.providerForChat().id == "gemini")
        #expect(loaded.providerForIngest().id == "claude-acp")  // stale → fallback
        #expect(loaded.providerForLint().id == "claude-acp")
    }

    // MARK: - Float through existing carried fields too

    @Test func perOpPinsDoNotResetModelCachesOrFavorites() {
        // Setting a per-op pin must not wipe `providerModels` /
        // `favoriteModelIds` / `maxConcurrent` / `selectedModelIds` — those are
        // independent fields and the setters carry them through.
        let cached = [CachedModelInfo(modelId: "opus", name: "Opus", description: nil)]
        let config = fixture
            .settingCachedModels(cached, forProvider: "claude-acp")
            .togglingFavoriteModel("opus", forProvider: "claude-acp")
            .settingSelectedModel("sonnet", forProvider: "claude-acp")
            .settingChatProvider(id: "gemini")
        #expect(config.cachedModels(forProvider: "claude-acp").count == 1)
        #expect(config.isFavoriteModel("opus", forProvider: "claude-acp"))
        #expect(config.selectedModelId(forProvider: "claude-acp") == "sonnet")
        #expect(config.chatProviderId == "gemini")
    }
}
