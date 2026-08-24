import Foundation
import Testing

@Suite("Agent provider composition boundary")
struct AgentProviderCompositionBoundaryTests {
    @Test("app queue and wiki sessions receive one stable facade")
    func appQueueAndWikiSessionsReceiveSameFacade() throws {
        let source = try sourceText("Sources/WikiFS/Window/WikiFSApp.swift")
        let settings = try sourceText("Sources/WikiFS/Settings/AgentsSettingsView.swift")

        #expect(source.contains("let providerServices = MutableAgentProviderServices()"))
        #expect(source.contains("providerServices: providerServices"))
        #expect(source.contains("await providerServices.install(handle.services)"))
        #expect(source.contains("agentProviderRuntimeHandle = handle"))
        #expect(source.contains("providerServices: agentProviderServices"))
        #expect(settings.contains("providerServices.discoverCatalog("))
        #expect(!settings.contains("ACPProviderModelProbe("))
        #expect(!source.contains("CordisContext"))
    }

    @Test("daemon queue and chat receive one stable facade")
    func daemonQueueAndChatReceiveSameFacade() throws {
        let daemon = try sourceText("Sources/wikid/WikiDaemon.swift")
        let queue = try sourceText("Sources/wikid/DaemonQueueIngestionProvider.swift")
        let chat = try sourceText("Sources/wikid/DaemonChatHost.swift")
        let runtime = try sourceText("Sources/wikid/LauncherChatAgentRuntime.swift")

        #expect(daemon.contains("let runtime = try await runtimeServices()"))
        #expect(daemon.contains("providerServices: runtime.provider"))
        #expect(daemon.contains("profileOwner?.services()"))
        #expect(queue.contains("providerServices: providerServices"))
        #expect(chat.contains("providerServices: providerServices"))
        #expect(runtime.contains("providerServices: providerServices"))
        #expect(!daemon.contains("CordisContext"))
    }

    @Test("daemon chat cold start does not load provider configuration directly")
    func daemonChatColdStartUsesPreparedRuntimeContract() throws {
        let controller = try sourceText("Sources/wikid/DaemonChatController.swift")
        let runtime = try sourceText("Sources/wikid/LauncherChatAgentRuntime.swift")

        #expect(!controller.contains("AgentProvidersConfig.load"))
        #expect(controller.contains("runtime.prepareStart("))
        #expect(runtime.contains("providerServices.prepareInteractive("))
        #expect(runtime.contains("preparedInteractiveOperation:"))
    }

    @Test("only provider assembly constructs the runtime")
    func onlyProviderAssemblyConstructsRuntime() throws {
        let root = repositoryRoot()
        let sourceRoot = root.appendingPathComponent("Sources")
        let approvedPath = "WikiFSEngine/AgentProviderRuntimeAssembly.swift"
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil))
        var constructionPaths: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            guard source.contains("AgentProviderRuntime(") else { continue }
            constructionPaths.append(
                fileURL.path.replacingOccurrences(
                    of: sourceRoot.path + "/",
                    with: ""))
        }

        #expect(constructionPaths == [approvedPath])
    }

    @Test("provider assembly excludes app and process owners")
    func providerAssemblyExcludesAppAndProcessOwners() throws {
        let source = try sourceText(
            "Sources/WikiFSEngine/AgentProviderRuntimeAssembly.swift")
        for forbidden in [
            "SwiftUI",
            "WikiStoreModel",
            "SessionManager",
            "QueueStore",
            "NSXPCConnection",
            "WKWebView",
            "AgentLauncher",
        ] {
            #expect(!source.contains(forbidden))
        }
    }

    private func sourceText(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(path),
            encoding: .utf8)
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
