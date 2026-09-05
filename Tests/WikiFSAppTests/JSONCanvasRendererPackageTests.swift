#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes

/// Offline facts about the reviewed, committed JSON Canvas renderer package:
/// manifest shape, matching, fence claim, capabilities, navigation declaration,
/// digest pinning, viewer restrictions, bounds, and tamper rejection. Full
/// rendering and bridge behavior live in the hosted suite; these run in every
/// `swift test`.
@Suite("JSON Canvas installed renderer package", .serialized, .timeLimit(.minutes(1)))
struct JSONCanvasRendererPackageTests {
    @Test("reviewed package validates and declares the revision-5 asset-read contract")
    func reviewedPackageValidatesAndDeclaresRevision5Contract() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)

        #expect(package.manifest.revision == RendererManifestRevision.assetRead)
        #expect(package.manifest.revision == RendererManifestRevision.current)
        #expect(package.packageHash.hex.isEmpty == false)

        #expect(descriptor.capabilities.contains(.inputRead))
        #expect(descriptor.capabilities.contains(.externalLink))
        #expect(descriptor.capabilities.contains(.hostNavigation))
        #expect(descriptor.capabilities.contains(.assetRead))
        #expect(descriptor.linkPolicy == .userActivatedExternal)
        let navigation = try #require(descriptor.hostNavigation)
        #expect(navigation.allowedTargetKinds == [.page, .source, .namedContent])
        #expect(descriptor.hasHostNavigationDeclaration)

        // Revision 5 asset-read authority: closed roles + approved image
        // MIME types + one reviewed extractor asset.
        let assetRead = try #require(descriptor.assetRead)
        let gif = try RendererMIMEType(validating: "image/gif")
        let jpeg = try RendererMIMEType(validating: "image/jpeg")
        let png = try RendererMIMEType(validating: "image/png")
        let webp = try RendererMIMEType(validating: "image/webp")
        let svg = try RendererMIMEType(validating: "image/svg+xml")
        #expect(assetRead.allowedRoles == [.imageNode, .groupBackground])
        #expect(assetRead.allowedMIMETypes == [gif, jpeg, png, webp])
        #expect(assetRead.allowedMIMETypes.contains(svg) == false)
        #expect(assetRead.extractorAsset.rawValue == "extractor.js")
        #expect(assetRead.extractorEntryFunction == "__sdw_extract_canvas_assets")
        // The extractor asset is declared in both descriptor + top-level assets.
        #expect(package.manifest.assets.contains { $0.path.rawValue == "extractor.js" })
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "extractor.js" })
        #expect(descriptor.hasAssetReadDeclaration)
    }

    @Test("descriptor matches JSON Canvas sources and fence")
    func descriptorMatchesCanvasSourcesAndFence() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            availableInstalledDescriptors: [descriptor])
        let validData = Data("""
        {"nodes":[{"id":"note","type":"text","x":0,"y":0,"width":120,"height":60,"text":"Note"}],"edges":[]}
        """.utf8)
        let mimeInput = try RendererMatchInput(
            mimeType: try .init(validating: "application/json"),
            fileExtension: try .init(validating: "canvas"),
            sniffedBytes: validData,
            artifactKind: .source)
        let extensionInput = try RendererMatchInput(
            mimeType: nil,
            fileExtension: try .init(validating: "canvas"),
            sniffedBytes: validData,
            artifactKind: .source)
        let otherInput = try RendererMatchInput(
            mimeType: try .init(validating: "application/json"),
            fileExtension: try .init(validating: "json"),
            sniffedBytes: Data("{\"type\":\"excalidraw\",\"version\":2,\"elements\":[]}".utf8),
            artifactKind: .source)

        #expect(snapshot.matching(mimeInput).map(\.reference) == [descriptor.reference])
        #expect(snapshot.matching(extensionInput).map(\.reference) == [descriptor.reference])
        #expect(snapshot.matching(otherInput).isEmpty)

        let claim = try #require(descriptor.fenceClaims.only)
        #expect(claim.alias.rawValue == "jsoncanvas")
        #expect(claim.inlineMIMEType.rawValue == "application/json")
        #expect(snapshot.fenceClaim(for: claim.alias)?.reference == descriptor.reference)
    }

    @Test("package declares read-only capabilities and bounded sizes")
    func packageDeclaresReadOnlyCapabilitiesAndBounds() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)

        #expect(descriptor.presentations == [.web])
        #expect(descriptor.supportedEmbeddingRoles == [.inlineContent, .disclosureRow])
        #expect(descriptor.sizeLimits.maximumInputByteCount <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
        #expect(descriptor.sizeLimits.maximumDecodedByteCount <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
        #expect(descriptor.priority == 110)
        #expect(descriptor.compatibility.minimumProtocolRevision == RendererRegistrySnapshotDefaults.hostProtocolRevision)
        #expect(descriptor.accessibility.supportsVoiceOver)
        #expect(descriptor.accessibility.supportsKeyboardNavigation)
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "PROVENANCE.md" })
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "LICENSE.md" })
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "JSONCanvasSpec.md" })
    }

    @Test("viewer is bounded, local, and read-only")
    func viewerDriverIsBoundedLocalAndReadOnly() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let manifestHash = try package.manifest.packageHash()
        let declaredPaths = Set(package.manifest.assets.map(\.path.rawValue))
        let viewerSource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("viewer.js"),
            encoding: .utf8)
        let styleSource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("viewer.css"),
            encoding: .utf8)
        let entrySource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("index.html"),
            encoding: .utf8)

        #expect(package.packageHash == manifestHash)
        #expect(declaredPaths.count == 7)
        #expect(entrySource.contains("viewer.js"))
        #expect(entrySource.contains("viewer.css"))
        #expect(viewerSource.contains("method: \"input.read\""))
        #expect(viewerSource.contains("asset.read"))
        #expect(viewerSource.contains("host.navigate") == false)
        #expect(viewerSource.contains("__sdw_parse_canvas"))
        #expect(viewerSource.contains("makeSVG(\"g\", { class: \"node-wrapper\" })"))
        #expect(viewerSource.contains("wrapped.setAttribute(\"tabindex\", \"0\")"))
        #expect(viewerSource.contains("wrapped.setAttribute(\"role\", \"link\")"))
        #expect(viewerSource.contains("minimumScale"))
        #expect(viewerSource.contains("maximumScale"))
        #expect(viewerSource.contains("ArrowUp"))
        #expect(viewerSource.contains("prefers-reduced-motion") == false)
        #expect(styleSource.contains(":focus-visible"))
        #expect(styleSource.contains("prefers-reduced-motion"))
        #expect(RendererContentSecurityPolicy.headerValue.contains("default-src 'none'"))
        #expect(RendererContentSecurityPolicy.headerValue.contains("connect-src renderer-package:"))

        for prohibitedPattern in [
            "window.open", "fetch(", "XMLHttpRequest", "WebSocket", "Worker(",
            "import(", "eval(", "Function(", "document.write", "localStorage",
            "sessionStorage", "indexedDB", "navigator.clipboard", "contentEditable",
        ] {
            #expect(viewerSource.contains(prohibitedPattern) == false)
        }
    }

    @Test("validator rejects a modified viewer asset")
    func validatorRejectsModifiedViewerAsset() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let tamperedDirectory = fixture.root.appending(path: "tampered-json-canvas")
        try FileManager.default.copyItem(at: fixture.packageDirectory, to: tamperedDirectory)

        let viewerURL = tamperedDirectory.appending(path: "viewer.js")
        let tamperedSource = try Data(contentsOf: viewerURL) + Data("\n// tampered\n".utf8)
        try tamperedSource.write(to: viewerURL, options: .atomic)

        #expect(throws: RendererPackageValidationError.assetHashMismatch("viewer.js")) {
            try fixture.validator.validate(directory: tamperedDirectory)
        }
    }

    @Test("viewer parser enforces named-content safety bounds")
    func viewerParserEnforcesNamedContentSafety() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let viewerSource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("viewer.js"),
            encoding: .utf8)
        // The parser must reject traversal, absolute paths, schemes,
        // credentials, queries, percent escapes, and control characters before
        // any route callback; the file reference is a plain logical name.
        #expect(viewerSource.contains("parseCanvas"))
        #expect(viewerSource.contains("isValidFileReference"))
        #expect(viewerSource.contains("/[\\\\:@?#%]/") || viewerSource.contains("\\\\:@?#%"))
        // No page code may smuggle an HTTP(S) URL into the internal bridge.
        #expect(viewerSource.contains("host.navigate") == false)
    }
}

private final class PackageFixture {
    let root: URL
    let packageDirectory: URL
    let validator: RendererPackageValidator

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONCanvasRendererPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/JSONCanvas", isDirectory: true)
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
