#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import WikiFS
@testable import WikiFSCore

@Suite("Renderer attachment spike hosted tests", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct RendererAttachmentSpikeHostedTests {
    private static let bottomSpacerParagraphCount = 24

    @Test
    func testScrollZoomResizeAndHeightMutationStayAligned() async throws {
        for _ in 0..<20 {
            var alignmentEvidences: [RendererAttachmentSpikeAlignmentEvidence] = []
            let lease = await HostedAppKitTestGate.shared.acquire()
            defer { lease.release() }
            Self.prepareApplication()

            let harness = RendererAttachmentSpikeHarness(
                windowSize: NSSize(width: 820, height: 520),
                markdown: Self.scenarioMarkdown(includeBottomSpacer: true))
            let window = harness.window
            window.orderFrontRegardless()
            defer {
                harness.teardown()
                window.orderOut(nil as Any?)
            }

            try await harness.load()
            try await harness.publishGeometry()
            let initial = try harness.requireGeometry()
            let initialSnapshot = try #require(harness.currentSnapshot)
            let initialMeasurement = try await harness.measureDOMGeometry()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                measurement: initialMeasurement,
                pageZoom: harness.webView.pageZoom,
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                webViewBounds: harness.webView.bounds)
            )
            Self.assertIndependentDOM(initialSnapshot, measurement: initialMeasurement, expectedCenterHit: true)
            #expect(initial.revision == initialSnapshot.revision)

            let centeredScroll = max(0, initial.cssRect.minY - (harness.webView.bounds.height * 0.45))
            try await harness.scrollTo(y: centeredScroll)
            try await harness.publishGeometry()
            let centered = try harness.requireGeometry()
            let centeredSnapshot = try #require(harness.currentSnapshot)
            let centeredMeasurement = try await harness.measureDOMGeometry()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                measurement: centeredMeasurement,
                pageZoom: harness.webView.pageZoom,
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                webViewBounds: harness.webView.bounds)
            )
            Self.assertIndependentDOM(centeredSnapshot, measurement: centeredMeasurement, expectedCenterHit: true)
            #expect(centered.domCenterHit)
            #expect(centered.revision > initial.revision)

            try await harness.scrollTo(y: 220)
            try await harness.publishGeometry()
            let scrolled = try harness.requireGeometry()
            let scrolledSnapshot = try #require(harness.currentSnapshot)
            let scrolledMeasurement = try await harness.measureDOMGeometry()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                measurement: scrolledMeasurement,
                pageZoom: harness.webView.pageZoom,
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                webViewBounds: harness.webView.bounds)
            )
            Self.assertIndependentDOM(scrolledSnapshot, measurement: scrolledMeasurement, expectedCenterHit: true)
            #expect(scrolled.revision > centered.revision)

            harness.webView.pageZoom = 1.25
            try await harness.updateRuntimeState()
            try await harness.publishGeometry()
            let zoomed = try harness.requireGeometry()
            let zoomedSnapshot = try #require(harness.currentSnapshot)
            let zoomedMeasurement = try await harness.measureDOMGeometry()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                measurement: zoomedMeasurement,
                pageZoom: harness.webView.pageZoom,
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                webViewBounds: harness.webView.bounds)
            )
            Self.assertIndependentDOM(zoomedSnapshot, measurement: zoomedMeasurement, expectedCenterHit: true)
            #expect(zoomed.revision > scrolled.revision)

            window.setContentSize(NSSize(width: 920, height: 580))
            harness.containerView.layoutSubtreeIfNeeded()
            try await harness.publishGeometry()
            let resized = try harness.requireGeometry()
            _ = try #require(harness.currentSnapshot)
            let resizedMeasurement = try await harness.measureDOMGeometry()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                measurement: resizedMeasurement,
                pageZoom: harness.webView.pageZoom,
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                webViewBounds: harness.webView.bounds)
            )
            #expect(resized.revision > zoomed.revision)

            try await harness.insertSpacerBeforePlaceholder(height: 96)
            try await harness.publishGeometry()
            let mutated = try harness.requireGeometry()
            let mutatedSnapshot = try #require(harness.currentSnapshot)
            let mutatedMeasurement = try await harness.measureDOMGeometry()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                measurement: mutatedMeasurement,
                pageZoom: harness.webView.pageZoom,
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                webViewBounds: harness.webView.bounds)
            )
            Self.assertIndependentDOM(mutatedSnapshot, measurement: mutatedMeasurement, expectedCenterHit: true)
            #expect(mutated.revision == mutatedSnapshot.revision)
            #expect(mutated.revision > resized.revision)

            let tolerance = RendererAttachmentSpikeMetrics.derivedAlignmentTolerance(
                pointResiduals: alignmentEvidences.flatMap { $0.pointResiduals },
                backingResiduals: alignmentEvidences.flatMap { $0.backingResiduals },
                backingScaleFactor: window.backingScaleFactor)
            Self.assertAlignmentEvidence(
                alignmentEvidences,
                tolerance: tolerance,
                backingScaleFactor: window.backingScaleFactor)
        }
    }

    @Test
    func testClippingAndHitTestingRespectVisiblePlaceholder() async throws {
        for _ in 0..<20 {
            var alignmentEvidences: [RendererAttachmentSpikeAlignmentEvidence] = []
            let lease = await HostedAppKitTestGate.shared.acquire()
            defer { lease.release() }
            Self.prepareApplication()

            let harness = RendererAttachmentSpikeHarness(
                windowSize: NSSize(width: 760, height: 420),
                markdown: Self.scenarioMarkdown(includeBottomSpacer: true))
            let window = harness.window
            window.orderFrontRegardless()
            defer {
                harness.teardown()
                window.orderOut(nil as Any?)
            }

            try await harness.load()
            try await harness.publishGeometry()
            let baseline = try harness.requireGeometry()
            let targetScroll = max(0, baseline.cssRect.minY - (harness.webView.bounds.height - 24))
            try await harness.scrollTo(y: targetScroll)
            try await harness.publishGeometry()
            let geometry = try harness.requireGeometry()
            let geometrySnapshot = try #require(harness.currentSnapshot)
            let geometryMeasurement = try await harness.measureDOMGeometry()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                measurement: geometryMeasurement,
                pageZoom: harness.webView.pageZoom,
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                webViewBounds: harness.webView.bounds))

            #expect(geometry.clipRect.isEmpty == false)
            #expect(geometry.clipRect != geometry.overlayRect)
            #expect(harness.overlay.visibleClipRect == geometry.localClipRect)
            Self.assertIndependentDOM(geometrySnapshot, measurement: geometryMeasurement, expectedCenterHit: true)

            let visible = geometry.localClipRect
            let insidePoint = NSPoint(x: visible.midX, y: visible.midY)
            let outsidePoint = RendererAttachmentSpikeHostedTests.outsidePoint(
                overlayBounds: harness.overlay.bounds,
                visibleClip: visible)
            let insideWindowPoint = harness.overlay.convert(insidePoint, to: harness.containerView)
            let outsideWindowPoint = harness.overlay.convert(outsidePoint, to: harness.containerView)

            let routedInside = harness.containerView.hitTest(insideWindowPoint)
            #expect(routedInside === harness.overlay)
            let insideHit = harness.overlay.hitTest(insideWindowPoint)
            #expect(insideHit === harness.overlay)
            #expect(harness.overlay.hitTest(outsideWindowPoint) == nil)

            let routedView = harness.containerView.hitTest(outsideWindowPoint)
            #expect(routedView !== harness.overlay)

            let offscreenScroll = max(0, geometry.scrollY + geometry.cssRect.maxY + 80)
            try await harness.scrollTo(y: offscreenScroll)
            try await harness.publishGeometry()
            let offscreen = try harness.requireGeometry()
            let offscreenSnapshot = try #require(harness.currentSnapshot)
            let offscreenMeasurement = try await harness.measureDOMGeometry()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                measurement: offscreenMeasurement,
                pageZoom: harness.webView.pageZoom,
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                webViewBounds: harness.webView.bounds))
            #expect(offscreen.clipRect.isEmpty)
            #expect(offscreen.domCenterHit == false)
            #expect(harness.overlay.visibleClipRect.isEmpty)
            #expect(harness.overlay.hitTest(NSPoint(x: 1, y: 1)) == nil)
            #expect(offscreenSnapshot.scrollY > geometry.scrollY)
            Self.assertIndependentDOM(
                offscreenSnapshot,
                measurement: offscreenMeasurement,
                expectedCenterHit: false)

            let tolerance = RendererAttachmentSpikeMetrics.derivedAlignmentTolerance(
                pointResiduals: alignmentEvidences.flatMap { $0.pointResiduals },
                backingResiduals: alignmentEvidences.flatMap { $0.backingResiduals },
                backingScaleFactor: window.backingScaleFactor)
            Self.assertAlignmentEvidence(
                alignmentEvidences,
                tolerance: tolerance,
                backingScaleFactor: window.backingScaleFactor)
        }
    }

    @Test
    func testStaleGenerationAndTeardownCannotReviveAttachment() async throws {
        for _ in 0..<20 {
            let lease = await HostedAppKitTestGate.shared.acquire()
            defer { lease.release() }
            Self.prepareApplication()

            let harness = RendererAttachmentSpikeHarness(
                windowSize: NSSize(width: 780, height: 460),
                markdown: Self.scenarioMarkdown(includeBottomSpacer: true))
            let window = harness.window
            window.orderFrontRegardless()
            defer {
                harness.teardown()
                window.orderOut(nil as Any?)
            }

            try await harness.load()
            try await harness.publishGeometry()
            let generation1 = try harness.requireGeometry()

            try await harness.reload(markdown: Self.scenarioMarkdown(includeBottomSpacer: true))
            try await harness.publishGeometry()
            let generation2 = try harness.requireGeometry()

            harness.ingest(Self.snapshot(from: generation1))
            #expect(harness.currentGeometry?.generation == generation2.generation)

            window.setContentSize(NSSize(width: 860, height: 500))
            harness.containerView.layoutSubtreeIfNeeded()
            try await harness.publishGeometry()
            let generation3 = try harness.requireGeometry()

            let frameBeforeStaleResize = harness.overlay.frame
            let revisionBeforeStaleResize = try #require(harness.currentSnapshot).revision
            #expect(generation2.revision < generation3.revision)
            harness.ingest(Self.snapshot(from: generation2))
            #expect(harness.currentGeometry?.generation == generation3.generation)
            let currentAfterStaleResize = try #require(harness.currentSnapshot)
            #expect(currentAfterStaleResize.revision == revisionBeforeStaleResize)
            #expect(harness.overlay.frame == frameBeforeStaleResize)

            try await harness.reload(markdown: Self.scenarioMarkdown(includePlaceholder: false, includeBottomSpacer: false))
            try await harness.publishGeometry()
            let removed = try #require(harness.currentSnapshot)
            #expect(removed.present == false)
            #expect(harness.currentGeometry == nil)
            #expect(harness.overlay.isHidden)

            harness.ingest(Self.snapshot(from: generation3))
            #expect(harness.currentGeometry == nil)
            #expect(harness.overlay.isHidden)

            harness.teardown()
            harness.ingest(Self.snapshot(from: generation3))
            #expect(harness.currentGeometry == nil)
            #expect(harness.overlay.superview == nil || harness.overlay.isHidden)
        }
    }

    private static func scenarioMarkdown(
        includePlaceholder: Bool = true,
        includeBottomSpacer: Bool
    ) -> String {
        let top = (0..<28).map { index in
            "Paragraph \(index): " + String(repeating: "This keeps the document tall enough for scroll alignment. ", count: 2)
        }.joined(separator: "\n\n")
        let bottom = includeBottomSpacer
            ? String(
                repeating: "Trailing content keeps the placeholder in flow.\n\n",
                count: bottomSpacerParagraphCount)
            : ""
        let placeholder = includePlaceholder
            ? """

        ```jsoncanvas
        {"nodes":[{"id":"node-1","type":"text","x":24,"y":28,"width":180,"height":80,"text":"Attachment placeholder"}],"edges":[]}
        ```
        """
            : ""
        return """
        # Reader spike

        \(top)
        \(placeholder)

        \(bottom)
        """
    }

    private static func assertIndependentDOM(
        _ snapshot: RendererAttachmentSpikeSnapshot?,
        measurement: RendererAttachmentSpikeDOMMeasurement,
        expectedCenterHit: Bool,
        expectedPresent: Bool = true
    ) {
        guard let snapshot else {
            Issue.record("missing independent DOM snapshot")
            return
        }
        #expect(snapshot.revision > 0)
        #expect(measurement.present == expectedPresent)
        #expect(measurement.centerHit == expectedCenterHit)
        #expect(measurement.scrollY >= 0)
        if expectedPresent {
            #expect(measurement.placeholderID == snapshot.placeholderID)
        } else {
            #expect(measurement.placeholderID.isEmpty)
        }
    }

    private static func alignmentEvidence(
        _ actual: CGRect,
        measurement: RendererAttachmentSpikeDOMMeasurement,
        pageZoom: CGFloat,
        containerView: NSView,
        backingScaleFactor: CGFloat,
        webViewBounds: CGRect
    ) -> RendererAttachmentSpikeAlignmentEvidence {
        let expected = RendererAttachmentSpikeGeometry(
            generation: 0,
            revision: 0,
            placeholderID: measurement.placeholderID,
            cssRect: measurement.cssRect,
            pageZoom: pageZoom,
            domCenterHit: measurement.centerHit,
            scrollY: measurement.scrollY,
            backingScaleFactor: backingScaleFactor,
            webViewBounds: webViewBounds)
        let expectedBacking = containerView.convertToBacking(expected.overlayRect)
        let actualBacking = containerView.convertToBacking(actual)
        return RendererAttachmentSpikeAlignmentEvidence(
            pointResiduals: [
                abs(actual.minX - expected.overlayRect.minX),
                abs(actual.minY - expected.overlayRect.minY),
                abs(actual.width - expected.overlayRect.width),
                abs(actual.height - expected.overlayRect.height)
            ],
            backingResiduals: [
                abs(actualBacking.minX - expectedBacking.minX),
                abs(actualBacking.minY - expectedBacking.minY),
                abs(actualBacking.width - expectedBacking.width),
                abs(actualBacking.height - expectedBacking.height)
            ])
    }

    private static func assertAlignmentEvidence(
        _ evidences: [RendererAttachmentSpikeAlignmentEvidence],
        tolerance: CGFloat,
        backingScaleFactor: CGFloat
    ) {
        for evidence in evidences {
            #expect(evidence.maxPointResidual <= tolerance)
            #expect(evidence.maxBackingResidual / max(backingScaleFactor, .leastNonzeroMagnitude) <= tolerance)
        }
    }

    private static func snapshot(from geometry: RendererAttachmentSpikeGeometry) -> RendererAttachmentSpikeSnapshot {
        RendererAttachmentSpikeSnapshot(
            generation: geometry.generation,
            revision: geometry.revision,
            placeholderID: geometry.placeholderID,
            present: true,
            cssRect: geometry.cssRect,
            centerHit: geometry.domCenterHit,
            scrollY: geometry.scrollY)
    }

    private static func outsidePoint(overlayBounds: CGRect, visibleClip: CGRect) -> NSPoint {
        let probes: [NSPoint] = [
            NSPoint(x: visibleClip.midX, y: visibleClip.minY - 2),
            NSPoint(x: visibleClip.midX, y: visibleClip.maxY + 2),
            NSPoint(x: visibleClip.minX - 2, y: visibleClip.midY),
            NSPoint(x: visibleClip.maxX + 2, y: visibleClip.midY)
        ]
        for probe in probes where overlayBounds.contains(probe) {
            if visibleClip.contains(probe) == false {
                return probe
            }
        }
        return NSPoint(x: max(0, visibleClip.maxX + 2), y: max(0, visibleClip.minY + 2))
    }

    private static func prepareApplication() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
    }
}

