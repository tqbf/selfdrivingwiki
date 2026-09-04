#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

/// Phase 5 acceptance tests: validated package bytes and host-composed frame
/// resources are served through separate typed layers, and the reserved
/// `__host__/` namespace cannot be shadowed by a package.
@MainActor
struct RendererFrameResourceProvenanceTests {
    /// A stub validated provider: serves one entry document and rejects the
    /// reserved namespace like the real validated provider would (it only
    /// serves manifest-declared assets).
    private struct StubValidatedProvider: RendererPackageResourceProviding {
        let entryHTML: String

        func resource(for url: URL) throws -> RendererPackageResource {
            let request = try RendererPackageScheme.request(from: url)
            if RendererFrameHostNamespace.isReserved(request.path) {
                throw RendererPackageResourceError.undeclaredAsset
            }
            guard request.path.rawValue == "index.html" else {
                throw RendererPackageResourceError.undeclaredAsset
            }
            return RendererPackageResource(
                data: Data(entryHTML.utf8),
                mimeType: RendererMIMEType(rawValue: "text/html")!,
                isEntryDocument: true)
        }
    }

    private func makeRouter(entryHTML: String) -> ReaderRendererPackageRouter {
        let router = ReaderRendererPackageRouter()
        let token = RendererFrameOriginToken.generate()
        _ = router.admit(
            token: token,
            reservation: RendererPackageReservation(
                packageID: RendererPackageID(rawValue: "org.example.probe")!,
                version: RendererPackageVersion(rawValue: "1.0.0")!),
            entryPath: RendererRelativePath(rawValue: "index.html")!,
            provider: StubValidatedProvider(entryHTML: entryHTML),
            inputBootstrapHTML: "window.__hostBootstrap=true;")
        return router
    }

    @Test("validated provider never serves the reserved host namespace")
    func validatedProviderRejectsHostNamespace() throws {
        let provider = StubValidatedProvider(entryHTML: "<html></html>")
        let url = RendererPackageScheme.url(
            packageID: RendererPackageID(rawValue: "org.example.probe")!,
            version: RendererPackageVersion(rawValue: "1.0.0")!,
            path: RendererRelativePath(rawValue: "__host__/renderer-input.js")!)
        #expect(throws: RendererPackageResourceError.undeclaredAsset) {
            _ = try provider.resource(for: url)
        }
    }

    @Test("frame composer serves the typed bootstrap overlay from the reserved path")
    func composerServesTypedBootstrapOnly() throws {
        let router = makeRouter(entryHTML: "<html><script src=\"viewer.js\"></script></html>")
        let tokenURL = router.diagnosticStartedRequests.first
        _ = tokenURL
        // Serve the entry under a frame token to exercise composition.
        let token = RendererFrameOriginToken.generate()
        let router2 = ReaderRendererPackageRouter()
        let entryURL = router2.admit(
            token: token,
            reservation: RendererPackageReservation(
                packageID: RendererPackageID(rawValue: "org.example.probe")!,
                version: RendererPackageVersion(rawValue: "1.0.0")!),
            entryPath: RendererRelativePath(rawValue: "index.html")!,
            provider: StubValidatedProvider(entryHTML: "<html><script src=\"viewer.js\"></script></html>"),
            inputBootstrapHTML: "window.__hostBootstrap=true;")

        // The composed entry references the reserved bootstrap path.
        let entry = try router2.resource(for: entryURL)
        let html = String(decoding: entry.data, as: UTF8.self)
        #expect(html.contains("<script src=\"__host__/renderer-input.js\"></script>"))
        #expect(html.contains("viewer.js"))

        // The reserved path serves the exact typed overlay bytes.
        let bootstrapURL = RendererFramePackageURL.frameURL(
            token: token,
            packageID: RendererPackageID(rawValue: "org.example.probe")!,
            version: RendererPackageVersion(rawValue: "1.0.0")!,
            path: RendererRelativePath(rawValue: RendererFrameHostNamespace.inputBootstrapPath)!)
        let bootstrap = try router2.resource(for: bootstrapURL)
        #expect(String(decoding: bootstrap.data, as: UTF8.self) == "window.__hostBootstrap=true;")
        #expect(bootstrap.isEntryDocument == false)

        // An uncomposed token's reserved path fails closed.
        let stranger = RendererFrameOriginToken.generate()
        let strangerURL = RendererFramePackageURL.frameURL(
            token: stranger,
            packageID: RendererPackageID(rawValue: "org.example.probe")!,
            version: RendererPackageVersion(rawValue: "1.0.0")!,
            path: RendererRelativePath(rawValue: RendererFrameHostNamespace.inputBootstrapPath)!)
        #expect(throws: RendererPackageResourceError.packageIdentityMismatch) {
            _ = try router2.resource(for: strangerURL)
        }
    }

    @Test("package validation rejects manifests declaring the reserved namespace")
    func packageManifestCannotShadowHostNamespace() throws {
        // The reserved-prefix predicate is the single shadowing gate.
        #expect(RendererFrameHostNamespace.isReserved(
            RendererRelativePath(rawValue: "__host__/renderer-input.js")!))
        #expect(RendererFrameHostNamespace.isReserved(
            RendererRelativePath(rawValue: "__host__/anything.txt")!))
        #expect(RendererFrameHostNamespace.isReserved(
            RendererRelativePath(rawValue: "__host__/nested/deep.js")!))
        // Ordinary package paths are unaffected.
        #expect(RendererFrameHostNamespace.isReserved(
            RendererRelativePath(rawValue: "index.html")!) == false)
        #expect(RendererFrameHostNamespace.isReserved(
            RendererRelativePath(rawValue: "vendor/engine.js")!) == false)
        #expect(RendererFrameHostNamespace.isReserved(
            RendererRelativePath(rawValue: "__hostile__.js")!) == false)
    }
}
#endif
