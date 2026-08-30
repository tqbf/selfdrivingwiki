#if os(macOS)
import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// `ExtractionCoordinator` backend resolution + readiness mapping over the
/// test-only legacy seam. Uses an `InMemoryExtractionCredentialStore` and a
/// temp container directory so tests are hermetic (no real Keychain
/// pollution). #1178 removed the retired `ExtractionConfig.backend` fallback,
/// so the seam receives its backend explicitly through `backendOverride` and
/// fails closed when a caller supplies none. The coordinator is `@MainActor`.
@MainActor
struct ExtractionCoordinatorTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extraction-coord-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A coordinator over `dir` with an in-memory secret store. The config file
    /// holds only persisted settings (models, endpoints, provider ids); the
    /// backend itself is passed explicitly per `prepare(backendOverride:)` call.
    private func makeCoordinator(
        dir: URL,
        seeds: [ExtractionSecret: String] = [:],
        configure: ((inout ExtractionConfig) -> Void)? = nil
    ) throws -> ExtractionCoordinator {
        var cfg = ExtractionConfig()
        configure?(&cfg)
        try cfg.save(to: dir)
        return ExtractionCoordinator(
            containerDirectory: dir,
            credentialStore: InMemoryExtractionCredentialStore(seeds: seeds),
            fetcher: FakeHTTPFetcher(body: "x"),
            localExtractorFactory: { CoordinatorStubExtractor() })
    }

    // MARK: - Backend resolution

    @Test func localPdf2mdOverrideResolvesLocalExtractor() async throws {
        let coord = try makeCoordinator(dir: tempDirectory())
        let preparation = try await coord.prepare(backendOverride: .localPdf2md)
        #expect(preparation.backend == .localPdf2md)
        #expect(preparation.extractor is CoordinatorStubExtractor)
    }

    /// #1178: with the retired `ExtractionConfig.backend` fallback gone, a
    /// prepare call without an explicit backend fails closed instead of
    /// inventing a default. Production resolves defaults through the route
    /// records; this legacy seam does not.
    @Test func missingOverrideFailsClosed() async throws {
        let coord = try makeCoordinator(dir: tempDirectory())
        await #expect(throws: ExtractionServicesError.unavailable) {
            try await coord.prepare()
        }
    }

    @Test func resolvesAnthropicBackend() async throws {
        let coord = try makeCoordinator(dir: tempDirectory(),
                                        seeds: [.anthropicAPIKey: "k"])
        #expect((try await coord.prepare(backendOverride: .anthropic)).extractor is AnthropicExtractionClient)
    }

    @Test func resolvesGeminiBackend() async throws {
        let coord = try makeCoordinator(dir: tempDirectory(),
                                        seeds: [.geminiAPIKey: "k"])
        #expect((try await coord.prepare(backendOverride: .gemini)).extractor is GeminiExtractionClient)
    }

    @Test func geminiNeedsSetupWithoutKey() async throws {
        let coord = try makeCoordinator(dir: tempDirectory())
        let r = await (try await coord.prepare(backendOverride: .gemini)).extractor.readiness()
        if case .needsSetup = r { } else { Issue.record("expected .needsSetup") }
    }

    @Test func geminiReadyWithKey() async throws {
        let coord = try makeCoordinator(dir: tempDirectory(),
                                        seeds: [.geminiAPIKey: "AIza-x"])
        #expect(await (try await coord.prepare(backendOverride: .gemini)).extractor.readiness() == .ready)
    }

    @Test func geminiClientUsesConfiguredModel() async throws {
        let coord = try makeCoordinator(dir: tempDirectory(),
                                        seeds: [.geminiAPIKey: "k"]) { cfg in
            cfg.geminiModel = "gemini-3.1-flash-lite"
        }
        #expect(((try await coord.prepare(backendOverride: .gemini)).extractor as? GeminiExtractionClient)?.model == "gemini-3.1-flash-lite")
    }

    // MARK: - Readiness mapping

    @Test func anthropicNeedsSetupWithoutKey() async throws {
        let coord = try makeCoordinator(dir: tempDirectory())
        let r = await (try await coord.prepare(backendOverride: .anthropic)).extractor.readiness()
        if case .needsSetup = r { } else { Issue.record("expected .needsSetup") }
    }

    @Test func anthropicReadyWithKey() async throws {
        let coord = try makeCoordinator(dir: tempDirectory(),
                                        seeds: [.anthropicAPIKey: "sk-ant-x"])
        #expect(await (try await coord.prepare(backendOverride: .anthropic)).extractor.readiness() == .ready)
    }

    /// #1159: the legacy seam keeps no direct Docling execution path — Docling
    /// runs through the reviewed package, so an explicit `.doclingServe`
    /// override fails closed here regardless of the configured endpoint.
    @Test func doclingServeOverrideFailsClosed() async throws {
        let coord = try makeCoordinator(dir: tempDirectory()) { cfg in
            cfg.doclingServeEndpoint = "http://localhost:5001"
        }
        await #expect(throws: ExtractionServicesError.unavailable) {
            try await coord.prepare(backendOverride: .doclingServe)
        }
    }

    // MARK: - Config reload + default-model wiring

    @Test func configReloadsAfterSave() async throws {
        let dir = tempDirectory()
        let coord = try makeCoordinator(dir: dir)
        #expect((try await coord.prepare(backendOverride: .anthropic)).modelVersion == ExtractionConfig.defaultAnthropicModel)
        var cfg = ExtractionConfig.load(from: dir)
        cfg.anthropicModel = "claude-sonnet-4-6"
        try cfg.save(to: dir)
        #expect((try await coord.prepare(backendOverride: .anthropic)).modelVersion == "claude-sonnet-4-6")
    }

    @Test func anthropicClientUsesConfiguredModel() async throws {
        let coord = try makeCoordinator(dir: tempDirectory(),
                                        seeds: [.anthropicAPIKey: "k"]) { cfg in
            cfg.anthropicModel = "claude-sonnet-4-6"
        }
        let client = (try await coord.prepare(backendOverride: .anthropic)).extractor as? AnthropicExtractionClient
        #expect(client?.model == "claude-sonnet-4-6")
    }

    // MARK: - ACP backend

    /// An absent provider is an unavailable selection: with `.acp` requested
    /// explicitly but no resolvable provider command, the seam fails closed
    /// instead of substituting the local extractor.
    @Test func acpOverrideWithoutResolvableProviderFailsClosed() async throws {
        let dir = tempDirectory()
        var cfg = ExtractionConfig()
        cfg.acpProviderId = "claude-acp"
        try cfg.save(to: dir)

        // Seed agent-providers.json so the provider exists + is enabled, but
        // its command cannot be resolved (the path does not exist).
        let providersConfig = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude-acp"), label: "Claude", command: ["/nonexistent/claude"], enabled: true, isDefault: true)
        ])
        try providersConfig.save(to: dir)

        let coord = ExtractionCoordinator(
            containerDirectory: dir,
            credentialStore: InMemoryExtractionCredentialStore(),
            acpCredentialStore: InMemoryACPCredentialStore(),
            fetcher: FakeHTTPFetcher(body: "x"),
            localExtractorFactory: { CoordinatorStubExtractor() })
        await #expect(throws: ExtractionServicesError.unavailable) {
            try await coord.prepare(backendOverride: .acp)
        }
    }
}

private struct CoordinatorStubExtractor: MarkdownExtractor {
    var displayName: String { "coordinator-stub" }

    func readiness() async -> ExtractionReadiness { .ready }

    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        "stub"
    }
}
#endif