@MainActor
private final class RendererAttachmentSpikeHarness: NSObject, WKNavigationDelegate {
    static let messageName = "rendererAttachmentSpike"
    private static let cardSelector = "section.sdw-renderer-card"
    private static let probeScript = makeProbeScript()

    let containerView: NSView
    let webView: WikiReaderWebView
    let overlay = RendererAttachmentSpikeOverlayView(frame: .zero)
    private let bridge = RendererAttachmentSpikeBridge()
    let window: NSWindow
    private let markdown: String
    private let documentIdentity = MarkdownDocumentIdentity(
        pageID: .init(rawValue: "01HTESTPAGE000000000000001"),
        pageVersionID: .init(rawValue: "01HTESTPV00000000000000001"))

    private(set) var currentGeometry: RendererAttachmentSpikeGeometry?
    private(set) var currentSnapshot: RendererAttachmentSpikeSnapshot?
    private(set) var didFinishLoad = false
    private(set) var generation = 0
    private(set) var currentRevision = 0
    private(set) var isTornDown = false

    init(windowSize: NSSize, markdown: String) {
        self.markdown = markdown
        containerView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        webView = WikiReaderWebView()
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        super.init()

        bridge.host = self
        let controller = webView.configuration.userContentController
        controller.add(bridge, name: Self.messageName)
        controller.addUserScript(WKUserScript(
            source: Self.probeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))

        webView.navigationDelegate = self
        webView.pageZoom = Double(ZoomScale.defaultScale)
        webView.autoresizingMask = [.width, .height]
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        containerView.addSubview(webView)
        containerView.addSubview(overlay)
        webView.frame = containerView.bounds
        overlay.frame = containerView.bounds
        window.contentView = containerView
    }

