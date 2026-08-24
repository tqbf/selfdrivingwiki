import Foundation
import Testing

@Suite("Renderer capability boundary policy")
struct RendererCapabilityBoundaryPolicyTests {
    @Test("built-in factory inputs expose narrow capabilities only")
    func factoryInputsExposeNarrowCapabilitiesOnly() throws {
        let source = try read("Sources/WikiFS/Renderer/BuiltInRendererFactoryMap.swift")
        let inputs = try #require(source.split(separator: "struct BuiltInRendererFactoryInputs", maxSplits: 1).last)

        for forbidden in [
            "WikiStoreModel", "WikiStore", "CordisContext", "RendererServices",
            "Agent", "LLM", "URLSession", "FileManager", "NSWorkspace", "Process",
        ] {
            #expect(!inputs.contains(forbidden), "Shared built-in inputs must not expose \(forbidden)")
        }
        #expect(inputs.contains("mermaidProjection: AnyView?"))
        #expect(inputs.contains("jsonCanvasHostAction:"))
    }

    @Test("installed package protocol version one remains closed")
    func v1CapabilitySetIsClosed() throws {
        let bridge = try read("Sources/WikiFSCore/Renderer/RendererBridgeContracts.swift")
        let csp = try read("Sources/WikiFSCore/Renderer/RendererContentSecurityPolicy.swift")

        #expect(bridge.contains("case inputRead = \"input.read\""))
        #expect(!bridge.contains("case fetch"))
        #expect(!bridge.contains("case write"))
        #expect(!bridge.contains("case execute"))
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("connect-src 'none'"))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: rendererPolicyRepositoryRoot().appendingPathComponent(path), encoding: .utf8)
    }
}

private func rendererPolicyRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
