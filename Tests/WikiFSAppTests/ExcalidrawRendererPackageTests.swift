#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes

@Suite("Excalidraw installed renderer package", .serialized, .timeLimit(.minutes(1)))
struct ExcalidrawRendererPackageTests {
    @Test("reviewed package validates and its descriptor matches only Excalidraw artifacts")
    func reviewedPackageValidatesAndRegistersTypedArtifact() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let validated = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(validated.manifest.descriptors.only)
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [descriptor])
        let validInput = try RendererMatchInput(
            mimeType: try .init(validating: "application/json"),
            fileExtension: try .init(validating: "excalidraw"),
            sniffedBytes: Data("{\"type\":\"excalidraw\",\"version\":2,\"elements\":[]}".utf8),
            artifactKind: .source)
        let malformedInput = try RendererMatchInput(
            mimeType: try .init(validating: "application/json"),
            fileExtension: try .init(validating: "excalidraw"),
            sniffedBytes: Data("{\"type\":\"excalidraw\",\"version\":1,\"elements\":[]}".utf8),
            artifactKind: .source)

        #expect(snapshot.matching(validInput).map(\.reference) == [descriptor.reference])
        #expect(snapshot.matching(malformedInput).isEmpty)
    }

    @Test("package declares only its read-only input and trusted external-link capabilities")
    func packageDeclaresReadOnlyCapabilities() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)

        #expect(descriptor.capabilities == [.inputRead, .externalLink])
        #expect(descriptor.linkPolicy == .userActivatedExternal)
        #expect(descriptor.presentations == [.web])
        #expect(descriptor.sizeLimits.maximumInputByteCount <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "LICENSE.md" })
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "PROVENANCE.md" })
    }

    @Test("static viewer has bounded local assets and read-only pan zoom controls")
    func staticViewerIsBoundedReadOnlyAndInteractive() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let manifestHash = try package.manifest.packageHash()
        let declaredPaths = Set(package.manifest.assets.map(\.path.rawValue))
        let packageFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.packageDirectory,
            includingPropertiesForKeys: [.isRegularFileKey])
        var actualPaths: Set<String> = []
        for url in packageFiles where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            if url.lastPathComponent != "manifest.json" {
                actualPaths.insert(url.lastPathComponent)
            }
        }
        var copiedByteCount = 0
        for path in actualPaths {
            copiedByteCount += try Data(
                contentsOf: fixture.packageDirectory.appendingPathComponent(path)).count
        }
        let viewerSource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("viewer.js"),
            encoding: .utf8)
        let styleSource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("viewer.css"),
            encoding: .utf8)

        #expect(declaredPaths == actualPaths)
        #expect(copiedByteCount <= RendererPackageValidationLimits.maximumCopiedByteCount)
        #expect(package.packageHash == manifestHash)
        #expect(viewerSource.contains("pointerdown"))
        #expect(viewerSource.contains("pointermove"))
        #expect(viewerSource.contains("wheel"))
        #expect(viewerSource.contains("keydown"))
        #expect(viewerSource.contains("const minimumScale = 0.25"))
        #expect(viewerSource.contains("const maximumScale = 4"))
        #expect(viewerSource.contains("setScale(next)"))
        #expect(viewerSource.contains("event.ctrlKey || event.metaKey || event.altKey || event.shiftKey"))
        #expect(viewerSource.contains("const pointerX = event.clientX - bounds.left"))
        #expect(viewerSource.contains("view.x = pointerX - documentX * view.scale"))
        #expect(viewerSource.contains("{ passive: false }"))
        #expect(styleSource.contains("#viewer:focus-visible"))
        #expect(viewerSource.contains("method: \"input.read\""))
        #expect(viewerSource.contains("window.open") == false)

        for prohibitedPattern in [
            "fetch(", "XMLHttpRequest", "WebSocket", "Worker(", "import(",
            "eval(", "Function(", "document.write", "localStorage", "sessionStorage",
            "indexedDB", "navigator.clipboard", "contentEditable",
        ] {
            #expect(viewerSource.contains(prohibitedPattern) == false)
        }
    }

    @Test("validator rejects a modified static viewer asset")
    func validatorRejectsModifiedStaticViewerAsset() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let tamperedDirectory = fixture.root.appending(path: "tampered-excalidraw")
        try FileManager.default.copyItem(at: fixture.packageDirectory, to: tamperedDirectory)

        let viewerURL = tamperedDirectory.appending(path: "viewer.js")
        let tamperedSource = try Data(contentsOf: viewerURL) + Data("\n// tampered\n".utf8)
        try tamperedSource.write(to: viewerURL, options: .atomic)

        #expect(throws: RendererPackageValidationError.assetHashMismatch("viewer.js")) {
            try fixture.validator.validate(directory: tamperedDirectory)
        }
    }
}

private final class PackageFixture {
    let root: URL
    let packageDirectory: URL
    let validator: RendererPackageValidator

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExcalidrawRendererPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/Excalidraw", isDirectory: true)
        validator = RendererPackageValidator(packageRoot: root)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Package fixture cleanup failed: \(error)") }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
#endif