    func load() async throws {
        generation = 1
        didFinishLoad = false
        currentGeometry = nil
        currentSnapshot = nil
        currentRevision = 0
        webView.pageZoom = Double(ZoomScale.defaultScale)
        webView.loadHTMLString(Self.html(for: markdown, documentIdentity: documentIdentity), baseURL: WikiReaderOrigin.url)
        try await Self.waitFor(description: "reader web view load") { [weak self] in
            self?.didFinishLoad == true
        }
        try await updateRuntimeState()
    }

    func reload(markdown: String) async throws {
        generation += 1
        didFinishLoad = false
        currentGeometry = nil
        currentSnapshot = nil
        currentRevision = 0
        webView.loadHTMLString(Self.html(for: markdown, documentIdentity: documentIdentity), baseURL: WikiReaderOrigin.url)
        try await Self.waitFor(description: "reader web view reload") { [weak self] in
            self?.didFinishLoad == true
        }
        try await updateRuntimeState()
    }

    func publishGeometry() async throws {
        let minimumRevision = currentRevision + 1
        _ = await evaluateJavaScriptWithTimeout(webView, "window.__rendererAttachmentSpikeReport ? window.__rendererAttachmentSpikeReport() : 'missing'")
        try await Self.waitFor(description: "renderer attachment geometry") { [weak self] in
            (self?.currentSnapshot?.revision ?? 0) >= minimumRevision
        }
    }

