#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// Offline facts about the reviewed, committed SVG renderer package: manifest
/// shape, digest pinning, tamper rejection, and the inert display contract of
/// the viewer driver. Full-stack rendering lives in the hosted suite; the
/// app test target runs only with `WIKIFS_APP_TESTS=1`.
@Suite("SVG installed renderer package", .serialized, .timeLimit(.minutes(1)))
struct SVGRendererPackageTests {
    @Test("reviewed package validates at manifest revision 2 and version 1.0.1")
    func reviewedPackageValidates() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)

        #expect(package.manifest.revision == RendererManifestRevision.fenceClaims)
        #expect(package.manifest.version.rawValue == "1.0.1")
        #expect(package.packageHash.hex.isEmpty == false)
        #expect(descriptor.reference.packageID.rawValue == "org.selfdrivingwiki.svg-readonly")
        #expect(descriptor.reference.version.rawValue == "1.0.1")
        #expect(descriptor.reference.registrationID.rawValue == "svg")
        let claim = try #require(descriptor.fenceClaims.only)
        #expect(claim.alias == RendererFenceAlias(rawValue: "svg"))
        #expect(claim.inlineMIMEType == RendererMIMEType(rawValue: "image/svg+xml"))
    }

    @Test("an SVG fence produces a collapsed renderer row")
    func svgFenceProducesCollapsedRendererRow() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            availableInstalledDescriptors: [descriptor])
        let html = MarkdownHTMLRenderer.render(
            "```svg\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>\n```",
            options: .init(
                codeHighlighting: .disabled,
                rendererEmbedProjection: .init(sourceEmbeds: [:], richFenceClaims: claims),
                documentIdentity: .init(
                    pageID: PageID(rawValue: "01HTESTPAGE000000000000001"),
                    pageVersionID: PageVersionID(rawValue: "01HTESTPV00000000000000001")),
                rendererActivationAdmission: .init(
                    pageID: PageID(rawValue: "01HTESTPAGE000000000000001"),
                    pageVersionID: PageVersionID(rawValue: "01HTESTPV00000000000000001"),
                    capability: .init(rawValue: "svg-test"), generation: 1)))
        #expect(html.contains("sdw-renderer-card"))
        #expect(html.contains("data-renderer-reference=\"org.selfdrivingwiki.svg-readonly/1.0.1/svg\""))
        // Untitled rows use the descriptor display name.
        #expect(html.contains("title=\"SVG\""))
        #expect(html.contains(">SVG</span>"))
    }

    @Test("an SVG fence preserves its quoted title and exact payload metadata")
    func svgFencePreservesTitleAndPayload() throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let excalidraw = PackageFenceTestSupport.installedExcalidrawDescriptor()
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            availableInstalledDescriptors: [descriptor, excalidraw])
        // The authored title carries angle brackets, an ampersand, and spaces
        // inside the quoted info string.
        let payload = "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>&amp;</text></svg>"
        let pageID = PageID(rawValue: "01HTESTPAGE000000000000001")
        let versionID = PageVersionID(rawValue: "01HTESTPV00000000000000001")
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: .init(sourceEmbeds: [:], richFenceClaims: claims),
            documentIdentity: .init(pageID: pageID, pageVersionID: versionID),
            rendererActivationAdmission: .init(
                pageID: pageID, pageVersionID: versionID,
                capability: .init(rawValue: "svg-test"), generation: 1))
        let svgHTML = MarkdownHTMLRenderer.render(
            "```svg \"Logo <&> mark\"\n\(payload)\n```", options: options)
        let excalidrawHTML = MarkdownHTMLRenderer.render(
            "```excalidraw\n{\"type\":\"excalidraw\",\"version\":2,\"elements\":[]}\n```",
            options: options)
        #expect(svgHTML.contains("&quot;fenceAlias&quot;:&quot;svg&quot;"))
        #expect(svgHTML.contains("&quot;mimeType&quot;:&quot;image\\/svg+xml&quot;"))
        #expect(svgHTML.contains("&quot;bytes&quot;:"))
        #expect(svgHTML.contains("aria-label=\"SVG renderer: Logo &lt;&amp;&gt; mark\""))
        #expect(svgHTML.contains("title=\"Logo &lt;&amp;&gt; mark\""))

        // Both reviewed formats must use the same generic disclosure-row
        // structure, embedding role, and controls; only package metadata
        // differs. Assert presence first: two all-false arrays would
        // otherwise report parity on two broken rows.
        let genericRowMarkers = [
            "sdw-renderer-card", "data-renderer-expanded=\"false\"",
            "aria-expanded=\"false\"", "sdw-renderer-card__expansion",
            "sdw-renderer-card__title", "data-renderer-action=\"expand\"",
            "renderer-action://open", "Open in Window"
        ]
        #expect(genericRowMarkers.allSatisfy { svgHTML.contains($0) })
        #expect(genericRowMarkers.allSatisfy { excalidrawHTML.contains($0) })
        #expect(svgHTML.contains("data-renderer-reference=\"org.selfdrivingwiki.svg-readonly/1.0.1/svg\""))
        #expect(excalidrawHTML.contains("data-renderer-reference=\"org.selfdrivingwiki.excalidraw-readonly/1.0.5/excalidraw\""))
    }

    @Test("an SVG fence without its package remains readable code")
    func svgFenceWithoutPackageRemainsReadableCode() {
        let html = MarkdownHTMLRenderer.render(
            "```svg\n<svg>&amp;</svg>\n```",
            options: .init(
                codeHighlighting: .disabled,
                rendererEmbedProjection: .init(sourceEmbeds: [:], richFenceClaims: [:]),
                documentIdentity: nil,
                rendererActivationAdmission: nil))
        #expect(html.contains(#"<pre><code class="language-svg">"#))
        #expect(html.contains("&lt;svg&gt;&amp;amp;&lt;/svg&gt;"))
        #expect(html.contains("sdw-renderer-card\"") == false)
    }

    @Test("an SVG fence whose claimant was removed shows the fallback notice")
    func svgFenceWithRemovedClaimantShowsFallbackNotice() {
        // The alias was claimed before and its claimant is now gone, so the
        // projection records it as unavailable instead of silently dropping it.
        let html = MarkdownHTMLRenderer.render(
            "```svg\n<svg>&amp;</svg>\n```",
            options: .init(
                codeHighlighting: .disabled,
                rendererEmbedProjection: .init(
                    sourceEmbeds: [:],
                    richFenceClaims: [:],
                    unavailableFenceAliases: [RendererFenceAlias(rawValue: "svg")!]),
                documentIdentity: nil,
                rendererActivationAdmission: nil))
        #expect(html.contains(#"<pre><code class="language-svg">"#))
        #expect(html.contains(#"<p class="sdw-renderer-card__fallback">"#))
        #expect(html.contains("The renderer for this block is not available here."))
    }

    @Test("an oversized SVG fence stays silent plain code")
    func oversizedSVGFenceStaysReadableCodeWithoutCard() throws {
        // The bridge payload ceiling bounds every package fence; an oversized
        // fence must keep the readable code and must not grow a row or a notice.
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            availableInstalledDescriptors: [descriptor])
        let oversizedPayload = String(repeating: "<rect/>\n", count: 9_000)
        let html = MarkdownHTMLRenderer.render(
            "```svg\n\(oversizedPayload)```",
            options: .init(
                codeHighlighting: .disabled,
                rendererEmbedProjection: .init(sourceEmbeds: [:], richFenceClaims: claims),
                documentIdentity: .init(
                    pageID: PageID(rawValue: "01HTESTPAGE000000000000001"),
                    pageVersionID: PageVersionID(rawValue: "01HTESTPV00000000000000001")),
                rendererActivationAdmission: .init(
                    pageID: PageID(rawValue: "01HTESTPAGE000000000000001"),
                    pageVersionID: PageVersionID(rawValue: "01HTESTPV00000000000000001"),
                    capability: .init(rawValue: "svg-test"), generation: 1)))
        #expect(oversizedPayload.utf8.count > WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
        #expect(html.contains("<pre><code class=\"language-svg\">"))
        #expect(html.contains("sdw-renderer-card") == false)
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
        validator = RendererPackageValidator(
            packageRoot: root,
            reservedFenceAliases: BuiltInRendererDescriptors.reservedFenceAliases)
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
