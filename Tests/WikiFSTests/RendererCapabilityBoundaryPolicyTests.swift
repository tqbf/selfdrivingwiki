import Foundation
import Testing
@testable import WikiFSCore

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
        #expect(inputs.contains("mediaTarget: EmbedTarget?"))
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
        #expect(csp.contains("connect-src \\(packageSource)"))
        #expect(!csp.contains("connect-src 'none'"))
    }

    @Test("package CSP pins WASM compilation without network origins")
    func packageCSPPinsWASMWithoutNetworkOrigins() throws {
        let csp = try read("Sources/WikiFSCore/Renderer/RendererContentSecurityPolicy.swift")

        // Golden literal: the assembled headerValue, pinned by identity.
        let expected =
            "default-src 'none'; "
                + "script-src renderer-package: 'wasm-unsafe-eval'; "
                + "style-src renderer-package:; "
                + "connect-src renderer-package:; "
                + "img-src renderer-package:; "
                + "media-src renderer-package:; "
                + "font-src renderer-package:; "
                + "frame-src 'none'; "
                + "worker-src 'none'; "
                + "object-src 'none'; "
                + "form-action 'none'; "
                + "base-uri 'none'"
        #expect(RendererContentSecurityPolicy.headerValue == expected)

        // WASM compilation is permitted without JS eval.
        #expect(csp.contains("'wasm-unsafe-eval'"))
        // Workers stay forbidden.
        #expect(csp.contains("worker-src 'none'"))
        // No network or opaque origin may appear as a source in any directive.
        for forbiddenOrigin in ["http:", "https:", "data:", "blob:"] {
            #expect(!csp.contains(forbiddenOrigin), "CSP must not contain \(forbiddenOrigin)")
        }
    }

    @Test("package scheme MIME table stays closed and serves font assets")
    func packageSchemeMIMETableStaysClosed() throws {
        let serve = { path in RendererPackageMIMEType.mimeType(for: try RendererRelativePath(validating: path)) }
        // Font assets are a normal static class; TTF joins the existing woff
        // and woff2 entries so a package can carry text-measured fonts.
        #expect(try serve("fonts/SourceSansPro-Regular.ttf")?.rawValue == "font/ttf")
        #expect(try serve("styles.woff")?.rawValue == "font/woff")
        #expect(try serve("module.wasm")?.rawValue == "application/wasm")
        #expect(try serve("index.html")?.rawValue == "text/html")
        #expect(try serve("d2-viewer.js")?.rawValue == "text/javascript")
        // Unknown extensions fail closed.
        #expect(try serve("asset.bin") == nil)
        #expect(try serve("archive.exe") == nil)
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