    func measureDOMGeometry() async throws -> RendererAttachmentSpikeDOMMeasurement {
        let body = await evaluateJavaScriptWithTimeout(webView, """
        (function(){
          var card = document.querySelector('\(Self.cardSelector)');
          var scrollY = window.scrollY || document.documentElement.scrollTop || 0;
          var viewport = (function(){
            var visual = window.visualViewport;
            var left = visual ? visual.offsetLeft : 0;
            var top = visual ? visual.offsetTop : 0;
            var width = visual ? visual.width : (window.innerWidth || document.documentElement.clientWidth || 0);
            var height = visual ? visual.height : (window.innerHeight || document.documentElement.clientHeight || 0);
            return { left: left, top: top, right: left + width, bottom: top + height };
          })();
          function hitAt(x, y) {
            var rect = paintedTextRect();
            return !!rect && x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
          }
          function paintedTextRect() {
            if(!card){ return null; }
            var walker = document.createTreeWalker(card, NodeFilter.SHOW_TEXT);
            while(walker.nextNode()){
              var textNode = walker.currentNode;
              if(!textNode || !textNode.textContent || !textNode.textContent.trim()){
                continue;
              }
              var range = document.createRange();
              range.selectNodeContents(textNode);
              var rects = range.getClientRects();
              for(var i = 0; i < rects.length; i++){
                var rect = rects[i];
                var left = Math.max(rect.left, viewport.left);
                var top = Math.max(rect.top, viewport.top);
                var right = Math.min(rect.right, viewport.right);
                var bottom = Math.min(rect.bottom, viewport.bottom);
                if(right > left && bottom > top){
                  return rect;
                }
              }
            }
            return null;
          }
          function visibleHit() {
            var textRect = paintedTextRect();
            if(!textRect){
              return false;
            }
            return textRect.right > viewport.left &&
                   textRect.left < viewport.right &&
                   textRect.bottom > viewport.top &&
                   textRect.top < viewport.bottom;
          }
          if(!card){
            return JSON.stringify({
              present: false,
              placeholderID: "",
              centerHit: false,
              scrollY: scrollY
            });
          }
          var rect = card.getBoundingClientRect();
          return JSON.stringify({
            present: true,
            placeholderID: card.id || "",
            cssRect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height },
            centerHit: visibleHit(),
            scrollY: scrollY
          });
        })()
        """)
        guard let measurement = RendererAttachmentSpikeDOMMeasurement(body: body) else {
            throw RendererAttachmentSpikeHarnessError.missingDOMMeasurement
        }
        return measurement
    }

