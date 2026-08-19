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

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
