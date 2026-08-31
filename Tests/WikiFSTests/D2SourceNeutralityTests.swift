import Foundation
import Testing

/// The executable guard behind the "no format-specific production Swift"
/// acceptance criteria: `Sources/` must not contain D2-specific tokens, and
/// `Package.swift` must not reference the D2 package or its generated output.
/// The upstream project name, the format's extension literal, and any
/// `D2`-prefixed type name are all absent from production sources by design;
/// everything D2 lives in `tools/d2/`, `scripts/`, and `Tests/`.
@Suite("D2 source neutrality", .serialized)
struct D2SourceNeutralityTests {
    @Test("production sources contain no D2-specific tokens")
    func productionSourcesAreD2Free() throws {
        let sourcesRoot = D2PackageFixtures.repositoryRoot().appending(path: "Sources")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        let forbidden = ["d2lang", "terrastruct", "RendererPackages/D2", "d2.wasm", "wasm_exec"]
        var scannedFileCount = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedFileCount += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden {
                #expect(
                    !source.localizedCaseInsensitiveContains(token),
                    "\(url.lastPathComponent) must not reference \(token)")
            }
            // The extension literal as a quoted string would annex the format
            // into host matching code; matching is manifest data only.
            #expect(
                !source.contains("\"d2\""),
                "\(url.lastPathComponent) must not embed the quoted d2 extension literal")
            // No D2-prefixed type names (RendererDescriptor types etc. are
            // format-neutral by design).
            for range in source.ranges(of: "D2") {
                let next = source.index(after: range.upperBound)
                if next < source.endIndex, source[next].isUppercase {
                    Issue.record("\(url.lastPathComponent) contains a D2-prefixed identifier")
                }
            }
        }
        #expect(scannedFileCount > 100, "the scan must cover the real source tree")
    }

    @Test("Package.swift stays free of D2 and generated-output references")
    func packageManifestStaysNeutral() throws {
        let package = try String(
            contentsOf: D2PackageFixtures.repositoryRoot().appending(path: "Package.swift"),
            encoding: .utf8)
        #expect(!package.contains("RendererPackages/D2"))
        #expect(!package.contains("tmp/d2-renderer-package"))
        #expect(!package.contains("tools/d2"))
        // The Excalidraw bundled package remains the only vendored renderer.
        #expect(package.contains("RendererPackages/Excalidraw"))
    }
}
