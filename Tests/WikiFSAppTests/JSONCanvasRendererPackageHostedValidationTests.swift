#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

@Suite("JSON Canvas renderer hosted validation", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct JSONCanvasRendererPackageHostedValidationTests {
    @Test("startup input renders an accessible scene and keyboard changes its transform")
    func startupInputRendersSceneAndKeyboardTransforms() async throws {
        let fixture = try JSONCanvasHostedFixture()
        defer { fixture.remove() }
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        NSApplication.shared.setActivationPolicy(.accessory)

        let package = try fixture.validator.validate(directory: fixture.directory)
        let descriptor = try #require(package.manifest.descriptors.first)
        let entry = try #require(descriptor.webEntryPoint)
        let entryURL = RendererPackageScheme.url(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            path: entry.path)
        let bytes = Data(#"{"nodes":[{"id":"note","type":"link","x":0,"y":0,"width":160,"height":80,"url":"[[page:01HXXXXXXXXXXXXXXXXXXXXXXX]]"},{"id":"external","type":"link","x":200,"y":0,"width":160,"height":80,"url":"https://example.com"}],"edges":[]}"#.utf8)
        let document = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01JHOSTEDJSONCANVASP000001"),
            pageVersionID: PageVersionID(rawValue: "01JHOSTEDJSONCANVASV0000001"))
        let block = try MarkdownFencedBlock(
            documentIdentity: document,
            parserOrdinal: 0,
            rawInfoString: "jsoncanvas",
            bytes: bytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: document.pageID,
            pageVersionID: document.pageVersionID,
            blockID: try #require(block.blockID),
            fenceAlias: try RendererFenceAlias(validating: "jsoncanvas"),
            mimeType: try RendererMIMEType(validating: "application/json"),
            bytes: bytes)
        let reader = RendererAuthorizedInputReader(
            store: try GRDBWikiStore(),
            authorizedInput: .inlineArtifact(artifact))
        let mount = try Self.makeMount(
            package: package,
            descriptor: descriptor,
            entryURL: entryURL,
            reader: reader)
        defer { mount.teardown() }

        try await Self.wait("session") { mount.session() != nil }
        let session = try #require(mount.session())
        try await Self.wait("ready") {
            if case .ready = session.state { return true }
            return false
        }
        let webView = try #require(session.webView)
        try await Self.waitForJavaScript(
            "document.querySelector('svg.scene') ? 'ok' : 'pending'",
            expected: "ok",
            webView: webView,
            description: "scene")

        let semantics = await evaluateJavaScriptWithTimeout(webView, """
        JSON.stringify({
          role: document.querySelector('svg.scene')?.getAttribute('role'),
          label: !!document.querySelector('svg.scene')?.getAttribute('aria-label'),
          node: !!document.querySelector('.node-text, rect.node'),
          wrapperChildren: document.querySelector('.node-wrapper')?.children.length,
          wrapperRole: document.querySelector('.node-wrapper')?.getAttribute('role'),
          wrapperTabIndex: document.querySelector('.node-wrapper')?.getAttribute('tabindex'),
          navigation: !!document.querySelector('.node-wrapper')?.dataset.rendererHostNavigation,
          externalAnchor: document.querySelector('a.node-anchor')?.getAttribute('href'),
          externalHasInternalTarget: !!document.querySelector('a.node-anchor')?.dataset.rendererHostNavigation
        })
        """)
        #expect(semantics?.contains("\"role\":\"group\"") == true)
        #expect(semantics?.contains("\"label\":true") == true)
        #expect(semantics?.contains("\"node\":true") == true)
        #expect(semantics?.contains("\"wrapperChildren\":2") == true)
        #expect(semantics?.contains("\"wrapperRole\":\"link\"") == true)
        #expect(semantics?.contains("\"wrapperTabIndex\":\"0\"") == true)
        #expect(semantics?.contains("\"navigation\":true") == true)
        #expect(semantics?.contains("\"externalAnchor\":\"https://example.com\"") == true)
        #expect(semantics?.contains("\"externalHasInternalTarget\":false") == true)

        let interaction = await evaluateJavaScriptWithTimeout(webView, """
        (function() {
          const viewer = document.getElementById('viewer');
          const internalLink = document.querySelector('.node-wrapper');
          const scene = document.querySelector('svg.scene g');
          internalLink.focus();
          if (document.activeElement !== internalLink) return 'focus-missing';
          const before = scene.getAttribute('transform');
          viewer.dispatchEvent(new KeyboardEvent('keydown', { key: '+', bubbles: true }));
          const zoomed = scene.getAttribute('transform');
          viewer.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
          return before !== zoomed && zoomed !== scene.getAttribute('transform') ? 'ok' : 'missing';
        })()
        """)
        #expect(interaction == "ok")
    }

    @Test("multi-node canvas renders bezier edges, markers, text, and z-order")
    func rendersGeometryMarkersAndText() async throws {
        let fixture = try JSONCanvasHostedFixture()
        defer { fixture.remove() }
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        NSApplication.shared.setActivationPolicy(.accessory)

        let package = try fixture.validator.validate(directory: fixture.directory)
        let descriptor = try #require(package.manifest.descriptors.first)
        let entry = try #require(descriptor.webEntryPoint)
        let entryURL = RendererPackageScheme.url(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            path: entry.path)
        // Text nodes + an edge with implicit sides/ends (defaults toEnd=arrow)
        // + a disabled-style file node referencing a host-denied asset.
        let bytes = Data(#"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":100,"height":50,"text":"**Bold** line"},{"id":"b","type":"text","x":200,"y":0,"width":100,"height":50,"text":"Second"},{"id":"f","type":"file","x":400,"y":0,"width":100,"height":60,"file":"absent.png"}],"edges":[{"id":"e","fromNode":"a","toNode":"b"}]}"#.utf8)
        let document = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01JHOSTEDJSONCANVASP000001"),
            pageVersionID: PageVersionID(rawValue: "01JHOSTEDJSONCANVASV0000001"))
        let block = try MarkdownFencedBlock(
            documentIdentity: document,
            parserOrdinal: 0,
            rawInfoString: "jsoncanvas",
            bytes: bytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: document.pageID,
            pageVersionID: document.pageVersionID,
            blockID: try #require(block.blockID),
            fenceAlias: try RendererFenceAlias(validating: "jsoncanvas"),
            mimeType: try RendererMIMEType(validating: "application/json"),
            bytes: bytes)
        let reader = RendererAuthorizedInputReader(
            store: try GRDBWikiStore(),
            authorizedInput: .inlineArtifact(artifact))
        let mount = try Self.makeMount(
            package: package,
            descriptor: descriptor,
            entryURL: entryURL,
            reader: reader)
        defer { mount.teardown() }

        try await Self.wait("session") { mount.session() != nil }
        let session = try #require(mount.session())
        try await Self.wait("ready") {
            if case .ready = session.state { return true }
            return false
        }
        let webView = try #require(session.webView)
        try await Self.waitForJavaScript(
            "document.querySelector('svg.scene path.edge') ? 'ok' : 'pending'",
            expected: "ok",
            webView: webView,
            description: "geometry path")

        let semantics = await evaluateJavaScriptWithTimeout(webView, """
        JSON.stringify({
          edges: document.querySelectorAll('svg.scene path.edge').length,
          nodes: document.querySelectorAll('svg.scene .node-wrapper').length,
          hasMarkerEnd: !!document.querySelector('svg.scene path.edge')?.getAttribute('marker-end'),
          hasMarkerStart: !!document.querySelector('svg.scene path.edge')?.getAttribute('marker-start'),
          textFo: !!document.querySelector('svg.scene .node-text-fo'),
          bold: !!document.querySelector('svg.scene .node-text strong'),
          fileFallbackLabel: document.querySelector('[data-asset-reference="absent.png"]') ? 'image-requested' : 'none',
          transform: document.querySelector('svg.scene g.scene-layer')?.getAttribute('transform') || ''
        })
        """)
        #expect(semantics?.contains("\"edges\":1") == true)
        #expect(semantics?.contains("\"nodes\":3") == true)
        // toEnd defaults to arrow -> marker-end set, marker-start absent.
        #expect(semantics?.contains("\"hasMarkerEnd\":true") == true)
        #expect(semantics?.contains("\"hasMarkerStart\":false") == true)
        // Markdown text renders as strong inside the foreignObject.
        #expect(semantics?.contains("\"textFo\":true") == true)
        #expect(semantics?.contains("\"bold\":true") == true)
        // The file node references a host-denied asset; the image element is
        // present (fallback label remains).
        #expect(semantics?.contains("\"fileFallbackLabel\":\"image-requested\"") == true)
        // Initial fit sets a non-identity transform (fit-to-window). The
        // literal empty-value form `"transform":""` must NOT be present.
        #expect(semantics?.contains("\"transform\":\"\"") == false, "transform was not applied; semantics: \(semantics ?? "nil")")
    }

    @Test("malformed input shows an in-view message and preserves source bytes")
    func malformedInputPreservesSource() async throws {
        let fixture = try JSONCanvasHostedFixture()
        defer { fixture.remove() }
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        NSApplication.shared.setActivationPolicy(.accessory)

        let package = try fixture.validator.validate(directory: fixture.directory)
        let descriptor = try #require(package.manifest.descriptors.first)
        let entry = try #require(descriptor.webEntryPoint)
        let entryURL = RendererPackageScheme.url(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            path: entry.path)
        let bytes = Data("{ malformed".utf8)
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "broken.canvas", data: bytes)
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .source(versionID: version.id))
        let mount = try Self.makeMount(
            package: package,
            descriptor: descriptor,
            entryURL: entryURL,
            reader: reader)
        defer { mount.teardown() }

        try await Self.wait("session") { mount.session() != nil }
        let session = try #require(mount.session())
        try await Self.wait("ready") {
            if case .ready = session.state { return true }
            return false
        }
        let webView = try #require(session.webView)
        try await Self.waitForJavaScript(
            "document.querySelector('.message') ? 'ok' : 'pending'",
            expected: "ok",
            webView: webView,
            description: "error message")
        #expect(try store.sourceContent(versionID: version.id) == bytes)
    }

    private struct MountedSession {
        let session: @MainActor () -> WikiAppWebViewSession?
        let teardown: @MainActor () -> Void
    }

    private static func makeMount(
        package: ValidatedRendererPackage,
        descriptor: RendererDescriptor,
        entryURL: URL,
        reader: RendererAuthorizedInputReader
    ) throws -> MountedSession {
        let provider = try ValidatedRendererPackageResourceProvider(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            expectedPackageHash: package.packageHash,
            installedRoot: package.stagedRoot,
            validatedPackage: package)
        let reservation = RendererPackageReservation(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version)
        var liveSession: WikiAppWebViewSession?
        let view = WikiAppWebView(
            identity: .init(rendererReference: descriptor.reference, entryURL: entryURL),
            makeSession: { _, reportFailure in
                let session = WikiAppWebViewSession(
                    entryURL: entryURL,
                    resourceProvider: provider,
                    installedPackage: reservation,
                    lifecycleFailureHandler: reportFailure,
                    bridgeFactory: { sessionID in
                        RendererContentWorldBroker(
                            sessionID: sessionID,
                            capability: .init(rawValue: UUID().uuidString),
                            inputReader: reader,
                            expectedOrigin: entryURL)
                    },
                    externalActivationPolicy: .enabled)
                liveSession = session
                return session
            },
            onFailure: { failure in
                Issue.record("JSON Canvas session failed: \(failure.kind)")
            })
        let host = NSHostingController(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.orderFront(nil)

        return MountedSession(
            session: { liveSession },
            teardown: {
                host.rootView = AnyView(EmptyView())
                liveSession?.close()
                window.orderOut(nil)
                window.contentView = nil
            })
    }

    private static func wait(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                throw JSONCanvasHostedTestError.timeout(description)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func waitForJavaScript(
        _ source: String,
        expected: String,
        webView: WKWebView,
        description: String
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if await evaluateJavaScriptWithTimeout(webView, source) == expected { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        throw JSONCanvasHostedTestError.timeout(description)
    }
}

private enum JSONCanvasHostedTestError: Error {
    case timeout(String)
}

private struct JSONCanvasHostedFixture {
    let root: URL
    let directory: URL
    let validator: RendererPackageValidator

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/JSONCanvasHosted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/JSONCanvas")
        validator = RendererPackageValidator(packageRoot: root)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("JSON Canvas hosted fixture cleanup failed: \(error)") }
    }
}

private extension RendererDescriptor {
    var webEntryPoint: RendererWebEntryPoint? {
        if case let .webPackage(entryPoint) = implementation { return entryPoint }
        return nil
    }
}
#endif
