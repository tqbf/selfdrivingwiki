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

    @Test("colored edges render with matching stroke and colored arrowhead markers")
    func coloredEdgesRenderWithColorAndMarkers() async throws {
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
        // One colored edge (preset "1" red) with an arrow; one hex-colored
        // edge with both-arrow; one default edge.
        let bytes = Data(##"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":100,"height":50,"text":"A"},{"id":"b","type":"text","x":250,"y":0,"width":100,"height":50,"text":"B"},{"id":"c","type":"text","x":500,"y":0,"width":100,"height":50,"text":"C"}],"edges":[{"id":"red","fromNode":"a","toNode":"b","fromSide":"right","toSide":"left","toEnd":"arrow","color":"1"},{"id":"hex","fromNode":"b","toNode":"c","fromSide":"right","toSide":"left","fromEnd":"arrow","toEnd":"arrow","color":"#059669"},{"id":"plain","fromNode":"a","toNode":"c","label":"plain"}]}"##.utf8)
        let document = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01JHOSTEDJSONCANVASP000001"),
            pageVersionID: PageVersionID(rawValue: "01JHOSTEDJSONCANVASV0000001"))
        let block = try MarkdownFencedBlock(
            documentIdentity: document, parserOrdinal: 0, rawInfoString: "jsoncanvas", bytes: bytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: document.pageID,
            pageVersionID: document.pageVersionID,
            blockID: try #require(block.blockID),
            fenceAlias: try RendererFenceAlias(validating: "jsoncanvas"),
            mimeType: try RendererMIMEType(validating: "application/json"),
            bytes: bytes)
        let reader = RendererAuthorizedInputReader(
            store: try GRDBWikiStore(), authorizedInput: .inlineArtifact(artifact))
        let mount = try Self.makeMount(
            package: package, descriptor: descriptor, entryURL: entryURL, reader: reader)
        defer { mount.teardown() }

        try await Self.wait("session") { mount.session() != nil }
        let session = try #require(mount.session())
        try await Self.wait("ready") { if case .ready = session.state { return true }; return false }
        let webView = try #require(session.webView)
        try await Self.waitForJavaScript(
            "document.querySelectorAll('svg.scene path.edge').length === 3 ? 'ok' : 'pending'",
            expected: "ok", webView: webView, description: "three edges")

        let semantics = await evaluateJavaScriptWithTimeout(webView, """
        JSON.stringify({
          colors: Array.from(document.querySelectorAll('svg.scene path.edge')).map(function (p) {
            return getComputedStyle(p).stroke;
          }),
          strokes: Array.from(document.querySelectorAll('svg.scene path.edge')).map(function (p) {
            return p.getAttribute('stroke') || '';
          }),
          defaultClasses: Array.from(document.querySelectorAll('svg.scene path.edge')).map(function (p) {
            return p.classList.contains('edge-default');
          }),
          markers: Array.from(document.querySelectorAll('svg.scene path.edge')).map(function (p) {
            return (p.getAttribute('marker-end') || '') + (p.getAttribute('marker-start') || '');
          }),
          markerDefs: Array.from(document.querySelectorAll('svg.scene defs marker')).map(function (m) {
            var arrow = m.querySelector('path');
            return JSON.stringify({
              color: m.getAttribute('color') || 'css-default',
              orient: m.getAttribute('orient'),
              fill: arrow ? getComputedStyle(arrow).fill : ''
            });
          })
        })
        """)
        #expect(semantics?.contains("rgb(224, 49, 49)") == true)        // preset 1 -> red
        #expect(semantics?.contains("rgb(5, 150, 105)") == true)        // hex edge
        #expect(semantics?.contains("#e03131") == true)
        #expect(semantics?.contains("#059669") == true)
        #expect(semantics?.contains("\"defaultClasses\":[false,false,true]") == true)
        #expect(semantics?.contains("css-default") == true)              // default edge keeps CSS gray
        // The hex dual-arrow edge must reference the SAME marker at both ends.
        #expect(semantics?.contains("url(#sdw-arrowhead-") == true)
        // Start markers reverse their orientation so arrows point outward from
        // the source node, while end markers retain the path direction.
        #expect(semantics?.contains("auto-start-reverse") == true)
        // The colored marker paths carry the resolved color directly; they do
        // not depend on currentColor inheritance through <marker>.
        #expect(semantics?.contains("fill\\\":\\\"rgb(5, 150, 105)") == true)
    }

    @Test("colored edge stems and arrowheads paint the same pixels")
    func coloredEdgeStemsAndArrowheadsPaintMatchingPixels() async throws {
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
        let bytes = Data(##"{"nodes":[{"id":"4000000000000001","type":"text","x":0,"y":180,"width":220,"height":100,"text":"Left"},{"id":"4000000000000002","type":"text","x":340,"y":180,"width":240,"height":100,"color":"3","text":"Center"},{"id":"4000000000000003","type":"text","x":700,"y":180,"width":220,"height":100,"text":"Right"},{"id":"4000000000000004","type":"text","x":340,"y":0,"width":240,"height":100,"text":"Top"},{"id":"4000000000000005","type":"text","x":340,"y":360,"width":240,"height":100,"text":"Bottom"}],"edges":[{"id":"4e00000000000001","fromNode":"4000000000000001","fromSide":"right","fromEnd":"none","toNode":"4000000000000002","toSide":"left","toEnd":"arrow","color":"1","label":"right to left"},{"id":"4e00000000000002","fromNode":"4000000000000004","fromSide":"bottom","fromEnd":"arrow","toNode":"4000000000000002","toSide":"top","toEnd":"none","color":"2","label":"bottom to top"},{"id":"4e00000000000003","fromNode":"4000000000000002","fromSide":"bottom","fromEnd":"none","toNode":"4000000000000005","toSide":"top","toEnd":"arrow","color":"#059669","label":"downward"},{"id":"4e00000000000004","fromNode":"4000000000000002","fromSide":"right","fromEnd":"arrow","toNode":"4000000000000003","toSide":"left","toEnd":"arrow","color":"6","label":"two arrows"},{"id":"4e00000000000005","fromNode":"4000000000000001","toNode":"4000000000000005"}]}"##.utf8)
        let document = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01JHOSTEDJSONCANVASP000001"),
            pageVersionID: PageVersionID(rawValue: "01JHOSTEDJSONCANVASV0000001"))
        let block = try MarkdownFencedBlock(
            documentIdentity: document, parserOrdinal: 0, rawInfoString: "jsoncanvas", bytes: bytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: document.pageID,
            pageVersionID: document.pageVersionID,
            blockID: try #require(block.blockID),
            fenceAlias: try RendererFenceAlias(validating: "jsoncanvas"),
            mimeType: try RendererMIMEType(validating: "application/json"),
            bytes: bytes)
        let reader = RendererAuthorizedInputReader(
            store: try GRDBWikiStore(), authorizedInput: .inlineArtifact(artifact))
        let mount = try Self.makeMount(
            package: package,
            descriptor: descriptor,
            entryURL: entryURL,
            reader: reader,
            size: NSSize(width: 1_024, height: 640))
        defer { mount.teardown() }

        try await Self.wait("session") { mount.session() != nil }
        let session = try #require(mount.session())
        try await Self.wait("ready") { if case .ready = session.state { return true }; return false }
        let webView = try #require(session.webView)
        webView.frame = NSRect(x: 0, y: 0, width: 1_024, height: 640)
        webView.layoutSubtreeIfNeeded()
        try await Self.wait("web view layout") {
            webView.bounds.width > 0 && webView.bounds.height > 0
        }
        try await Self.waitForJavaScript(
            "document.querySelectorAll('svg.scene path.edge').length === 5 ? 'ok' : 'pending'",
            expected: "ok", webView: webView, description: "five painted edges")
        let deterministicView = await evaluateJavaScriptWithTimeout(webView, """
        (function () {
          const layer = document.querySelector('svg.scene g.scene-layer');
          if (!layer) return 'missing';
          layer.setAttribute('transform', 'translate(52 90) scale(1)');
          return window.innerWidth > 0 && window.innerHeight > 0 ? 'ok' : 'zero';
        })()
        """)
        #expect(deterministicView == "ok")

        let probeJSON = try #require(await evaluateJavaScriptWithTimeout(webView, """
        JSON.stringify(Array.from(document.querySelectorAll('svg.scene path.edge')).map(function (path) {
          const length = path.getTotalLength();
          const matrix = path.getScreenCTM();
          function pointAt(fraction) {
            const local = path.getPointAtLength(length * fraction);
            const screen = new DOMPoint(local.x, local.y).matrixTransform(matrix);
            return { x: screen.x, y: screen.y };
          }
          function markerWings(tip, inner) {
            const dx = inner.x - tip.x;
            const dy = inner.y - tip.y;
            const magnitude = Math.hypot(dx, dy) || 1;
            const ux = dx / magnitude;
            const uy = dy / magnitude;
            return [
              { x: tip.x + ux * 6 - uy * 2, y: tip.y + uy * 6 + ux * 2 },
              { x: tip.x + ux * 6 + uy * 2, y: tip.y + uy * 6 - ux * 2 }
            ];
          }
          const start = pointAt(0);
          const end = pointAt(1);
          return {
            stem: pointAt(0.25),
            startWings: markerWings(start, pointAt(0.05)),
            endWings: markerWings(end, pointAt(0.95))
          };
        }))
        """))
        let probes = try JSONDecoder().decode([JSONCanvasPaintProbe].self, from: Data(probeJSON.utf8))
        #expect(probes.count == 5)

        let image = try await Self.takeSnapshot(of: webView, timeout: .seconds(15))
        let bitmap = try Self.bitmap(from: image)
        let expectations: [JSONCanvasPaintExpectation] = [
            .init(edgeIndex: 0, color: .init(red: 224, green: 49, blue: 49), arrowFractions: [.end]),
            .init(edgeIndex: 1, color: .init(red: 240, green: 140, blue: 0), arrowFractions: [.start]),
            // The later default diagonal edge shares and paints over this
            // edge's destination marker. Its marker is sampled separately
            // after hiding only that occluding path.
            .init(edgeIndex: 2, color: .init(red: 5, green: 150, blue: 105), arrowFractions: []),
            .init(edgeIndex: 3, color: .init(red: 112, green: 72, blue: 232), arrowFractions: [.start, .end])
        ]
        var failures: [String] = []
        for expectation in expectations {
            let probe = try #require(probes[safe: expectation.edgeIndex])
            let stemCount = Self.matchingPixelCount(
                near: probe.stem, radius: 5, expected: expectation.color,
                bitmap: bitmap, webViewBounds: webView.bounds)
            if stemCount < 2 {
                failures.append("edge \(expectation.edgeIndex) stem had \(stemCount) matching pixels")
            }
            for fraction in expectation.arrowFractions {
                // Probe the triangle wings off the centerline, so
                // a correctly colored stem cannot make a gray marker pass.
                let points = fraction == .start ? probe.startWings : probe.endWings
                let arrowCount = points.reduce(into: 0) { count, point in
                    count += Self.matchingPixelCount(
                        near: point, radius: 2, expected: expectation.color,
                        bitmap: bitmap, webViewBounds: webView.bounds)
                }
                if arrowCount < 2 {
                    failures.append("edge \(expectation.edgeIndex) \(fraction.rawValue) arrow had \(arrowCount) matching pixels")
                }
            }
        }

        let unoccludedResult = await evaluateJavaScriptWithTimeout(webView, """
        (function () {
          const paths = document.querySelectorAll('svg.scene path.edge');
          if (paths.length !== 5) return 'missing';
          paths[4].style.display = 'none';
          return getComputedStyle(paths[4]).display === 'none' ? 'hidden' : 'visible';
        })()
        """)
        #expect(unoccludedResult == "hidden")
        let unoccludedImage = try await Self.takeSnapshot(of: webView, timeout: .seconds(15))
        let unoccludedBitmap = try Self.bitmap(from: unoccludedImage)
        let greenProbe = try #require(probes[safe: 2])
        let green = JSONCanvasRGB(red: 5, green: 150, blue: 105)
        let greenArrowCount = greenProbe.endWings.reduce(into: 0) { count, point in
            count += Self.matchingPixelCount(
                near: point, radius: 2, expected: green,
                bitmap: unoccludedBitmap, webViewBounds: webView.bounds)
        }
        if greenArrowCount < 2 {
            failures.append("edge 2 unoccluded end arrow had \(greenArrowCount) matching pixels")
        }

        if failures.isEmpty == false {
            Self.writeDiagnosticPNG(image, named: "JSONCanvas-edge-paint-failure")
            Self.writeDiagnosticPNG(unoccludedImage, named: "JSONCanvas-edge-paint-unoccluded-failure")
        }
        #expect(failures.isEmpty, "Rendered SVG pixel mismatch: \(failures.joined(separator: "; "))")
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
        reader: RendererAuthorizedInputReader,
        size: NSSize = NSSize(width: 720, height: 480)
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
            contentRect: NSRect(origin: .zero, size: size),
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

    private static func takeSnapshot(of webView: WKWebView, timeout: Duration) async throws -> NSImage {
        final class Once: @unchecked Sendable {
            private var fired = false
            private let lock = NSLock()

            func fire(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard fired == false else { return }
                fired = true
                body()
            }
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.afterScreenUpdates = true
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                    once.fire { continuation.resume(throwing: JSONCanvasHostedTestError.snapshotTimeout) }
                } catch {
                    // WebKit won the one-shot race and cancelled the timer.
                }
            }
            webView.takeSnapshot(with: configuration) { image, error in
                once.fire {
                    timeoutTask.cancel()
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? JSONCanvasHostedTestError.missingSnapshot)
                    }
                }
            }
        }
    }

    private static func bitmap(from image: NSImage) throws -> NSBitmapImageRep {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return NSBitmapImageRep(cgImage: cgImage)
        }
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }

    private static func matchingPixelCount(
        near point: JSONCanvasPaintPoint,
        radius: CGFloat,
        expected: JSONCanvasRGB,
        bitmap: NSBitmapImageRep,
        webViewBounds: CGRect
    ) -> Int {
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              webViewBounds.width > 0, webViewBounds.height > 0 else { return 0 }
        let scaleX = CGFloat(bitmap.pixelsWide) / webViewBounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / webViewBounds.height
        let centerX = point.x * scaleX
        // NSBitmapImageRep.colorAt(x:y:) addresses this WebKit snapshot from
        // its top-left, matching DOM viewport coordinates.
        let centerY = point.y * scaleY
        let pixelRadiusX = max(1, Int((radius * scaleX).rounded(.up)))
        let pixelRadiusY = max(1, Int((radius * scaleY).rounded(.up)))
        let minimumX = max(0, Int(centerX.rounded()) - pixelRadiusX)
        let maximumX = min(bitmap.pixelsWide - 1, Int(centerX.rounded()) + pixelRadiusX)
        let minimumY = max(0, Int(centerY.rounded()) - pixelRadiusY)
        let maximumY = min(bitmap.pixelsHigh - 1, Int(centerY.rounded()) + pixelRadiusY)
        guard minimumX <= maximumX, minimumY <= maximumY else { return 0 }

        var count = 0
        for y in minimumY...maximumY {
            for x in minimumX...maximumX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let pixel = JSONCanvasRGB(
                    red: Int((color.redComponent * 255).rounded()),
                    green: Int((color.greenComponent * 255).rounded()),
                    blue: Int((color.blueComponent * 255).rounded()))
                if pixel.isNear(expected, tolerance: 45) { count += 1 }
            }
        }
        return count
    }

    private static func writeDiagnosticPNG(_ image: NSImage, named name: String) {
        do {
            let bitmap = try bitmap(from: image)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("\(name)-\(UUID().uuidString).png"))
        } catch {
            Issue.record("Could not write JSON Canvas diagnostic snapshot: \(error)")
        }
    }
}

private enum JSONCanvasHostedTestError: Error {
    case timeout(String)
    case snapshotTimeout
    case missingSnapshot
}

private struct JSONCanvasPaintPoint: Decodable {
    let x: CGFloat
    let y: CGFloat
}

private struct JSONCanvasPaintProbe: Decodable {
    let stem: JSONCanvasPaintPoint
    let startWings: [JSONCanvasPaintPoint]
    let endWings: [JSONCanvasPaintPoint]
}

private enum JSONCanvasArrowFraction: String {
    case start
    case end
}

private struct JSONCanvasPaintExpectation {
    let edgeIndex: Int
    let color: JSONCanvasRGB
    let arrowFractions: [JSONCanvasArrowFraction]
}

private struct JSONCanvasRGB {
    let red: Int
    let green: Int
    let blue: Int

    func isNear(_ other: Self, tolerance: Int) -> Bool {
        abs(red - other.red) <= tolerance
            && abs(green - other.green) <= tolerance
            && abs(blue - other.blue) <= tolerance
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
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