    func scrollTo(y: CGFloat) async throws {
        _ = await evaluateJavaScriptWithTimeout(webView, """
        (function(y){ window.scrollTo(0, y); return 'scrolled'; })(\(Self.posix(y)))
        """)
        try await publishGeometry()
    }

    func insertSpacerBeforePlaceholder(height: CGFloat) async throws {
        _ = await evaluateJavaScriptWithTimeout(webView, """
        (function(h){
          var card=document.querySelector('\(Self.cardSelector)');
          if(!card){ return 'missing'; }
          if(document.getElementById('renderer-attachment-spike-spacer')){ return 'exists'; }
          var spacer=document.createElement('div');
          spacer.id='renderer-attachment-spike-spacer';
          spacer.style.height=h+'px';
          spacer.style.display='block';
          spacer.setAttribute('aria-hidden','true');
          card.parentNode.insertBefore(spacer, card);
          return 'inserted';
        })(\(Self.posix(height)))
        """)
        try await publishGeometry()
    }

    func ingest(_ snapshot: RendererAttachmentSpikeSnapshot) {
        guard !isTornDown else { return }
        guard snapshot.generation == generation else { return }
        guard snapshot.revision > currentRevision else { return }
        currentSnapshot = snapshot
        currentRevision = snapshot.revision
        guard snapshot.present else {
            currentGeometry = nil
            overlay.isHidden = true
            overlay.frame = .zero
            overlay.visibleClipRect = .zero
            return
        }
        let geometry = RendererAttachmentSpikeGeometry(
            generation: snapshot.generation,
            revision: snapshot.revision,
            placeholderID: snapshot.placeholderID,
            cssRect: snapshot.cssRect,
            pageZoom: webView.pageZoom,
            domCenterHit: snapshot.centerHit,
            scrollY: snapshot.scrollY,
            backingScaleFactor: window.backingScaleFactor,
            webViewBounds: webView.bounds)
        currentGeometry = geometry
        overlay.isHidden = false
        overlay.frame = geometry.overlayRect
        overlay.visibleClipRect = geometry.localClipRect
    }

