import Foundation
import Testing

@Suite("Agent summary provider boundary")
struct AgentSummaryProviderBoundaryTests {
    @Test("summary owners do not construct providers or backends directly")
    func summaryOwnersDoNotConstructProvidersOrBackendsDirectly() throws {
        let root = repositoryRoot()
        let paths = [
            "Sources/WikiFSEngine/AgentOperationRunner.swift",
            "Sources/wikid/DaemonChatHost.swift",
        ]
        let forbidden = [
            "AgentProvidersConfig.load",
            "ACPCredentialStore",
            "KeychainACPCredentialStore",
            "PathPreflight.loginShellPATH",
            "AgentBackendFactory.makeBackend",
            "MessageSummarizer.resolveProfile",
        ]

        for path in paths {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8)
            let summaryStart = try #require(source.range(
                of: "summarizePendingMessages(",
                options: .backwards))
            let summaryTail = source[summaryStart.lowerBound...]
            let summaryEnd = summaryTail.range(of: "\n    // MARK:")?.lowerBound
                ?? summaryTail.endIndex
            let summarySection = String(summaryTail[..<summaryEnd])
            for symbol in forbidden {
                #expect(!summarySection.contains(symbol), "\(path) summary path bypasses provider services with \(symbol)")
            }
        }
    }

    @Test("summary owners preserve default truncation when provider services are unavailable")
    func summaryOwnersPreserveUnavailableFallback() throws {
        let root = repositoryRoot()
        let paths = [
            "Sources/WikiFSEngine/AgentOperationRunner.swift",
            "Sources/wikid/DaemonChatHost.swift",
        ]

        for path in paths {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8)
            #expect(source.contains("catch AgentProviderRuntimeError.unavailable"))
            #expect(source.contains("writeDefaultSummaries("))
        }
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
