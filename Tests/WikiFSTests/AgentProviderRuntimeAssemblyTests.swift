import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("Cordis agent provider runtime assembly", .serialized, .timeLimit(.minutes(1)))
struct AgentProviderRuntimeAssemblyTests {
    @Test("shuffled registration builds one opaque runtime")
    func shuffledRegistrationBuildsOpaqueRuntime() async throws {
        let handle = try await makeAssembly().assemble(
            registrationOrder: AgentProviderRuntimeAssembly.Component.allCases.shuffled())

        #expect(await handle.services.readiness())
        try await handle.dispose()
    }

    @Test("disposal is idempotent and invalidates outstanding tokens")
    func disposalIsIdempotent() async throws {
        let handle = try await makeAssembly().assemble()
        let preparation = try await handle.services.prepare(.ingest)

        try await handle.dispose()
        try await handle.dispose()
        await #expect(throws: AgentProviderRuntimeError.unavailable) {
            try await handle.services.preparation(
                from: preparation.selection.token,
                stage: .planner)
        }
    }

    @Test("missing registration fails with a typed component error")
    func missingRegistrationFailsTyped() async throws {
        let incomplete = AgentProviderRuntimeAssembly.Component.allCases.filter {
            $0 != .credentialReader
        }

        do {
            _ = try await makeAssembly().assemble(registrationOrder: incomplete)
            Issue.record("Expected provider runtime assembly to fail")
        } catch {
            guard case .activationFailed(let component, _) = error as? AgentProviderRuntimeAssemblyError else {
                Issue.record("Expected a typed provider runtime activation failure, got \(error)")
                return
            }
            #expect(component == AgentProviderRuntimeAssembly.Component.credentialReader.rawValue)
        }
    }

    @Test("catalog discovery resolves command and credential through the runtime")
    func catalogDiscoveryUsesRuntimeDependencies() async throws {
        let calls = CatalogProbeCalls()
        let provider = AgentProvider(
            id: ProviderID(rawValue: "draft"),
            label: "Draft",
            command: ["draft-agent", "--acp"],
            env: ["MODE": "test"])
        let expected = ACPProviderCatalogObservation(
            providerID: provider.id,
            fingerprint: nil,
            models: [CachedModelInfo(
                modelId: ModelID(rawValue: "test-model"),
                name: "Test Model",
                description: nil)],
            currentModelID: ModelID(rawValue: "test-model"),
            thinkingCapability: nil)
        let assembly = AgentProviderRuntimeAssembly(
            readConfiguration: { AgentProvidersConfig(providers: []) },
            resolveCommand: { providers in
                #expect(providers == [provider])
                return [provider.id: ["/resolved/draft-agent", "--acp"]]
            },
            readCredential: { providerID in
                #expect(providerID == provider.id)
                return "secret"
            },
            resolvePermissionPolicy: { _ in .bypass },
            probeCatalog: { receivedProvider, command, credential in
                await calls.record(
                    provider: receivedProvider,
                    command: command,
                    credential: credential)
                return expected
            })
        let handle = try await assembly.assemble(
            registrationOrder: AgentProviderRuntimeAssembly.Component.allCases.shuffled())

        let observation = try await handle.services.discoverCatalog(for: provider)

        #expect(observation == expected)
        #expect(await calls.provider == provider)
        #expect(await calls.command == ["/resolved/draft-agent", "--acp"])
        #expect(await calls.credential == "secret")
        try await handle.dispose()
    }

    @Test("catalog discovery rejects a missing resolved command")
    func catalogDiscoveryRejectsMissingCommand() async throws {
        let handle = try await AgentProviderRuntimeAssembly(
            readConfiguration: { AgentProvidersConfig(providers: []) },
            resolveCommand: { _ in [:] },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass })
            .assemble()
        let provider = AgentProvider(
            id: ProviderID(rawValue: "missing"),
            label: "Missing",
            command: ["missing-agent"])

        await #expect(throws: ACPProviderModelProbeError.notConfigured) {
            try await handle.services.discoverCatalog(for: provider)
        }
        try await handle.dispose()
    }

    @Test("disposed runtime rejects catalog discovery")
    func disposedRuntimeRejectsCatalogDiscovery() async throws {
        let handle = try await makeAssembly().assemble()
        try await handle.dispose()

        await #expect(throws: AgentProviderRuntimeError.unavailable) {
            try await handle.services.discoverCatalog(
                for: AgentProvider(
                    id: ProviderID(rawValue: "test"),
                    label: "Test",
                    command: ["/test/provider"]))
        }
    }

    @Test("assembly source contains only approved headless boundaries")
    func assemblyContainsOnlyApprovedHeadlessBoundaries() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/WikiFSEngine/AgentProviderRuntimeAssembly.swift"),
            encoding: .utf8)
        let requiredServices = [
            "agent-provider.configuration-reader",
            "agent-provider.command-resolver",
            "agent-provider.credential-reader",
            "agent-provider.permission-policy-resolver",
            "agent-provider.backend-factory",
            "agent-provider.catalog-probe",
            "agent-provider.runtime",
            "agent-provider.services",
        ]
        let forbiddenBoundaries = [
            "SwiftUI",
            "WikiStoreModel",
            "SessionManager",
            "QueueStore",
            "NSXPCConnection",
            "WKWebView",
        ]

        for service in requiredServices {
            #expect(source.contains("label: \"\(service)\""))
        }
        for boundary in forbiddenBoundaries {
            #expect(!source.contains(boundary))
        }
    }

    private func makeAssembly() -> AgentProviderRuntimeAssembly {
        AgentProviderRuntimeAssembly(
            readConfiguration: {
                AgentProvidersConfig(providers: [
                    AgentProvider(
                        id: ProviderID(rawValue: "test"),
                        label: "Test",
                        command: ["/test/provider"],
                        isDefault: true),
                ])
            },
            resolveCommand: { providers in
                Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            makeBackend: { _, _, _ in FakeAgentBackend() })
    }
}

private actor CatalogProbeCalls {
    private(set) var provider: AgentProvider?
    private(set) var command: [String]?
    private(set) var credential: String?

    func record(
        provider: AgentProvider,
        command: [String],
        credential: String?
    ) {
        self.provider = provider
        self.command = command
        self.credential = credential
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
