import Foundation
import Testing

@Suite("Agent provider composition boundary")
struct AgentProviderCompositionBoundaryTests {
    @Test("provider consumers do not assemble runtimes or receive Cordis contexts")
    func providerConsumersDoNotOwnAssembly() throws {
        for path in [
            "Sources/WikiFS/Window/WikiFSApp.swift",
            "Sources/wikid/WikiDaemon.swift",
            "Sources/wikid/DaemonQueueIngestionProvider.swift",
            "Sources/wikid/DaemonChatHost.swift",
            "Sources/wikid/LauncherChatAgentRuntime.swift",
        ] {
            let source = try sourceText(path)
            #expect(!source.contains("AgentProviderRuntimeFactory("))
            #expect(!source.contains("CordisContext"))
        }
    }

    @Test("only provider assembly constructs the runtime")
    func onlyProviderAssemblyConstructsRuntime() throws {
        let root = repositoryRoot()
        let sourceRoot = root.appendingPathComponent("Sources")
        let approvedPath = "WikiFSEngine/AgentProviderRuntimeFactory.swift"
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
            "Sources/WikiFSEngine/AgentProviderRuntimeFactory.swift")
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
