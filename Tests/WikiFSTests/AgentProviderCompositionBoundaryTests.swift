import Foundation
import Testing

@Suite("Agent provider composition boundary")
struct AgentProviderCompositionBoundaryTests {
    @Test("app queue and wiki sessions receive one stable facade")
    func appQueueAndWikiSessionsReceiveSameFacade() throws {
        let source = try sourceText("Sources/WikiFS/Window/WikiFSApp.swift")

        #expect(source.contains("let providerServices = MutableAgentProviderServices()"))
        #expect(source.contains("providerServices: providerServices"))
        #expect(source.contains("await providerServices.install(handle.services)"))
        #expect(source.contains("agentProviderRuntimeHandle = handle"))
        #expect(!source.contains("CordisContext"))
    }

    @Test("daemon queue and chat receive one stable facade")
    func daemonQueueAndChatReceiveSameFacade() throws {
        let daemon = try sourceText("Sources/wikid/WikiDaemon.swift")
        let queue = try sourceText("Sources/wikid/DaemonQueueIngestionProvider.swift")
        let chat = try sourceText("Sources/wikid/DaemonChatHost.swift")
        let runtime = try sourceText("Sources/wikid/LauncherChatAgentRuntime.swift")

        #expect(daemon.contains("MutableAgentProviderServices()"))
        #expect(daemon.contains("await providerServices.install(handle.services)"))
        #expect(daemon.contains("providerServices: agentProviderServices"))
        #expect(queue.contains("providerServices: providerServices"))
        #expect(chat.contains("providerServices: providerServices"))
        #expect(runtime.contains("providerServices: providerServices"))
        #expect(!daemon.contains("CordisContext"))
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
