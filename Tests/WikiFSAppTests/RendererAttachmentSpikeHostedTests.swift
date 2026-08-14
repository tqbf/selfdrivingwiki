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
    @Test
    func testScrollZoomResizeAndHeightMutationStayAligned() async throws {
        for _ in 0..<20 {
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
            Self.assertAligned(harness.overlay.frame, expected: initial)
            Self.assertIndependentDOM(harness.currentSnapshot)
            #expect(initial.backingScaleFactor == (window.backingScaleFactor))

            let centeredScroll = max(0, initial.cssRect.minY - (harness.webView.bounds.height * 0.45))
            try await harness.scrollTo(y: centeredScroll)
            try await harness.publishGeometry()
            let centered = try harness.requireGeometry()
            Self.assertAligned(harness.overlay.frame, expected: centered)
            Self.assertIndependentDOM(harness.currentSnapshot)
            #expect(centered.domCenterHit)

            try await harness.scrollTo(y: 220)
            try await harness.publishGeometry()
            let scrolled = try harness.requireGeometry()
            Self.assertAligned(harness.overlay.frame, expected: scrolled)
            Self.assertIndependentDOM(harness.currentSnapshot)

            harness.webView.pageZoom = 1.25
            try await harness.updateRuntimeState()
            try await harness.publishGeometry()
            let zoomed = try harness.requireGeometry()
            Self.assertAligned(harness.overlay.frame, expected: zoomed)
            Self.assertIndependentDOM(harness.currentSnapshot)

            window.setContentSize(NSSize(width: 920, height: 580))
            harness.containerView.layoutSubtreeIfNeeded()
            try await harness.publishGeometry()
            let resized = try harness.requireGeometry()
            Self.assertAligned(harness.overlay.frame, expected: resized)

            try await harness.insertSpacerBeforePlaceholder(height: 96)
            try await harness.publishGeometry()
            let mutated = try harness.requireGeometry()
            Self.assertAligned(harness.overlay.frame, expected: mutated)
            Self.assertIndependentDOM(harness.currentSnapshot)

            let seam = RendererAttachmentSpikeGeometry(
                generation: mutated.generation,
                revision: mutated.revision,
                placeholderID: mutated.placeholderID,
                cssRect: mutated.cssRect,
                pageZoom: mutated.pageZoom,
                domToViewScale: mutated.domToViewScale,
                domCenterHit: mutated.domCenterHit,
                scrollY: mutated.scrollY,
                backingScaleFactor: 2,
                webViewBounds: harness.webView.bounds,
                tolerance: RendererAttachmentSpikeMetrics.measuredAlignmentTolerance)
            #expect(abs(seam.physicalOverlayRect.width - (seam.overlayRect.width * 2)) <= 0.01)
        }
    }

    @Test
    func testClippingAndHitTestingRespectVisiblePlaceholder() async throws {
        for _ in 0..<20 {
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

            #expect(geometry.clipRect.isEmpty == false)
            #expect(geometry.clipRect != geometry.overlayRect)
            #expect(harness.overlay.visibleClipRect == geometry.localClipRect)
            Self.assertIndependentDOM(harness.currentSnapshot)

            let visible = geometry.localClipRect
            let insidePoint = NSPoint(x: visible.midX, y: visible.midY)
            let outsidePoint = RendererAttachmentSpikeHostedTests.outsidePoint(
                overlayBounds: harness.overlay.bounds,
                visibleClip: visible)

            let insideHit = harness.overlay.hitTest(insidePoint)
            #expect(insideHit === harness.overlay)
            #expect(harness.overlay.hitTest(outsidePoint) == nil)

            let outsideWindowPoint = harness.overlay.convert(outsidePoint, to: harness.containerView)
            let routedView = harness.containerView.hitTest(outsideWindowPoint)
            #expect(routedView !== harness.overlay)

            let offscreenScroll = max(0, geometry.scrollY + geometry.cssRect.maxY + 80)
            try await harness.scrollTo(y: offscreenScroll)
            try await harness.publishGeometry()
            let offscreen = try harness.requireGeometry()
            #expect(offscreen.clipRect.isEmpty)
            #expect(offscreen.domCenterHit == false)
            #expect(harness.overlay.visibleClipRect.isEmpty)
            #expect(harness.overlay.hitTest(NSPoint(x: 1, y: 1)) == nil)
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
            ? String(repeating: "Trailing content keeps the placeholder in flow.\n\n", count: 8)
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

    private static func assertAligned(_ actual: CGRect, expected geometry: RendererAttachmentSpikeGeometry) {
        #expect(geometry.isAligned(with: actual))
        #expect(abs(actual.minX - geometry.overlayRect.minX) <= geometry.tolerance)
        #expect(abs(actual.minY - geometry.overlayRect.minY) <= geometry.tolerance)
        #expect(abs(actual.width - geometry.overlayRect.width) <= geometry.tolerance)
        #expect(abs(actual.height - geometry.overlayRect.height) <= geometry.tolerance)
    }

    private static func assertIndependentDOM(_ snapshot: RendererAttachmentSpikeSnapshot?) {
        guard let snapshot else {
            Issue.record("missing independent DOM snapshot")
            return
        }
        let expectedPhysicalWidth = RendererAttachmentSpikeMetrics.referenceCSSWidth * snapshot.pageZoom
        let measuredPhysicalWidth = snapshot.referenceRect.width * snapshot.domToViewScale
        #expect(snapshot.domToViewScale > 0)
        #expect(abs(measuredPhysicalWidth - expectedPhysicalWidth)
            <= RendererAttachmentSpikeMetrics.measuredAlignmentTolerance)
    }

    private static func snapshot(from geometry: RendererAttachmentSpikeGeometry) -> RendererAttachmentSpikeSnapshot {
        RendererAttachmentSpikeSnapshot(
            generation: geometry.generation,
            revision: geometry.revision,
            placeholderID: geometry.placeholderID,
            present: true,
            cssRect: geometry.cssRect,
            pageZoom: geometry.pageZoom,
            domToViewScale: geometry.domToViewScale,
            centerHit: true,
            scrollY: 0,
            referenceRect: CGRect(
                x: -1000,
                y: -1000,
                width: RendererAttachmentSpikeMetrics.referenceCSSWidth / max(geometry.pageZoom, .leastNonzeroMagnitude),
                height: 1))
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
        webView.loadHTMLString(Self.html(for: markdown, documentIdentity: documentIdentity), baseURL: WikiReaderOrigin.url)
        try await Self.waitFor(description: "reader web view reload") { [weak self] in
            self?.didFinishLoad == true
        }
        try await updateRuntimeState()
    }

    func publishGeometry() async throws {
        let minimumRevision = (currentSnapshot?.revision ?? 0) + 1
        _ = await evaluateJavaScriptWithTimeout(webView, "window.__rendererAttachmentSpikeReport ? window.__rendererAttachmentSpikeReport() : 'missing'")
        try await Self.waitFor(description: "renderer attachment geometry") { [weak self] in
            (self?.currentSnapshot?.revision ?? 0) >= minimumRevision
        }
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
        guard snapshot.revision > (currentSnapshot?.revision ?? 0) else { return }
        currentSnapshot = snapshot
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
            pageZoom: snapshot.pageZoom,
            domToViewScale: snapshot.domToViewScale,
            domCenterHit: snapshot.centerHit,
            scrollY: snapshot.scrollY,
            backingScaleFactor: window.backingScaleFactor,
            webViewBounds: webView.bounds,
            tolerance: RendererAttachmentSpikeMetrics.measuredAlignmentTolerance)
        currentGeometry = geometry
        overlay.isHidden = false
        overlay.frame = geometry.overlayRect
        overlay.visibleClipRect = geometry.localClipRect
    }

    func updateRuntimeState() async throws {
        _ = await evaluateJavaScriptWithTimeout(webView, """
        (function(generation, zoom){
          window.__rendererAttachmentSpikeState = window.__rendererAttachmentSpikeState || { generation: 0, pageZoom: 1, revision: 0 };
          window.__rendererAttachmentSpikeState.generation = generation;
          window.__rendererAttachmentSpikeState.pageZoom = zoom;
          window.__rendererAttachmentSpikeState.revision = window.__rendererAttachmentSpikeState.revision || 0;
          return 'updated';
        })(\(generation), \(Self.posix(webView.pageZoom)))
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
          window.__rendererAttachmentSpikeState = window.__rendererAttachmentSpikeState || { generation: 0, pageZoom: 1, revision: 0 };
          function rectFor(el){
            var r = el.getBoundingClientRect();
            return { x: r.left, y: r.top, width: r.width, height: r.height };
          }
          var referenceProbe = document.createElement('div');
          referenceProbe.id = 'renderer-attachment-spike-reference';
          referenceProbe.setAttribute('aria-hidden', 'true');
          referenceProbe.style.cssText = 'position:fixed;left:-10000px;top:-10000px;width:100px;height:1px;visibility:hidden;pointer-events:none;';
          document.documentElement.appendChild(referenceProbe);
          function referenceRect(){
            return rectFor(referenceProbe);
          }
          function report(){
            var state = window.__rendererAttachmentSpikeState || { generation: 0, pageZoom: 1, revision: 0 };
            state.revision = Number(state.revision || 0) + 1;
            var zoom = Number(state.pageZoom || 1);
            var reference = referenceRect();
            var domToViewScale = reference.width > 0 ? (\(Self.posix(RendererAttachmentSpikeMetrics.referenceCSSWidth)) * zoom) / reference.width : 1;
            var card = document.querySelector('\(Self.cardSelector)');
            if(!card){
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                generation: state.generation,
                revision: state.revision,
                placeholderID: "",
                present: false,
                pageZoom: zoom,
                domToViewScale: domToViewScale,
                centerHit: false,
                scrollY: window.scrollY || document.documentElement.scrollTop || 0,
                referenceRect: reference
              });
              return "missing";
            }
            var cardRect = rectFor(card);
            var centerNode = document.elementFromPoint(
              cardRect.x + cardRect.width / 2,
              cardRect.y + cardRect.height / 2);
            var centerHit = centerNode === card || (!!centerNode && card.contains(centerNode));
            window.webkit.messageHandlers.\(Self.messageName).postMessage({
              generation: state.generation,
              revision: state.revision,
              placeholderID: card.id || "",
              present: true,
              cssRect: cardRect,
              pageZoom: zoom,
              domToViewScale: domToViewScale,
              centerHit: centerHit,
              scrollY: window.scrollY || document.documentElement.scrollTop || 0,
              referenceRect: reference
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
        guard visibleClipRect.isEmpty == false, visibleClipRect.contains(point) else {
            return nil
        }
        return super.hitTest(point) ?? self
    }
}

private struct RendererAttachmentSpikeSnapshot: Sendable, Equatable {
    let generation: Int
    let revision: Int
    let placeholderID: String
    let present: Bool
    let cssRect: CGRect
    let pageZoom: CGFloat
    let domToViewScale: CGFloat
    let centerHit: Bool
    let scrollY: CGFloat
    let referenceRect: CGRect

    init(
        generation: Int,
        revision: Int,
        placeholderID: String,
        present: Bool,
        cssRect: CGRect,
        pageZoom: CGFloat,
        domToViewScale: CGFloat,
        centerHit: Bool,
        scrollY: CGFloat,
        referenceRect: CGRect
    ) {
        self.generation = generation
        self.revision = revision
        self.placeholderID = placeholderID
        self.present = present
        self.cssRect = cssRect
        self.pageZoom = pageZoom
        self.domToViewScale = domToViewScale
        self.centerHit = centerHit
        self.scrollY = scrollY
        self.referenceRect = referenceRect
    }

    init?(body: Any) {
        guard let dict = body as? [String: Any] else { return nil }
        guard let generation = Self.int(dict["generation"]),
              let revision = Self.int(dict["revision"]),
              let present = dict["present"] as? Bool,
              let placeholderID = dict["placeholderID"] as? String else {
            return nil
        }
        let pageZoom = Self.cgFloat(dict["pageZoom"]) ?? 1
        let domToViewScale = Self.cgFloat(dict["domToViewScale"]) ?? 1
        let centerHit = dict["centerHit"] as? Bool ?? false
        let scrollY = Self.cgFloat(dict["scrollY"]) ?? 0
        let referenceRect = Self.rect(dict["referenceRect"]) ?? .zero
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
        self.pageZoom = pageZoom
        self.domToViewScale = domToViewScale
        self.centerHit = centerHit
        self.scrollY = scrollY
        self.referenceRect = referenceRect
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

private enum RendererAttachmentSpikeHarnessError: LocalizedError {
    case timeout(description: String)
    case missingGeometry

    var errorDescription: String? {
        switch self {
        case let .timeout(description):
            return "timed out waiting for \(description)"
        case .missingGeometry:
            return "missing attachment geometry"
        }
    }
}
#endif
