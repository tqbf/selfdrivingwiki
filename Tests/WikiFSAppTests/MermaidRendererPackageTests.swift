#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes

/// Offline facts about the reviewed, committed Mermaid renderer package:
/// manifest shape, the fence claim with its validation declaration, digest
/// pinning, and tamper rejection. Full-stack rendering lives in the hosted
/// suite; these run in every `swift test`.
@Suite("Mermaid installed renderer package", .serialized, .timeLimit(.minutes(1)))
struct MermaidRendererPackageTests {
    @Test("reviewed package validates and declares the revision-3 validation contract")
    func reviewedPackageValidatesAndDeclaresValidationContract() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)

        #expect(package.manifest.revision == RendererManifestRevision.current)
        #expect(package.packageHash.hex.isEmpty == false)

        let claim = try #require(descriptor.fenceClaims.only)
        let expectedAlias = try RendererFenceAlias(validating: "mermaid")
        let expectedMIME = try RendererMIMEType(validating: "text/mermaid")
        #expect(claim.alias == expectedAlias)
        #expect(claim.inlineMIMEType == expectedMIME)
        let validation = try #require(claim.validation)
        #expect(validation.engineAssetPath.rawValue == "mermaid.min.js")
        #expect(validation.wrapperAssetPath.rawValue == "validate.js")
        #expect(validation.entryFunction == "__sdw_validate_fence")
        #expect(claim.hasValidation)
        #expect(descriptor.hasFenceValidation)
    }

    @Test("descriptor matches text/mermaid sources and the .mmd extension")
    func descriptorMatchesMermaidSources() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [descriptor])
        let mimeInput = try RendererMatchInput(
            mimeType: try .init(validating: "text/mermaid"),
            fileExtension: try .init(validating: "mmd"),
            sniffedBytes: Data("graph TD\n A-->B".utf8),
            artifactKind: .source)
        let extensionInput = try RendererMatchInput(
            mimeType: nil,
            fileExtension: try .init(validating: "mmd"),
            sniffedBytes: Data("graph TD\n A-->B".utf8),
            artifactKind: .source)
        let otherInput = try RendererMatchInput(
            mimeType: try .init(validating: "text/plain"),
            fileExtension: try .init(validating: "txt"),
            sniffedBytes: Data("hello".utf8),
            artifactKind: .source)

        #expect(snapshot.matching(mimeInput).map(\.reference) == [descriptor.reference])
        #expect(snapshot.matching(extensionInput).map(\.reference) == [descriptor.reference])
        #expect(snapshot.matching(otherInput).isEmpty)
    }

    @Test("package declares read-only capabilities and bounded sizes")
    func packageDeclaresReadOnlyCapabilities() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)

        #expect(descriptor.capabilities == [.inputRead])
        #expect(descriptor.linkPolicy == .none)
        #expect(descriptor.presentations == [.web])
        #expect(descriptor.supportedEmbeddingRoles == [.inlineContent, .disclosureRow])
        #expect(descriptor.sizeLimits.maximumInputByteCount <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
        #expect(descriptor.priority == 90)
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "LICENSE.txt" })
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "PROVENANCE.md" })
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "mermaid.min.js" })
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "validate.js" })
    }

    @Test("viewer driver is bounded, local, and read-only")
    func viewerDriverIsBoundedLocalAndReadOnly() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        _ = try fixture.validator.validate(directory: fixture.packageDirectory)
        let viewerSource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("viewer.js"),
            encoding: .utf8)
        let entrySource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("validate.js"),
            encoding: .utf8)
        let documentSource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("index.html"),
            encoding: .utf8)

        #expect(viewerSource.contains("method: \"input.read\""))
        #expect(viewerSource.contains("securityLevel: \"strict\""))
        #expect(viewerSource.contains("prefers-color-scheme"))
        #expect(viewerSource.contains("Promise.race"))
        #expect(entrySource.contains("__sdw_validate_fence"))
        #expect(documentSource.contains("mermaid.min.js"))
        #expect(documentSource.contains("viewer.js"))

        for prohibitedPattern in [
            "window.open", "fetch(", "XMLHttpRequest", "WebSocket", "Worker(",
            "eval(", "Function(", "document.write", "localStorage", "sessionStorage",
            "indexedDB", "navigator.clipboard", "contentEditable",
        ] {
            #expect(viewerSource.contains(prohibitedPattern) == false)
            #expect(entrySource.contains(prohibitedPattern) == false)
        }
    }

    @Test("validator rejects a modified engine asset")
    func validatorRejectsModifiedEngineAsset() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let tamperedDirectory = fixture.root.appending(path: "tampered-mermaid")
        try FileManager.default.copyItem(at: fixture.packageDirectory, to: tamperedDirectory)

        let engineURL = tamperedDirectory.appending(path: "mermaid.min.js")
        let tamperedSource = try Data(contentsOf: engineURL) + Data("\n// tampered\n".utf8)
        try tamperedSource.write(to: engineURL, options: .atomic)

        #expect(throws: RendererPackageValidationError.assetHashMismatch("mermaid.min.js")) {
            try fixture.validator.validate(directory: tamperedDirectory)
        }
    }

    @Test("validator rejects a modified wrapper asset")
    func validatorRejectsModifiedWrapperAsset() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let tamperedDirectory = fixture.root.appending(path: "tampered-mermaid-wrapper")
        try FileManager.default.copyItem(at: fixture.packageDirectory, to: tamperedDirectory)

        let wrapperURL = tamperedDirectory.appending(path: "validate.js")
        let tamperedSource = try Data(contentsOf: wrapperURL) + Data("\n// tampered\n".utf8)
        try tamperedSource.write(to: wrapperURL, options: .atomic)

        #expect(throws: RendererPackageValidationError.assetHashMismatch("validate.js")) {
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
            .appendingPathComponent("MermaidRendererPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/Mermaid", isDirectory: true)
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
