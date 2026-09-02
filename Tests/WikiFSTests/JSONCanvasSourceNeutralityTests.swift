import Foundation
import Testing

/// Repository contract for the JSON Canvas renderer-package migration.
///
/// JSON Canvas is now a reviewed, installed Web package only
/// (`RendererPackages/JSONCanvas`). Production Swift must not contain renderer,
/// decoder, view, built-in registration, fence, presentation, or navigation
/// policy for the format. Only narrow, data-only ingestion/MIME allowlist
/// mentions may name the format.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct JSONCanvasSourceNeutralityTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Production Swift paths allowed to mention the format as pure data or
    /// documentation: MIME detection, bounded artifact matching, extension
    /// materialization, and the built-in table's package-claim comment. These
    /// never branch presentation or routing on the format name.
    private static let allowedDataOnlyPaths: Set<String> = [
        "Sources/WikiFSCore/Sources/ContentSniff.swift",
        "Sources/WikiFSCore/Sources/FormatMaterializer.swift",
        "Sources/WikiFS/Renderer/BuiltInRendererDescriptors.swift",
        "Sources/WikiFSTypes/MimeType.swift",
        "Sources/WikiFSTypes/Renderer/RendererMatcher.swift",
    ]

    /// Symbols that must not appear in production Swift (native decoder/core,
    /// native view, attachment factory, host-action router, or format-scoped
    /// presentation).
    private static let forbiddenNativeSymbols = [
        "JSONCanvasDocument",
        "JSONCanvasRendererView",
        "JSONCanvasViewportState",
        "NativeJSONCanvasAttachmentFactory",
        "JSONCanvasHostAction",
        "JSONCanvasHostActionRouter",
        "JSONCanvasLimits",
        "JSONCanvasNavigationTarget",
    ]

    /// Fence alias and registration spellings that must not exist in host Swift.
    private static let forbiddenAliasTokens = [
        "fenceAlias(\"jsoncanvas\")",
        "BuiltInRendererID.jsonCanvas",
    ]

    @Test("production sources contain no JSON Canvas renderer policy")
    func productionSourcesContainNoJSONCanvasPolicy() throws {
        let sourcesRoot = Self.repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sourcesRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .map { sourcesRoot.appendingPathComponent($0) }

        var violations: [String] = []
        for url in files {
            let relative = "Sources/" + url.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            if Self.allowedDataOnlyPaths.contains(relative) { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for symbol in Self.forbiddenNativeSymbols where source.contains(symbol) {
                violations.append("\(relative): native symbol \(symbol)")
            }
            for token in Self.forbiddenAliasTokens where source.contains(token) {
                violations.append("\(relative): alias/policy token \(token)")
            }
            if source.localizedCaseInsensitiveContains("jsoncanvas") || source.localizedCaseInsensitiveContains("json canvas") {
                violations.append("\(relative): JSON Canvas mention outside the data-only allowlist")
            }
        }
        #expect(violations.isEmpty, "JSON Canvas policy found in production Swift:\n\(violations.joined(separator: "\n"))")
    }

    @Test("SwiftPM and build scripts do not bundle the JSON Canvas package")
    func packageManifestAndBuildScriptDoNotBundleJSONCanvas() throws {
        let buildConfig: [(String, URL)] = [
            ("Package.swift", Self.repositoryRoot.appendingPathComponent("Package.swift")),
            ("build.sh", Self.repositoryRoot.appendingPathComponent("build.sh")),
            ("Makefile", Self.repositoryRoot.appendingPathComponent("Makefile")),
        ]
        for (name, url) in buildConfig where FileManager.default.fileExists(atPath: url.path) {
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(source.contains("RendererPackages/JSONCanvas") == false,
                    "\(name) must not copy or name the JSON Canvas package")
        }
        // The package exists only as a reviewed source tree for manual import.
        let packageDir = Self.repositoryRoot.appendingPathComponent("RendererPackages/JSONCanvas", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: packageDir.path))
        #expect(FileManager.default.fileExists(atPath: packageDir.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: packageDir.appendingPathComponent("viewer.js").path))
    }
}
