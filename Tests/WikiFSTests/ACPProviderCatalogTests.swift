import Foundation
import Testing
@testable import WikiFSCore

/// The Add Provider catalog must be the UNION of the (live or bundled)
/// upstream registry and the hardcoded `fallbackCatalog` floor: the
/// upstream registry does not carry every agent the app supports
/// (hermes, grok, codewhale, gjc, traecli, ...), and without the union
/// those providers vanish from the sheet whenever a registry fetch
/// succeeds. Registry entries shadow same-id fallback entries.
struct ACPProviderCatalogTests {

    @Test func mergingFallbackExtrasAppendsFallbackOnlyAgents() {
        let registryOnly = [
            KnownACPAgent(
                id: ProviderID(rawValue: "gemini"),
                label: "Gemini CLI",
                summary: "Registry-listed agent.",
                detectExecutable: "gemini",
                command: ["gemini", "--acp"]),
        ]
        let merged = ACPProviderCatalog.mergingFallbackExtras(into: registryOnly)
        let ids = merged.map(\.id.rawValue)
        // The registry entry stays first and is not duplicated...
        #expect(ids.first == "gemini")
        #expect(ids.filter { $0 == "gemini" }.count == 1)
        // ...and the fallback-only floor survives.
        #expect(ids.contains("hermes"))
        #expect(ids.contains("grok"))
        #expect(ids.contains("codewhale"))
    }

    @Test func mergingFallbackExtrasRegistryShadowsSameIdFallbackEntry() {
        // A registry entry with the same id as a fallback entry wins; the
        // fallback shape must not overwrite or duplicate it.
        let registryClaude = [
            KnownACPAgent(
                id: ProviderID(rawValue: "claude-acp"),
                label: "Claude (registry)",
                summary: "Registry-listed shape.",
                detectExecutable: "bun",
                command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"]),
        ]
        let merged = ACPProviderCatalog.mergingFallbackExtras(into: registryClaude)
        let claudeEntries = merged.filter { $0.id.rawValue == "claude-acp" }
        #expect(claudeEntries.count == 1)
        #expect(claudeEntries.first?.label == "Claude (registry)")
    }

    @Test func mergingFallbackExtrasEmptyCatalogFallsBackEntirely() {
        let merged = ACPProviderCatalog.mergingFallbackExtras(into: [])
        #expect(merged.map(\.id.rawValue) == ACPProviderCatalog.fallbackCatalog.map(\.id.rawValue))
    }

    /// The fallback floor carries the two providers the upstream registry
    /// does not list (verified against the live registry, 2026-10-12).
    @Test func fallbackCatalogCoversNonUpstreamAgents() {
        let ids = Set(ACPProviderCatalog.fallbackCatalog.map(\.id.rawValue))
        #expect(ids.contains("gjc"))
        #expect(ids.contains("traecli"))
        // Plain-binary launch shapes — the binary IS the provider.
        let gjc = ACPProviderCatalog.fallbackCatalog.first { $0.id.rawValue == "gjc" }
        #expect(gjc?.command == ["gjc", "acp"])
        #expect(gjc?.detectExecutable == "gjc")
        let traecli = ACPProviderCatalog.fallbackCatalog.first { $0.id.rawValue == "traecli" }
        #expect(traecli?.command == ["traecli", "acp", "serve"])
    }
}
