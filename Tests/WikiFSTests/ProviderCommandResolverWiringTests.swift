import Foundation
import Testing

/// Source audit for the shared provider-command resolution (issue #1279
/// AC.9): BOTH production `AgentProviderProcessInput` constructions — the
/// daemon's and the app/renderer's — MUST resolve through
/// `ProviderCommandResolver`, and neither may reintroduce an inline
/// PATH-only resolution body. A drift between the two compositions is what
/// let the shipped bare `bun x` command fail to resolve from the GUI daemon
/// while the catalog path worked.
@Suite("ProviderCommandResolver wiring")
struct ProviderCommandResolverWiringTests {

    /// The two production files that build an `AgentProviderProcessInput`.
    static let productionCompositions: [(file: String, mustContain: [String], mustNotContain: [String])] = [
        (
            "Sources/WikiFSEngine/ProductionPluginCatalogs.swift",
            // The daemon composition resolves through the shared resolver…
            ["ProviderCommandResolver.resolveCommands("],
            // …and the deleted inline PATH-only body must stay gone.
            ["AgentLauncher.resolveCommand(for: provider, searchPath: searchPath)"]
        ),
        (
            "Sources/WikiFS/Renderer/RendererCompositionOwner.swift",
            ["ProviderCommandResolver.resolveCommands("],
            ["AgentLauncher.resolveCommand(for: provider, searchPath: searchPath)"]
        ),
    ]

    @Test func bothProductionCompositionsUseTheSharedResolver() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/WikiFSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        for composition in Self.productionCompositions {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(composition.file),
                encoding: .utf8)
            for marker in composition.mustContain {
                #expect(
                    source.contains(marker),
                    "\(composition.file) must resolve provider commands through the shared resolver (missing: \(marker))")
            }
            for banned in composition.mustNotContain {
                #expect(
                    !source.contains(banned),
                    "\(composition.file) reintroduced an inline PATH-only resolution body (\(banned))")
            }
        }
    }

    @Test func theOnlyBunFallbackImplementationIsRuntimeCommandLocator() throws {
        // The locator fallback must stay implemented in exactly ONE place —
        // `ProviderCommandResolver.defaultLocateBun` — which delegates to
        // `RuntimeCommandLocator`. A second hand-rolled bun lookup would
        // duplicate the shell query / identity probe / timeout contract.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resolverSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/WikiFSEngine/ProviderCommandResolver.swift"),
            encoding: .utf8)
        #expect(resolverSource.contains("RuntimeCommandLocator().locate"),
                "the fallback must delegate to RuntimeCommandLocator")
        // ACPBackend's canonicalization keeps its own validated lookup — the
        // memoized one — and that is the ONLY other permitted site.
        let backendSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/WikiFSEngine/ACPBackend.swift"),
            encoding: .utf8)
        #expect(backendSource.contains("RuntimeCommandLocator().locate"),
                "canonicalization's bun resolution must remain the locator-backed one")
    }
}
