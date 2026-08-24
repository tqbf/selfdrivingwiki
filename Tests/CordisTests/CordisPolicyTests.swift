import Cordis
import Foundation
import Testing

@Suite("Cordis source policy", .timeLimit(.minutes(1)))
struct CordisSourcePolicyTests {
    @Test("target graph is Foundation-only")
    func foundationOnlyTargetGraph() throws {
        let root = repositoryRoot()
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let expected = """
        .target(
                    name: "Cordis",
                    path: "Sources/Cordis",
                    swiftSettings: strictSwiftSettings
                )
        """
        #expect(package.contains(expected))
    }

    @Test("source has no unchecked Sendable or detached tasks")
    func noUncheckedSendableOrDetachedTasks() throws {
        let root = repositoryRoot()
        let sourceURL = root.appendingPathComponent("Sources/Cordis", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")

        let uncheckedSendable = "@unchecked" + " Sendable"
        let detachedTask = "Task." + "detached"
        #expect(!source.contains(uncheckedSendable))
        #expect(!source.contains(detachedTask))
        #expect(!source.contains("import SwiftUI"))
        #expect(!source.contains("import AppKit"))
        #expect(!source.contains("import GRDB"))
        #expect(!source.contains("import WikiFS"))
    }

    @Test("Cordis remains outside UI, model, session, and daemon files")
    func forbiddenProductionFilesDoNotImportCordis() throws {
        let root = repositoryRoot()
        let forbidden = [
            "Sources/WikiFS/Window",
            "Sources/WikiFSCore/WikiStoreModel.swift",
            "Sources/WikiFSEngine/SessionManager.swift",
            "Sources/wikid",
        ]
        for relativePath in forbidden {
            let url = root.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            let files: [URL]
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            } else {
                files = [url]
            }
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(!source.contains("import Cordis"), "Forbidden Cordis import in \(file.path)")
            }
        }
    }

    @Test("Cordis context APIs stay in approved engine assemblies")
    func cordisContextAPIsStayInApprovedAssemblies() throws {
        let root = repositoryRoot()
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let approved = Set([
            "Sources/WikiFSEngine/AgentProviderRuntimeFactory.swift",
            "Sources/WikiFSEngine/QueueRuntimeFactory.swift",
            "Sources/WikiFSEngine/ExtractionRuntimeFactory.swift",
            "Sources/WikiFSEngine/SearchRuntimeCompositionFactory.swift",
            "Sources/WikiFSEngine/SearchRuntimeFactory.swift",
            "Sources/WikiFSEngine/ProductionPluginCatalogs.swift",
            "Sources/WikiFSEngine/ProfileWikiSession.swift",
            "Sources/WikiFSEngine/DaemonTransportRuntimeFactory.swift",
            "Sources/WikiFSEngine/SearchRuntimeRegistry.swift",
            // Phase 4.1 store-domain composition boundary: typed keys and the
            // plugin that owns store construction plus reversible bus bridging.
            "Sources/WikiFSEngine/StoreServiceKeys.swift",
            "Sources/WikiFSEngine/StorePlugin.swift",
            // Phase 4.2 session-log composition boundary: append-only event
            // facade and the reversible chat-persistence projection.
            "Sources/WikiFSEngine/SessionServiceKeys.swift",
            "Sources/WikiFSEngine/SessionsPlugin.swift",
            // Phase 4.3 model-adapter composition boundary: actor-backed route
            // registry and reversible ACP adapter registration.
            "Sources/WikiFSEngine/LlmServiceKeys.swift",
            "Sources/WikiFSEngine/LlmPlugin.swift",
            // Phase 4.4 tool composition boundary: scoped registry, guarded
            // execution waterfalls, and reversible tool registration.
            "Sources/WikiFSEngine/ToolServiceKeys.swift",
            "Sources/WikiFSEngine/ToolsPlugin.swift",
            // Phase 4.5 prompt composition boundary: ordered section registry
            // and base prompt resource contribution.
            "Sources/WikiFSEngine/PromptServiceKeys.swift",
            "Sources/WikiFSEngine/PromptPlugin.swift",
            // Phase 4.6 agent-loop composition boundary: durable turn/step
            // events plus pre-step and request waterfalls.
            "Sources/WikiFSEngine/AgentLoopServiceKeys.swift",
            "Sources/WikiFSEngine/AgentLoopPlugin.swift",
            // Phase 4.7 extraction composition boundary: typed lazy adapter
            // registry and reversible backend registrations.
            "Sources/WikiFSEngine/ExtractionServiceKeys.swift",
            "Sources/WikiFSEngine/ExtractionPlugins.swift",
            // Phase 4.8 search composition boundary: typed provider registry
            // plus lazy Tantivy and embeddings adapter registrations.
            "Sources/WikiFSEngine/SearchServiceKeys.swift",
            "Sources/WikiFSEngine/SearchPlugins.swift",
            // Phases 4.9–4.10 renderer and transport composition boundaries:
            // typed lazy registries with reversible adapter registrations.
            "Sources/WikiFSEngine/RendererServiceKeys.swift",
            "Sources/WikiFSEngine/RendererPlugins.swift",
            "Sources/WikiFSEngine/TransportServiceKeys.swift",
            "Sources/WikiFSEngine/TransportPlugins.swift",
            // Phase 4.11 integration composition boundary: one lazy capability
            // registry with reversible Zotero, podcast, and URL-fetch adapters.
            "Sources/WikiFSEngine/IntegrationServiceKeys.swift",
            "Sources/WikiFSEngine/IntegrationPlugins.swift",
            "Sources/WikiCtlCore/CLITantivyLegResolver.swift",
            "Sources/WikiCtlCore/CLIPluginCatalog.swift",
            // Phase 5a diagnostic composition boundary: resolves loader data
            // without exposing a Cordis context to command implementations.
            "Sources/WikiCtlCore/DumpConfigCommand.swift",
            "Sources/WikiFS/Renderer/RendererRuntimeFactory.swift",
        ])
        let forbiddenPatterns = [
            "import Cordis", "CordisContext", "ActivationContext", "ServiceKey<",
        ]
        let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }

        for file in files {
            let relative = file.path.replacingOccurrences(
                of: root.path + "/",
                with: "")
            guard !approved.contains(relative),
                  !relative.hasPrefix("Sources/Cordis/"),
                  !relative.hasPrefix("Sources/CordisLoader/") else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for pattern in forbiddenPatterns {
                let containsForbiddenAPI: Bool
                if pattern == "ActivationContext" {
                    let expression = try NSRegularExpression(pattern: #"\bActivationContext\b"#)
                    containsForbiddenAPI = expression.firstMatch(
                        in: source,
                        range: NSRange(source.startIndex..., in: source)) != nil
                } else {
                    containsForbiddenAPI = source.contains(pattern)
                }
                #expect(
                    !containsForbiddenAPI,
                    "Forbidden Cordis API \(pattern) in \(relative)")
            }
        }
    }

    @Test("tests have no timing sleeps, polling, or semaphores")
    func testsUseDeterministicSynchronization() throws {
        let root = repositoryRoot()
        let testsURL = root.appendingPathComponent("Tests/CordisTests", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: testsURL,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")

        let taskSleep = "Task." + "sleep"
        let threadSleep = "Thread." + "sleep"
        let semaphore = "Dispatch" + "Semaphore"
        let bareContinuation = "withChecked" + "Continuation"
        let pollingLoop = "while" + " true"
        #expect(!source.contains(taskSleep))
        #expect(!source.contains(threadSleep))
        #expect(!source.contains(semaphore))
        #expect(!source.contains(bareContinuation))
        #expect(!source.contains(pollingLoop))
    }

    @Test("settlement returns for every stable transition")
    func awaitSettledReturnsForStableTransitions() async throws {
        let missingKey = ServiceKey<String>(label: "missing")
        let context = CordisContext()
        let pending = try await context.register(try ComponentDefinition(
            label: "pending",
            dependencies: [ServiceDependency(missingKey)]) { _ in })
        let active = try await context.register(try ComponentDefinition(label: "active") { _ in })
        let failed = try await context.register(try ComponentDefinition(label: "failed") { _ in
            throw CordisFailure("failure")
        })

        #expect(try await pending.awaitSettled().kind == .pending)
        #expect(try await active.awaitSettled().kind == .active)
        #expect(try await failed.awaitSettled().kind == .failed)
        try await active.dispose()
        #expect(try await active.awaitSettled().kind == .disposed)
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
