#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("Cordis extraction runtime assembly", .serialized, .timeLimit(.minutes(1)))
struct ExtractionRuntimeFactoryTests {
    @Test("shuffled registration builds a ready runtime")
    func shuffledRegistrationBuildsReadyRuntime() async throws {
        let handle = try await makeAssembly(
            state: ExtractionRuntimeTestState(configuration: ExtractionConfig(backend: .acp)))
            .assemble(registrationOrder: ExtractionRuntimeFactory.Component.allCases.shuffled())
        let preparation = try await handle.services.prepare()

        #expect(preparation.backend == .acp)
        #expect(preparation.extractor.displayName == "local-1")
        try await handle.dispose()
    }

    @Test("missing registration fails with a typed component error")
    func missingRegistrationFailsTyped() async throws {
        let incomplete = ExtractionRuntimeFactory.Component.allCases.filter {
            $0 != .credentialReader
        }

        do {
            _ = try await makeAssembly().assemble(registrationOrder: incomplete)
            Issue.record("Expected extraction runtime assembly to fail")
        } catch {
            guard case .activationFailed(let component, _) = error as? ExtractionRuntimeFactoryError else {
                Issue.record("Expected a typed extraction activation failure, got \(error)")
                return
            }
            #expect(component == ExtractionRuntimeFactory.Component.credentialReader.rawValue)
        }
    }

    @Test("preparations freeze one configuration and later calls read updates")
    func preparationFreezesConfiguration() async throws {
        let state = ExtractionRuntimeTestState(configuration: ExtractionConfig(backend: .anthropic))
        let handle = try await makeAssembly(state: state).assemble()
        let first = try await handle.services.prepare()

        state.updateConfiguration { configuration in
            configuration.backend = .gemini
            configuration.geminiModel = "gemini-next"
        }
        let second = try await handle.services.prepare()

        #expect(first.backend == .anthropic)
        #expect(first.modelVersion == ExtractionConfig.defaultAnthropicModel)
        #expect(first.extractor is AnthropicExtractionClient)
        #expect(second.backend == .gemini)
        #expect(second.modelVersion == "gemini-next")
        #expect(second.extractor is GeminiExtractionClient)
        try await handle.dispose()
    }

    @Test("backend override builds and reports the overridden backend")
    func backendOverrideBuildsAndReportsTheOverriddenBackend() async throws {
        let state = ExtractionRuntimeTestState(configuration: ExtractionConfig(backend: .localPdf2md))
        state.updateConfiguration { $0.anthropicModel = "claude-override" }
        let handle = try await makeAssembly(state: state).assemble()

        let preparation = try await handle.services.prepare(backendOverride: .anthropic)

        #expect(preparation.backend == .anthropic)
        #expect(preparation.modelVersion == "claude-override")
        #expect((preparation.extractor as? AnthropicExtractionClient)?.model == "claude-override")
        try await handle.dispose()
    }

    @Test("each preparation constructs a distinct ACP extractor")
    func concurrentPreparationsReturnDistinctExtractorInstances() async throws {
        let state = ExtractionRuntimeTestState(configuration: ExtractionConfig(backend: .acp))
        let handle = try await makeAssembly(state: state).assemble()

        async let first = handle.services.prepare()
        async let second = handle.services.prepare()
        let preparations = try await [first, second]

        #expect(Set(preparations.map(\.extractor.displayName)).count == 2)
        try await handle.dispose()
    }

    @Test("disposal is idempotent and rejects new preparations")
    func disposalIsIdempotentAndInvalidatesService() async throws {
        let handle = try await makeAssembly().assemble()

        try await handle.dispose()
        try await handle.dispose()
        await #expect(throws: ExtractionServicesError.unavailable) {
            try await handle.services.prepare()
        }
    }

    @Test("assembly contains fixed labels and approved headless boundaries")
    func serviceLabelsAreComplete() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/WikiFSEngine/ExtractionRuntimeFactory.swift"),
            encoding: .utf8)
        let labels = [
            "extraction.configuration-reader",
            "extraction.credential-reader",
            "extraction.acp-resolver",
            "extraction.http-fetcher",
            "extraction.backend-resolver",
            "extraction.runtime",
            "extraction.services",
        ]
        let forbidden = [
            "SwiftUI", "AppKit", "WebKit", "WikiStoreModel", "ProfileWikiSession",
            "SessionManager", "QueueStore", "NSXPCConnection",
        ]

        for label in labels { #expect(source.contains("label: \"\(label)\"")) }
        for boundary in forbidden { #expect(!source.contains(boundary)) }
    }

    private func makeAssembly(
        state: ExtractionRuntimeTestState = ExtractionRuntimeTestState(
            configuration: ExtractionConfig())
    ) -> ExtractionRuntimeFactory {
        ExtractionRuntimeFactory(
            readConfiguration: { state.configuration },
            readCredential: { _ in "test-secret" },
            resolveACP: { configuration in
                guard configuration.backend == .acp else { return nil }
                return ExtractionRuntimeExtractor(name: state.nextExtractorName())
            },
            httpFetcher: ExtractionRuntimeHTTPFetcher())
    }
}

private final class ExtractionRuntimeTestState: Sendable {
    private struct State: Sendable {
        var configuration: ExtractionConfig
        var extractorCount = 0
    }

    private let state: Mutex<State>

    init(configuration: ExtractionConfig) {
        state = Mutex(State(configuration: configuration))
    }

    var configuration: ExtractionConfig {
        state.withLock { $0.configuration }
    }

    func updateConfiguration(_ update: (inout ExtractionConfig) -> Void) {
        state.withLock { update(&$0.configuration) }
    }

    func nextExtractorName() -> String {
        state.withLock {
            $0.extractorCount += 1
            return "local-\($0.extractorCount)"
        }
    }
}

private struct ExtractionRuntimeExtractor: MarkdownExtractor {
    let name: String
    var displayName: String { name }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { name }
}

private struct ExtractionRuntimeHTTPFetcher: HTTPRequestFetcher {
    func fetch(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        (Data(), 200)
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
#endif