    func updateRuntimeState() async throws {
        _ = await evaluateJavaScriptWithTimeout(webView, """
        (function(generation){
          window.__rendererAttachmentSpikeState = window.__rendererAttachmentSpikeState || { generation: 0, revision: 0 };
          window.__rendererAttachmentSpikeState.generation = generation;
          return 'updated';
        })(\(generation))
        """)
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        generation += 1
        currentGeometry = nil
        currentSnapshot = nil
        overlay.visibleClipRect = .zero
        overlay.isHidden = true
        overlay.frame = .zero
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        webView.removeFromSuperview()
        overlay.removeFromSuperview()
        window.contentView = nil
    }

    func requireGeometry() throws -> RendererAttachmentSpikeGeometry {
        guard let geometry = currentGeometry else {
            throw RendererAttachmentSpikeHarnessError.missingGeometry
        }
        return geometry
    }

    private static func html(for markdown: String, documentIdentity: MarkdownDocumentIdentity) -> String {
        let projection = RendererEmbedProjection(
            sourceEmbeds: [:],
            richFenceAliases: [.jsoncanvas])
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: projection,
            documentIdentity: documentIdentity,
            rendererActivationAdmission: nil)
        let body = MarkdownHTMLRenderer.render(markdown, options: options)
        return WikiReaderView.documentHTML(body)
    }

    private static func makeProbeScript() -> String {
        """
        (function(){
          if(window.__rendererAttachmentSpikeProbeInstalled){ return; }
          window.__rendererAttachmentSpikeProbeInstalled = true;
          window.__rendererAttachmentSpikeState = window.__rendererAttachmentSpikeState || { generation: 0, revision: 0 };
          function rectFor(el){
            var r = el.getBoundingClientRect();
            return { x: r.left, y: r.top, width: r.width, height: r.height };
          }
          function viewportBounds(){
            var visual = window.visualViewport;
            var left = visual ? visual.offsetLeft : 0;
            var top = visual ? visual.offsetTop : 0;
            var width = visual ? visual.width : (window.innerWidth || document.documentElement.clientWidth || 0);
            var height = visual ? visual.height : (window.innerHeight || document.documentElement.clientHeight || 0);
            return { left: left, top: top, right: left + width, bottom: top + height };
          }
          function cardHitAt(card, x, y){
            var rect = paintedTextRect(card);
            return !!rect && x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
          }
          function paintedTextRect(card){
            var viewport = viewportBounds();
            var walker = document.createTreeWalker(card, NodeFilter.SHOW_TEXT);
            while(walker.nextNode()){
              var textNode = walker.currentNode;
              if(!textNode || !textNode.textContent || !textNode.textContent.trim()){
                continue;
              }
              var range = document.createRange();
              range.selectNodeContents(textNode);
              var rects = range.getClientRects();
              for(var i = 0; i < rects.length; i++){
                var rect = rects[i];
                var left = Math.max(rect.left, viewport.left);
                var top = Math.max(rect.top, viewport.top);
                var right = Math.min(rect.right, viewport.right);
                var bottom = Math.min(rect.bottom, viewport.bottom);
                if(right > left && bottom > top){
                  return rect;
                }
              }
            }
            return null;
          }
          function visibleCardHit(card){
            var viewport = viewportBounds();
            var textRect = paintedTextRect(card);
            if(!textRect){
              return false;
            }
            return textRect.right > viewport.left &&
                   textRect.left < viewport.right &&
                   textRect.bottom > viewport.top &&
                   textRect.top < viewport.bottom;
          }
          function report(){
            var state = window.__rendererAttachmentSpikeState || { generation: 0, revision: 0 };
            state.revision = Number(state.revision || 0) + 1;
            window.__rendererAttachmentSpikeState = state;
            var card = document.querySelector('\(Self.cardSelector)');
            if(!card){
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                generation: state.generation,
                revision: state.revision,
                placeholderID: "",
                present: false,
                centerHit: false,
                scrollY: window.scrollY || document.documentElement.scrollTop || 0
              });
              return "missing";
            }
            var cardRect = rectFor(card);
            window.webkit.messageHandlers.\(Self.messageName).postMessage({
                generation: state.generation,
                revision: state.revision,
                placeholderID: card.id || "",
                present: true,
                cssRect: cardRect,
                centerHit: visibleCardHit(card),
                scrollY: window.scrollY || document.documentElement.scrollTop || 0
            });
            return "posted";
          }
          window.__rendererAttachmentSpikeReport = report;
          window.addEventListener('scroll', report, { passive: true });
          window.addEventListener('resize', report, { passive: true });
          new MutationObserver(report).observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
        })();
        """
    }

    private static func posix(_ value: CGFloat) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    private static func waitFor(
        description: String,
        timeout: Duration = .seconds(15),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                throw RendererAttachmentSpikeHarnessError.timeout(description: description)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishLoad = true
    }
}

