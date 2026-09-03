#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// AC.4 frame-scoped bridge registry tests: exact provenance succeeds; wrong
/// token, origin, webview, generation, or closed state fails closed; the
/// frame budget bounds concurrency; collapse/removal are scoped; and two
/// same-package frames hold distinct, mutually isolated tokens.
@Suite
@MainActor
struct ReaderRendererFrameBridgeTests {
    private func placeholder(_ raw: String) throws -> RendererAttachmentPlaceholderID {
        try RendererAttachmentPlaceholderID(validating: raw)
    }

    private func makeSession(
        placeholderID: RendererAttachmentPlaceholderID,
        token: RendererFrameOriginToken,
        generation: Int = 5,
        webview: NSObject = NSObject()
    ) -> ReaderRendererFrameSession {
        ReaderRendererFrameSession(
            placeholderID: placeholderID,
            frameToken: token,
            rendererReference: RendererReference(
                packageID: RendererPackageID(rawValue: "org.example.probe")!,
                version: RendererPackageVersion(rawValue: "1.0.0")!,
                registrationID: RendererRegistrationID(rawValue: "probe")!),
            generation: generation,
            broker: ReaderRendererFrameTestSupport.makeBroker(),
            expectedWebViewID: ObjectIdentifier(webview))
    }

    @Test("exact frame provenance authorizes the session")
    func exactProvenanceSucceeds() throws {
        let registry = ReaderRendererFrameBridgeRegistry()
        let p = try placeholder("row")
        let token = RendererFrameOriginToken.generate()
        let webview = NSObject()
        #expect(registry.admit(
            placeholderID: p, frameToken: token,
            rendererReference: makeSession(placeholderID: p, token: token, webview: webview).rendererReference,
            generation: 5,
            broker: ReaderRendererFrameTestSupport.makeBroker(),
            expectedWebViewID: ObjectIdentifier(webview)))
        #expect(registry.authorize(
            token: token,
            originHost: token.rawValue,
            originScheme: RendererPackageScheme.name,
            webViewID: ObjectIdentifier(webview),
            generation: 5) != nil)
    }

    @Test("wrong token, origin, webview, generation, or closed state fails closed")
    func wrongProvenanceFailsClosed() throws {
        let registry = ReaderRendererFrameBridgeRegistry()
        let p = try placeholder("row")
        let token = RendererFrameOriginToken.generate()
        let webview = NSObject()
        let session = makeSession(placeholderID: p, token: token, webview: webview)
        #expect(registry.admit(
            placeholderID: p, frameToken: token,
            rendererReference: session.rendererReference,
            generation: 5,
            broker: ReaderRendererFrameTestSupport.makeBroker(),
            expectedWebViewID: ObjectIdentifier(webview)))

        // Unknown token.
        #expect(registry.authorize(
            token: RendererFrameOriginToken.generate(),
            originHost: token.rawValue,
            originScheme: RendererPackageScheme.name,
            webViewID: ObjectIdentifier(webview),
            generation: 5) == nil)
        // Wrong origin host (cross-frame replay).
        #expect(registry.authorize(
            token: token,
            originHost: "other-frame-host",
            originScheme: RendererPackageScheme.name,
            webViewID: ObjectIdentifier(webview),
            generation: 5) == nil)
        // Wrong origin scheme.
        #expect(registry.authorize(
            token: token,
            originHost: token.rawValue,
            originScheme: "https",
            webViewID: ObjectIdentifier(webview),
            generation: 5) == nil)
        // Wrong webview (frame hopping).
        #expect(registry.authorize(
            token: token,
            originHost: token.rawValue,
            originScheme: RendererPackageScheme.name,
            webViewID: ObjectIdentifier(NSObject()),
            generation: 5) == nil)
        // Stale generation.
        #expect(registry.authorize(
            token: token,
            originHost: token.rawValue,
            originScheme: RendererPackageScheme.name,
            webViewID: ObjectIdentifier(webview),
            generation: 4) == nil)
        // Closed frame.
        registry.close(placeholderID: p)
        #expect(registry.authorize(
            token: token,
            originHost: token.rawValue,
            originScheme: RendererPackageScheme.name,
            webViewID: ObjectIdentifier(webview),
            generation: 5) == nil)
    }

    @Test("frame budget bounds concurrent admitted sessions")
    func frameBudgetBounds() throws {
        let registry = ReaderRendererFrameBridgeRegistry(maximumFrames: 2)
        for index in 0..<3 {
            let p = try placeholder("row-\(index)")
            let token = RendererFrameOriginToken.generate()
            let webview = NSObject()
            let ok = registry.admit(
                placeholderID: p, frameToken: token,
                rendererReference: makeSession(placeholderID: p, token: token, webview: webview).rendererReference,
                generation: 1,
                broker: ReaderRendererFrameTestSupport.makeBroker(),
                expectedWebViewID: ObjectIdentifier(webview))
            #expect(ok == (index < 2))
        }
        #expect(registry.activeSessionCount == 2)
    }

    @Test("collapse and removal are scoped to one placeholder")
    func scopedTeardown() throws {
        let registry = ReaderRendererFrameBridgeRegistry()
        let a = try placeholder("row-a")
        let b = try placeholder("row-b")
        let tokenA = RendererFrameOriginToken.generate()
        let tokenB = RendererFrameOriginToken.generate()
        let webview = NSObject()
        let sessionA = makeSession(placeholderID: a, token: tokenA, webview: webview)
        #expect(registry.admit(
            placeholderID: a, frameToken: tokenA,
            rendererReference: sessionA.rendererReference,
            generation: 1,
            broker: ReaderRendererFrameTestSupport.makeBroker(),
            expectedWebViewID: ObjectIdentifier(webview)))
        let sessionB = makeSession(placeholderID: b, token: tokenB, webview: webview)
        #expect(registry.admit(
            placeholderID: b, frameToken: tokenB,
            rendererReference: sessionB.rendererReference,
            generation: 1,
            broker: ReaderRendererFrameTestSupport.makeBroker(),
            expectedWebViewID: ObjectIdentifier(webview)))

        registry.close(placeholderID: a)
        #expect(registry.session(for: tokenA) == nil)
        #expect(registry.session(for: tokenB) != nil)
        // B's messages still authorize.
        #expect(registry.authorize(
            token: tokenB,
            originHost: tokenB.rawValue,
            originScheme: RendererPackageScheme.name,
            webViewID: ObjectIdentifier(webview),
            generation: 1) != nil)
    }

    @Test("two same-package frames hold distinct tokens and cannot read each other")
    func twoFramesAreDistinctAndIsolated() throws {
        let registry = ReaderRendererFrameBridgeRegistry()
        let a = try placeholder("row-a")
        let b = try placeholder("row-b")
        let tokenA = RendererFrameOriginToken.generate()
        let tokenB = RendererFrameOriginToken.generate()
        #expect(tokenA.rawValue != tokenB.rawValue)
        let webview = NSObject()
        let reference = makeSession(placeholderID: a, token: tokenA, webview: webview).rendererReference
        #expect(registry.admit(
            placeholderID: a, frameToken: tokenA,
            rendererReference: reference,
            generation: 1,
            broker: ReaderRendererFrameTestSupport.makeBroker(),
            expectedWebViewID: ObjectIdentifier(webview)))
        #expect(registry.admit(
            placeholderID: b, frameToken: tokenB,
            rendererReference: reference,
            generation: 1,
            broker: ReaderRendererFrameTestSupport.makeBroker(),
            expectedWebViewID: ObjectIdentifier(webview)))

        // Frame A's provenance does not authorize frame B's session and vice
        // versa: one frame cannot use the other's bridge route.
        #expect(registry.authorize(
            token: tokenA,
            originHost: tokenB.rawValue, // A's token, B's origin: replay
            originScheme: RendererPackageScheme.name,
            webViewID: ObjectIdentifier(webview),
            generation: 1) == nil)
        #expect(registry.authorize(
            token: tokenB,
            originHost: tokenA.rawValue, // B's token, A's origin: replay
            originScheme: RendererPackageScheme.name,
            webViewID: ObjectIdentifier(webview),
            generation: 1) == nil)
    }

    @Test("closeAll releases every session deterministically")
    func closeAllReleases() throws {
        let registry = ReaderRendererFrameBridgeRegistry()
        for index in 0..<3 {
            let p = try placeholder("row-\(index)")
            let token = RendererFrameOriginToken.generate()
            let webview = NSObject()
            _ = registry.admit(
                placeholderID: p, frameToken: token,
                rendererReference: makeSession(placeholderID: p, token: token, webview: webview).rendererReference,
                generation: 1,
                broker: ReaderRendererFrameTestSupport.makeBroker(),
                expectedWebViewID: ObjectIdentifier(webview))
        }
        #expect(registry.activeSessionCount == 3)
        registry.closeAll()
        #expect(registry.activeSessionCount == 0)
    }
}

/// Test-only broker factory (the registry's broker dependency is otherwise
/// constructed by the reader with a real authorized input reader).
@MainActor
enum ReaderRendererFrameTestSupport {
    static func makeBroker() -> RendererContentWorldBroker {
        let store = try! GRDBWikiStore()
        let source = try! store.addSource(filename: "probe.txt", data: Data("probe".utf8))
        let version = try! store.activeContentVersion(sourceID: source.id)!
        let reader = RendererAuthorizedInputReader(
            store: store, authorizedInput: .source(versionID: version.id))
        return RendererContentWorldBroker(
            sessionID: .init(rawValue: UUID()),
            capability: .init(rawValue: "probe-capability"),
            inputReader: reader)
    }
}
#endif
