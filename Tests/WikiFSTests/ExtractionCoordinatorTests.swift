import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFS

/// `ExtractionCoordinator` backend resolution + readiness mapping. Uses an
/// `InMemoryExtractionCredentialStore` and a temp container directory so tests
/// are hermetic (no real Keychain pollution). The backend is driven through
/// `ExtractionConfig` (the single source of truth), matching how
/// `ExtractionSettingsView`'s Save writes it. The coordinator is `@MainActor`.
@MainActor
struct ExtractionCoordinatorTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extraction-coord-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A coordinator over `dir` with an in-memory secret store. `backend` is the
    /// configured backend (written to `ExtractionConfig` before construction).
    private func makeCoordinator(
        backend: ExtractionBackend = .localPdf2md,
        dir: URL,
        seeds: [ExtractionSecret: String] = [:],
        configure: ((inout ExtractionConfig) -> Void)? = nil
    ) throws -> ExtractionCoordinator {
        var cfg = ExtractionConfig()
        cfg.backend = backend
        configure?(&cfg)
        try cfg.save(to: dir)
        return ExtractionCoordinator(
            containerDirectory: dir,
            credentialStore: InMemoryExtractionCredentialStore(seeds: seeds),
            fetcher: FakeHTTPFetcher(body: "x"))
    }

    // MARK: - Backend resolution

    @Test func defaultsToLocalPdf2md() throws {
        let coord = try makeCoordinator(dir: tempDirectory())
        #expect(coord.config.backend == .localPdf2md)
        #expect(coord.current() is LocalPdf2MarkdownExtractor)
    }

    @Test func resolvesAnthropicBackend() throws {
        let coord = try makeCoordinator(backend: .anthropic, dir: tempDirectory(),
                                        seeds: [.anthropicAPIKey: "k"])
        #expect(coord.current() is AnthropicExtractionClient)
    }

    @Test func resolvesDoclingBackend() throws {
        let coord = try makeCoordinator(backend: .doclingServe, dir: tempDirectory())
        #expect(coord.current() is DoclingServeClient)
    }

    @Test func resolvesGeminiBackend() throws {
        let coord = try makeCoordinator(backend: .gemini, dir: tempDirectory(),
                                        seeds: [.geminiAPIKey: "k"])
        #expect(coord.current() is GeminiExtractionClient)
    }

    @Test func geminiNeedsSetupWithoutKey() async throws {
        let coord = try makeCoordinator(backend: .gemini, dir: tempDirectory())
        let r = await coord.current().readiness()
        if case .needsSetup = r { } else { Issue.record("expected .needsSetup") }
    }

    @Test func geminiReadyWithKey() async throws {
        let coord = try makeCoordinator(backend: .gemini, dir: tempDirectory(),
                                        seeds: [.geminiAPIKey: "AIza-x"])
        #expect(await coord.current().readiness() == .ready)
    }

    @Test func geminiClientUsesConfiguredModel() throws {
        let coord = try makeCoordinator(backend: .gemini, dir: tempDirectory(),
                                        seeds: [.geminiAPIKey: "k"]) { cfg in
            cfg.geminiModel = "gemini-3.1-flash-lite"
        }
        #expect((coord.current() as? GeminiExtractionClient)?.model == "gemini-3.1-flash-lite")
    }

    // MARK: - Readiness mapping

    @Test func anthropicNeedsSetupWithoutKey() async throws {
        let coord = try makeCoordinator(backend: .anthropic, dir: tempDirectory())
        let r = await coord.current().readiness()
        if case .needsSetup = r { } else { Issue.record("expected .needsSetup") }
    }

    @Test func anthropicReadyWithKey() async throws {
        let coord = try makeCoordinator(backend: .anthropic, dir: tempDirectory(),
                                        seeds: [.anthropicAPIKey: "sk-ant-x"])
        #expect(await coord.current().readiness() == .ready)
    }

    @Test func doclingNeedsSetupWithoutEndpoint() async throws {
        // No endpoint in config → coordinator passes "" → readiness .needsSetup.
        let coord = try makeCoordinator(backend: .doclingServe, dir: tempDirectory())
        let r = await coord.current().readiness()
        if case .needsSetup = r { } else { Issue.record("expected .needsSetup") }
    }

    @Test func doclingReadyWithEndpoint() async throws {
        let coord = try makeCoordinator(backend: .doclingServe, dir: tempDirectory()) { cfg in
            cfg.doclingServeEndpoint = "http://localhost:5001"
        }
        #expect(await coord.current().readiness() == .ready)
    }

    // MARK: - Config reload + default-model wiring

    @Test func configReloadsAfterSave() async throws {
        let dir = tempDirectory()
        let coord = try makeCoordinator(dir: dir)
        #expect(coord.config.anthropicModel == ExtractionConfig.defaultAnthropicModel)
        var cfg = coord.config
        cfg.anthropicModel = "claude-sonnet-4-6"
        try cfg.save(to: dir)
        #expect(coord.config.anthropicModel == "claude-sonnet-4-6")
    }

    @Test func anthropicClientUsesConfiguredModel() throws {
        let coord = try makeCoordinator(backend: .anthropic, dir: tempDirectory(),
                                        seeds: [.anthropicAPIKey: "k"]) { cfg in
            cfg.anthropicModel = "claude-sonnet-4-6"
        }
        let client = coord.current() as? AnthropicExtractionClient
        #expect(client?.model == "claude-sonnet-4-6")
    }

    @Test func unknownBackendInConfigDegradesToLocal() throws {
        // A corrupt/unknown backend value in the JSON file should never crash a
        // resolve — `ExtractionConfig` degrades it to `.localPdf2md`.
        let dir = tempDirectory()
        let url = dir.appendingPathComponent(ExtractionConfig.fileName, isDirectory: false)
        try Data(#"{"backend":"definitely_not_real"}"#.utf8).write(to: url)
        let coord = ExtractionCoordinator(
            containerDirectory: dir,
            credentialStore: InMemoryExtractionCredentialStore(),
            fetcher: FakeHTTPFetcher(body: "x"))
        #expect(coord.config.backend == .localPdf2md)
        #expect(coord.current() is LocalPdf2MarkdownExtractor)
    }
}
