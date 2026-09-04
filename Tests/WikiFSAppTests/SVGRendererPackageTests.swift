#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes

/// Offline facts about the reviewed, committed SVG renderer package: manifest
/// shape, digest pinning, tamper rejection, and the inert display contract of
/// the viewer driver. Full-stack rendering lives in the hosted suite; these
/// run in every `swift test`.
@Suite("SVG installed renderer package", .serialized, .timeLimit(.minutes(1)))
struct SVGRendererPackageTests {
    @Test("reviewed package validates at manifest revision 1")
    func reviewedPackageValidates() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)

        #expect(package.manifest.revision == 1)
        #expect(package.packageHash.hex.isEmpty == false)
        #expect(descriptor.reference.packageID.rawValue == "org.selfdrivingwiki.svg-readonly")
        #expect(descriptor.reference.registrationID.rawValue == "svg")
        // Revision 1 packages never receive fence authority.
        #expect(descriptor.fenceClaims.isEmpty)
    }

    @Test("descriptor matches image/svg+xml sources and the .svg extension")
    func descriptorMatchesSVGSources() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            availableInstalledDescriptors: [descriptor])
        let mimeInput = try RendererMatchInput(
            mimeType: try .init(validating: "image/svg+xml"),
            fileExtension: try .init(validating: "svg"),
            sniffedBytes: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8),
            artifactKind: .source)
        let extensionInput = try RendererMatchInput(
            mimeType: nil,
            fileExtension: try .init(validating: "svg"),
            sniffedBytes: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8),
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

    @Test("package declares read-only capabilities and built-in parity sizes")
    func packageDeclaresReadOnlyCapabilities() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)

        #expect(descriptor.capabilities == [.inputRead])
        #expect(descriptor.linkPolicy == .none)
        #expect(descriptor.presentations == [.web])
        #expect(descriptor.supportedEmbeddingRoles == [.inlineContent, .disclosureRow])
        // The retired built-in accepted 16 MiB of SVG input; the package
        // keeps that ceiling.
        #expect(descriptor.sizeLimits.maximumInputByteCount == 16_000_000)
        #expect(descriptor.priority == 100)
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "index.html" })
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "viewer.js" })
        #expect(descriptor.approvedAssets.contains { $0.path.rawValue == "PROVENANCE.md" })
    }

    @Test("viewer driver mounts the exact bytes as an inert data image")
    func viewerDriverIsBoundedLocalAndReadOnly() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        _ = try fixture.validator.validate(directory: fixture.packageDirectory)
        let viewerSource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("viewer.js"),
            encoding: .utf8)
        let documentSource = try String(
            contentsOf: fixture.packageDirectory.appendingPathComponent("index.html"),
            encoding: .utf8)

        #expect(viewerSource.contains("method: \"input.read\""))
        #expect(viewerSource.contains("data:image/svg+xml;base64,"))
        // WebKit image mode is the security boundary: the source bytes are
        // never decoded into markup, and the load is budget-bounded.
        #expect(viewerSource.contains("Promise.race"))
        #expect(documentSource.contains("viewer.js"))

        for prohibitedPattern in [
            "window.open", "fetch(", "XMLHttpRequest", "WebSocket", "Worker(",
            "eval(", "Function(", "document.write", "localStorage", "sessionStorage",
            "indexedDB", "navigator.clipboard", "contentEditable", "innerHTML",
        ] {
            #expect(viewerSource.contains(prohibitedPattern) == false)
        }
    }

    @Test("validator rejects a modified viewer asset")
    func validatorRejectsModifiedViewerAsset() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let tamperedDirectory = fixture.root.appending(path: "tampered-svg")
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
            .appendingPathComponent("SVGRendererPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/SVG", isDirectory: true)
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