@MainActor
private final class RendererAttachmentSpikeBridge: NSObject, WKScriptMessageHandler {
    weak var host: RendererAttachmentSpikeHarness?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let snapshot = RendererAttachmentSpikeSnapshot(body: message.body) else {
            return
        }
        host?.ingest(snapshot)
    }
}

@MainActor
private final class RendererAttachmentSpikeOverlayView: NSView {
    var visibleClipRect: CGRect = .zero

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        guard visibleClipRect.isEmpty == false, visibleClipRect.contains(localPoint) else {
            return nil
        }
        return super.hitTest(point)
    }
}

private struct RendererAttachmentSpikeSnapshot: Sendable, Equatable {
    let generation: Int
    let revision: Int
    let placeholderID: String
    let present: Bool
    let cssRect: CGRect
    let centerHit: Bool
    let scrollY: CGFloat

    init(
        generation: Int,
        revision: Int,
        placeholderID: String,
        present: Bool,
        cssRect: CGRect,
        centerHit: Bool,
        scrollY: CGFloat
    ) {
        self.generation = generation
        self.revision = revision
        self.placeholderID = placeholderID
        self.present = present
        self.cssRect = cssRect
        self.centerHit = centerHit
        self.scrollY = scrollY
    }

    init?(body: Any?) {
        guard let dict = body as? [String: Any] else { return nil }
        guard let generation = Self.int(dict["generation"]),
              let revision = Self.int(dict["revision"]),
              let present = dict["present"] as? Bool,
              let placeholderID = dict["placeholderID"] as? String else {
            return nil
        }
        let centerHit = dict["centerHit"] as? Bool ?? false
        let scrollY = Self.cgFloat(dict["scrollY"]) ?? 0
        let rect: CGRect
        if present {
            guard let cssRect = Self.rect(dict["cssRect"]) else { return nil }
            rect = cssRect
        } else {
            rect = .zero
        }
        self.generation = generation
        self.revision = revision
        self.placeholderID = placeholderID
        self.present = present
        self.cssRect = rect
        self.centerHit = centerHit
        self.scrollY = scrollY
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any],
              let x = cgFloat(dict["x"]),
              let y = cgFloat(dict["y"]),
              let width = cgFloat(dict["width"]),
              let height = cgFloat(dict["height"]) else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func cgFloat(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            return CGFloat(number.doubleValue)
        case let string as String:
            return CGFloat(Double(string) ?? 0)
        default:
            return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}

private struct RendererAttachmentSpikeDOMMeasurement: Sendable, Equatable {
    let present: Bool
    let placeholderID: String
    let cssRect: CGRect
    let centerHit: Bool
    let scrollY: CGFloat

