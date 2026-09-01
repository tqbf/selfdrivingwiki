import Foundation
import Testing

@Suite("Excalidraw source neutrality", .serialized)
struct ExcalidrawSourceNeutralityTests {
    @Test("production sources keep Excalidraw policy in manifest data")
    func productionSourcesContainNoActiveExcalidrawPolicy() throws {
        let root = repositoryRoot()
        let sourceRoot = root.appending(path: "Sources")
        let allowedCompatibilityPath = root.appending(path: "Sources/WikiFSTypes/Renderer/RendererMatcher.swift").standardizedFileURL.path
        let forbidden = [
            "BundledRendererPackages",
            "bootstrapBundledRendererPackages",
            "bootstrapBundledPackage",
            "excalidrawResourceURL",
            "DocumentRendererDOMProjector",
            "DocumentRendererDOMOutput",
            "DocumentVectorScene",
            "org.selfdrivingwiki.excalidraw-readonly",
        ]
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden {
                if url.standardizedFileURL.path == allowedCompatibilityPath,
                   token == "BundledRendererPackages" || token == "bootstrapBundledRendererPackages" || token == "bootstrapBundledPackage" {
                    continue
                }
                if url.standardizedFileURL.path == allowedCompatibilityPath,
                   token == "org.selfdrivingwiki.excalidraw-readonly" {
                    continue
                }
                #expect(!source.contains(token), "\(url.path) must not contain \(token)")
            }
            if url.standardizedFileURL.path != allowedCompatibilityPath {
                #expect(!source.contains("boundedJSONArtifact"))
                #expect(!source.localizedCaseInsensitiveContains("excalidraw"))
            }
        }
        #expect(scanned > 100)
    }

    @Test("SwiftPM and build packaging do not copy the Excalidraw package")
    func packageManifestAndBuildScriptDoNotBundleExcalidraw() throws {
        let root = repositoryRoot()
        let package = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let build = try String(contentsOf: root.appending(path: "build.sh"), encoding: .utf8)

        #expect(!package.contains("RendererPackages/Excalidraw"))
        #expect(!build.contains("RendererPackages/Excalidraw"))
        #expect(!build.contains("SPM_APP_RESOURCE_BUNDLE"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