    init(
        present: Bool,
        placeholderID: String,
        cssRect: CGRect,
        centerHit: Bool,
        scrollY: CGFloat
    ) {
        self.present = present
        self.placeholderID = placeholderID
        self.cssRect = cssRect
        self.centerHit = centerHit
        self.scrollY = scrollY
    }

    init?(body: Any?) {
        guard let dict = Self.dictionary(body),
              let present = dict["present"] as? Bool,
              let placeholderID = dict["placeholderID"] as? String else {
            return nil
        }
        let centerHit = dict["centerHit"] as? Bool ?? false
        let scrollY = Self.cgFloat(dict["scrollY"]) ?? 0
        let rect: CGRect
        if present {
            guard let cssRect = Self.rect(dict["cssRect"]) else { return nil }
            rect = cssRect
        } else {
            rect = .zero
        }
        self.present = present
        self.placeholderID = placeholderID
        self.cssRect = rect
        self.centerHit = centerHit
        self.scrollY = scrollY
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            return dict
        }
        guard let string = value as? String,
              let data = string.data(using: .utf8) else {
            return nil
        }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any],
              let x = cgFloat(dict["x"]),
              let y = cgFloat(dict["y"]),
              let width = cgFloat(dict["width"]),
              let height = cgFloat(dict["height"]) else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func cgFloat(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            return CGFloat(number.doubleValue)
        case let string as String:
            return CGFloat(Double(string) ?? 0)
        default:
            return nil
        }
    }
}

private struct RendererAttachmentSpikeAlignmentEvidence {
    let pointResiduals: [CGFloat]
    let backingResiduals: [CGFloat]

    var maxPointResidual: CGFloat {
        pointResiduals.max() ?? 0
    }

    var maxBackingResidual: CGFloat {
        backingResiduals.max() ?? 0
    }
}

private enum RendererAttachmentSpikeHarnessError: LocalizedError {
    case timeout(description: String)
    case missingGeometry
    case missingDOMMeasurement

    var errorDescription: String? {
        switch self {
        case let .timeout(description):
            return "timed out waiting for \(description)"
        case .missingGeometry:
            return "missing attachment geometry"
        case .missingDOMMeasurement:
            return "missing independent DOM measurement"
        }
    }
}
#endif
