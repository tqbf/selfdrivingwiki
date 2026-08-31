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
    private static let positiveLeadingParagraphCount = 3
    private static let defaultLeadingParagraphCount = 28
    private static let positiveScrollY: CGFloat = 220
    private static let bottomSpacerParagraphCount = 24
    /// Fixed from the retained exact-head hosted evidence. This is deliberately
    /// independent of the residuals produced by the run under judgment.
    private static let fixedAlignmentTolerancePoints: CGFloat = 1

    @Test
    func testPhysicalOverlayRectUsesBackingScale() {
        let geometry = RendererAttachmentSpikeGeometry(
            generation: 1,
            revision: 1,
            placeholderID: "placeholder",
            cssRect: CGRect(x: 10, y: 20, width: 30, height: 40),
            pageZoom: 1,
            domCenterHit: true,
            scrollY: 0,
            backingScaleFactor: 2,
            webViewBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(geometry.overlayRect == CGRect(x: 10, y: 40, width: 30, height: 40))
        #expect(geometry.physicalOverlayRect == CGRect(x: 20, y: 80, width: 60, height: 80))
    }

    @Test
    func testScrollZoomResizeAndHeightMutationStayAligned() async throws {
        for iteration in 1...20 {
            var alignmentEvidences: [RendererAttachmentSpikeAlignmentEvidence] = []
            let lease = await HostedAppKitTestGate.shared.acquire()
            defer { lease.release() }
            Self.prepareApplication()

            let harness = RendererAttachmentSpikeHarness(
                windowSize: NSSize(width: 820, height: 520),
                markdown: Self.scenarioMarkdown(
                    includeBottomSpacer: true,
                    leadingParagraphCount: Self.positiveLeadingParagraphCount))
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
            let initialRenderedRect = try await harness.captureSentinelRect()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                renderedRect: try #require(initialRenderedRect),
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                stage: "initial",
                iteration: iteration)
            )
            Self.assertIndependentDOM(
                initialSnapshot,
                measurement: initialMeasurement,
                expectedCenterHit: true,
                expectedFullyInsideLayoutViewport: true,
                stage: "initial iteration \(iteration)")
            #expect(initialMeasurement.centerHit)
            let occluderResult = try await harness.installDOMOccluder()
            #expect(occluderResult == "installed")
            try await harness.publishGeometry()
            let occludedMeasurement = try await harness.measureDOMGeometry()
            #expect(occludedMeasurement.centerHit == false)
            let removalResult = try await harness.removeDOMOccluder()
            #expect(removalResult == "removed")
            try await harness.publishGeometry()
            let restoredMeasurement = try await harness.measureDOMGeometry()
            #expect(restoredMeasurement.centerHit)
            let initialAccessibility = try await harness.measureDOMAccessibility()
            Self.assertAutomatedAccessibilityEvidence(
                overlay: harness.overlay,
                placeholderID: initialSnapshot.placeholderID,
                dom: initialAccessibility)

            try await harness.scrollTo(y: Self.positiveScrollY)
            try await harness.publishGeometry()
            let scrolled = try harness.requireGeometry()
            let scrolledSnapshot = try #require(harness.currentSnapshot)
            let scrolledMeasurement = try await harness.measureDOMGeometry()
            let scrolledRenderedRect = try await harness.captureSentinelRect()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                renderedRect: try #require(scrolledRenderedRect),
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                stage: "scroll",
                iteration: iteration)
            )
            Self.assertIndependentDOM(
                scrolledSnapshot,
                measurement: scrolledMeasurement,
                expectedCenterHit: true,
                expectedFullyInsideLayoutViewport: true,
                stage: "scroll iteration \(iteration)")
            #expect(scrolled.domCenterHit)
            #expect(scrolled.revision > initial.revision)

            harness.webView.pageZoom = 1.25
            try await harness.updateRuntimeState()
            try await harness.scrollTo(y: Self.positiveScrollY)
            try await harness.publishGeometry()
            let zoomed = try harness.requireGeometry()
            let zoomedSnapshot = try #require(harness.currentSnapshot)
            let zoomedMeasurement = try await harness.measureDOMGeometry()
            let zoomedRenderedRect = try await harness.captureSentinelRect()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                renderedRect: try #require(zoomedRenderedRect),
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                stage: "zoomed",
                iteration: iteration)
            )
            Self.assertIndependentDOM(
                zoomedSnapshot,
                measurement: zoomedMeasurement,
                expectedCenterHit: true,
                expectedFullyInsideLayoutViewport: true,
                stage: "zoomed iteration \(iteration)")
            #expect(zoomedMeasurement.cssRect.width < scrolledMeasurement.cssRect.width,
                    "pageZoom observation iteration \(iteration): DOM CSS width shrinks at 1.25x")
            #expect(zoomed.revision > scrolled.revision)

            window.setContentSize(NSSize(width: 920, height: 580))
            harness.containerView.layoutSubtreeIfNeeded()
            try await harness.scrollTo(y: Self.positiveScrollY)
            try await harness.publishGeometry()
            let resized = try harness.requireGeometry()
            let resizedSnapshot = try #require(harness.currentSnapshot)
            let resizedMeasurement = try await harness.measureDOMGeometry()
            let resizedRenderedRect = try await harness.captureSentinelRect()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                renderedRect: try #require(resizedRenderedRect),
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                stage: "resized",
                iteration: iteration)
            )
            Self.assertIndependentDOM(
                resizedSnapshot,
                measurement: resizedMeasurement,
                expectedCenterHit: true,
                expectedFullyInsideLayoutViewport: true,
                stage: "resized iteration \(iteration)")
            #expect(resized.revision > zoomed.revision)

            let spacerInsertion = try await harness.insertSpacerBeforePlaceholder(height: 96)
            #expect(spacerInsertion == "inserted")
            try await harness.scrollTo(y: Self.positiveScrollY)
            try await harness.publishGeometry()
            let spacerMutated = try harness.requireGeometry()
            let spacerSnapshot = try #require(harness.currentSnapshot)
            let spacerMeasurement = try await harness.measureDOMGeometry()
            let spacerRenderedRect = try await harness.captureSentinelRect()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                renderedRect: try #require(spacerRenderedRect),
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                stage: "spacer-mutation",
                iteration: iteration)
            )
            Self.assertIndependentDOM(
                spacerSnapshot,
                measurement: spacerMeasurement,
                expectedCenterHit: true,
                expectedFullyInsideLayoutViewport: true,
                stage: "spacer-mutation iteration \(iteration)")
            #expect(spacerMeasurement.cssRect.minY > resizedMeasurement.cssRect.minY)
            #expect(spacerMutated.revision > resized.revision)

            let reservedHeightMutation = try await harness.increasePlaceholderReservedHeight(by: 96)
            #expect(reservedHeightMutation == "mutated")
            try await harness.publishGeometry()
            let reservedHeightMutated = try harness.requireGeometry()
            let reservedHeightSnapshot = try #require(harness.currentSnapshot)
            let reservedHeightMeasurement = try await harness.measureDOMGeometry()
            let reservedHeightRenderedRect = try await harness.captureSentinelRect()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame,
                renderedRect: try #require(reservedHeightRenderedRect),
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                stage: "reserved-height-mutation",
                iteration: iteration)
            )
            Self.assertIndependentDOM(
                reservedHeightSnapshot,
                measurement: reservedHeightMeasurement,
                expectedCenterHit: true,
                expectedFullyInsideLayoutViewport: true,
                stage: "reserved-height-mutation iteration \(iteration)")
            #expect(reservedHeightMeasurement.cssRect.height > spacerMeasurement.cssRect.height)
            #expect(reservedHeightMutated.revision > spacerMutated.revision)

            Self.assertAlignmentEvidence(
                alignmentEvidences,
                tolerance: Self.fixedAlignmentTolerancePoints,
                backingScaleFactor: window.backingScaleFactor)
        }
    }

    @Test
    func testClippingAndHitTestingRespectVisiblePlaceholder() async throws {
        for iteration in 1...20 {
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
            let geometryRenderedRect = try await harness.captureSentinelRect()
            alignmentEvidences.append(Self.alignmentEvidence(
                harness.overlay.frame.intersection(harness.webView.bounds),
                renderedRect: try #require(geometryRenderedRect),
                containerView: harness.containerView,
                backingScaleFactor: window.backingScaleFactor,
                stage: "visible-clipping",
                iteration: iteration))

            #expect(geometry.clipRect.isEmpty == false)
            #expect(geometry.clipRect != geometry.overlayRect)
            #expect(harness.overlay.visibleClipRect == geometry.localClipRect)
            Self.assertIndependentDOM(
                geometrySnapshot,
                measurement: geometryMeasurement,
                expectedCenterHit: false,
                stage: "geometry-visible iteration \(iteration)")

            let visible = geometry.localClipRect
            let insidePoint = NSPoint(x: visible.midX, y: visible.midY)
            let outsidePoint = try #require(RendererAttachmentSpikeHostedTests.outsidePoint(
                overlayBounds: harness.overlay.bounds,
                visibleClip: visible))
            #expect(harness.overlay.bounds.contains(outsidePoint))
            #expect(visible.contains(outsidePoint) == false)
            let insideWindowPoint = harness.overlay.convert(insidePoint, to: harness.containerView)
            let outsideWindowPoint = harness.overlay.convert(outsidePoint, to: harness.containerView)

            // Phase 3 demonstrates clip-based hit relinquishment. Phase 4 owns
            // the policy that maps DOM occlusion into an overlay clip.
            harness.overlay.visibleClipRect = .zero
            #expect(harness.overlay.hitTest(insideWindowPoint) == nil)
            try await harness.publishGeometry()

            let routedInside = harness.containerView.hitTest(insideWindowPoint)
            #expect(routedInside === harness.overlay)
            let insideHit = harness.overlay.hitTest(insideWindowPoint)
            #expect(insideHit === harness.overlay)
            #expect(harness.overlay.hitTest(outsideWindowPoint) == nil)

            let routedView = harness.containerView.hitTest(outsideWindowPoint)
            #expect(routedView !== harness.overlay)

            let containerOutsidePoint = try #require(Self.outsideContainerPoint(
                webViewBounds: harness.webView.bounds,
                attachmentClip: geometry.clipRect))
            let containerRoutedView = harness.containerView.hitTest(containerOutsidePoint)
            #expect(containerRoutedView !== harness.overlay)
            #expect(harness.isWebViewOrDescendant(containerRoutedView))

            let offscreenScroll = max(0, geometry.scrollY + geometry.cssRect.maxY + 80)
            try await harness.scrollTo(y: offscreenScroll)
            try await harness.publishGeometry()
            let offscreen = try harness.requireGeometry()
            let offscreenSnapshot = try #require(harness.currentSnapshot)
            let offscreenMeasurement = try await harness.measureDOMGeometry()
            let offscreenRenderedRect = try await harness.captureSentinelRect()
            #expect(offscreenRenderedRect == nil)
            #expect(offscreen.clipRect.isEmpty)
            #expect(offscreen.domCenterHit == false)
            #expect(harness.overlay.visibleClipRect.isEmpty)
            #expect(harness.overlay.hitTest(NSPoint(x: 1, y: 1)) == nil)
            #expect(offscreenSnapshot.scrollY > geometry.scrollY)
            Self.assertIndependentDOM(
                offscreenSnapshot,
                measurement: offscreenMeasurement,
                expectedCenterHit: false,
                stage: "geometry-offscreen iteration \(iteration)")

            Self.assertAlignmentEvidence(
                alignmentEvidences,
                tolerance: Self.fixedAlignmentTolerancePoints,
                backingScaleFactor: window.backingScaleFactor)
        }
    }

    @Test
    func testStaleGenerationAndTeardownCannotReviveAttachment() async throws {
        for iteration in 1...20 {
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
            #expect(harness.currentGeometry?.generation == generation2.generation,
                    "stale-generation iteration \(iteration)")

            window.setContentSize(NSSize(width: 860, height: 500))
            harness.containerView.layoutSubtreeIfNeeded()
            try await harness.publishGeometry()
            let generation3 = try harness.requireGeometry()

            let frameBeforeStaleResize = harness.overlay.frame
            let revisionBeforeStaleResize = try #require(harness.currentSnapshot).revision
            #expect(generation2.revision < generation3.revision)
            harness.ingest(Self.snapshot(from: generation2))
            #expect(harness.currentGeometry?.generation == generation3.generation,
                    "stale-resize iteration \(iteration)")
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
        includeBottomSpacer: Bool,
        leadingParagraphCount: Int = defaultLeadingParagraphCount
    ) -> String {
        let top = (0..<leadingParagraphCount).map { index in
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
        expectedPresent: Bool = true,
        expectedFullyInsideLayoutViewport: Bool = false,
        stage: String
    ) {
        guard let snapshot else {
            Issue.record("missing independent DOM snapshot")
            return
        }
        #expect(snapshot.revision > 0)
        #expect(measurement.present == expectedPresent)
        #expect(measurement.matchingCardCount == (expectedPresent ? 1 : 0))
        if measurement.centerHit != expectedCenterHit {
            Issue.record("DOM measurement mismatch [\(stage)]: \(measurement.diagnostics)")
        }
        #expect(measurement.centerHit == expectedCenterHit)
        #expect(measurement.scrollY >= 0)
        if expectedPresent {
            #expect(measurement.placeholderID == snapshot.placeholderID)
            if expectedFullyInsideLayoutViewport {
                #expect(measurement.layoutViewportClientWidth > 0)
                #expect(measurement.layoutViewportClientHeight > 0)
                #expect(measurement.cssRect.minX >= 0)
                #expect(measurement.cssRect.minY >= 0)
                #expect(measurement.cssRect.maxX <= measurement.layoutViewportClientWidth)
                #expect(measurement.cssRect.maxY <= measurement.layoutViewportClientHeight)
            }
        } else {
            #expect(measurement.placeholderID.isEmpty)
        }
    }

    private static func alignmentEvidence(
        _ actual: CGRect,
        renderedRect: CGRect,
        containerView: NSView,
        backingScaleFactor: CGFloat,
        stage: String,
        iteration: Int
    ) -> RendererAttachmentSpikeAlignmentEvidence {
        let expectedBacking = containerView.convertToBacking(renderedRect)
        let actualBacking = containerView.convertToBacking(actual)
        return RendererAttachmentSpikeAlignmentEvidence(
            stage: stage,
            iteration: iteration,
            actualRect: actual,
            renderedRect: renderedRect,
            pointResiduals: [
                abs(actual.minX - renderedRect.minX),
                abs(actual.minY - renderedRect.minY),
                abs(actual.width - renderedRect.width),
                abs(actual.height - renderedRect.height)
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
            if evidence.maxPointResidual > tolerance {
                Issue.record(RendererAttachmentSpikeEvidenceError.diagnostic(evidence.diagnostics))
            }
            #expect(evidence.maxPointResidual <= tolerance)
            if evidence.maxBackingResidual / max(backingScaleFactor, .leastNonzeroMagnitude) > tolerance {
                Issue.record(RendererAttachmentSpikeEvidenceError.diagnostic(evidence.diagnostics))
            }
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

    private static func outsidePoint(overlayBounds: CGRect, visibleClip: CGRect) -> NSPoint? {
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
        return nil
    }

    private static func outsideContainerPoint(webViewBounds: CGRect, attachmentClip: CGRect) -> NSPoint? {
        let inset: CGFloat = 8
        let probes = [
            NSPoint(x: webViewBounds.minX + inset, y: webViewBounds.minY + inset),
            NSPoint(x: webViewBounds.maxX - inset, y: webViewBounds.minY + inset),
            NSPoint(x: webViewBounds.minX + inset, y: webViewBounds.maxY - inset),
            NSPoint(x: webViewBounds.maxX - inset, y: webViewBounds.maxY - inset)
        ]
        return probes.first { webViewBounds.contains($0) && attachmentClip.contains($0) == false }
    }

    /// This checks automated attributes only. It does not certify spoken VoiceOver output.
    private static func assertAutomatedAccessibilityEvidence(
        overlay: RendererAttachmentSpikeOverlayView,
        placeholderID: String,
        dom: RendererAttachmentSpikeDOMAccessibility
    ) {
        let expectedOverlayLabel = "Renderer attachment overlay \(placeholderID)"
        #expect(overlay.isAccessibilityElement())
        #expect(overlay.accessibilityRole() == .group)
        #expect(overlay.accessibilityLabel() == expectedOverlayLabel)
        #expect(overlay.accessibilityIdentifier() == "renderer-attachment-overlay-\(placeholderID)")
        #expect(dom.present)
        #expect(dom.role == "group")
        #expect(dom.label.isEmpty == false)
        #expect(dom.actionRole.isEmpty || dom.actionRole == "link")
        if dom.actionRole == "link" {
            #expect(dom.actionName.isEmpty == false)
        }
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
    private static let sentinelColor = "rgb(1, 2, 3)"
    private static let sentinelColorSpace = NSColorSpace.genericRGB
    private static let snapshotTimeout: Duration = .seconds(15)
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
        overlay.autoresizingMask = []
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
        let body = await evaluateJavaScriptWithTimeout(
            webView,
            "window.__rendererAttachmentSpikeReport ? window.__rendererAttachmentSpikeReport() : 'missing'")
        guard let body, let publishedRevision = Int(body) else {
            throw RendererAttachmentSpikeHarnessError.missingPublishedRevision(body: String(describing: body))
        }
        try await Self.waitFor(description: "renderer attachment geometry") { [weak self] in
            (self?.currentSnapshot?.revision ?? 0) >= publishedRevision
        }
    }

    func measureDOMGeometry() async throws -> RendererAttachmentSpikeDOMMeasurement {
        guard let placeholderID = currentSnapshot?.placeholderID, placeholderID.isEmpty == false else {
            throw RendererAttachmentSpikeHarnessError.missingDOMMeasurement(body: "missing stable placeholder ID")
        }
        let body = await evaluateJavaScriptWithTimeout(webView, """
        (function(){
          var scrollY = window.scrollY || document.documentElement.scrollTop || 0;
          var docEl = document.documentElement;
          var body = document.body;
          var visual = window.visualViewport;
          var card = document.getElementById('\(placeholderID)');
          var cards = document.querySelectorAll('\(Self.cardSelector)');
          function viewportBounds(){
            var width = (docEl && docEl.clientWidth) || window.innerWidth || 0;
            var height = (docEl && docEl.clientHeight) || window.innerHeight || 0;
            return { left: 0, top: 0, right: width, bottom: height, width: width, height: height };
          }
          function rectFor(el){
            var r = el.getBoundingClientRect();
            return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
          }
          function intersectRects(a, b){
            if(!a || !b){ return null; }
            var left = Math.max(a.left, b.left);
            var top = Math.max(a.top, b.top);
            var right = Math.min(a.right, b.right);
            var bottom = Math.min(a.bottom, b.bottom);
            if(right > left && bottom > top){
              return { left: left, top: top, right: right, bottom: bottom, width: right - left, height: bottom - top };
            }
            return null;
          }
          var layoutViewport = viewportBounds();
          var cardRect = card ? rectFor(card) : null;
          var visibleIntersection = cardRect ? intersectRects(cardRect, layoutViewport) : null;
          var centerTarget = cardRect ? document.elementFromPoint(cardRect.left + (cardRect.width / 2), cardRect.top + (cardRect.height / 2)) : null;
          var centerHit = !!(card && centerTarget && (centerTarget === card || card.contains(centerTarget)));
          var selectedCardClass = card ? (typeof card.className === 'string' ? card.className : String(card.className || '')) : "";
          return JSON.stringify({
            present: !!card,
            placeholderID: card ? (card.id || "") : "",
            cssRect: cardRect ? { x: cardRect.left, y: cardRect.top, width: cardRect.width, height: cardRect.height } : { x: 0, y: 0, width: 0, height: 0 },
            centerHit: centerHit,
            scrollY: scrollY,
            matchingCardCount: cards.length,
            selectedCardTag: card ? (card.tagName || "") : "",
            selectedCardClass: selectedCardClass,
            selectedCardID: card ? (card.id || "") : "",
            selectedCardConnected: !!(card && card.isConnected),
            selectedCardRect: cardRect,
            layoutViewportClientWidth: layoutViewport.width,
            layoutViewportClientHeight: layoutViewport.height,
            windowInnerWidth: window.innerWidth || 0,
            windowInnerHeight: window.innerHeight || 0,
            documentElementClientWidth: docEl ? docEl.clientWidth || 0 : 0,
            documentElementClientHeight: docEl ? docEl.clientHeight || 0 : 0,
            documentElementScrollWidth: docEl ? docEl.scrollWidth || 0 : 0,
            documentElementScrollHeight: docEl ? docEl.scrollHeight || 0 : 0,
            documentElementScrollLeft: docEl ? docEl.scrollLeft || 0 : 0,
            documentElementScrollTop: docEl ? docEl.scrollTop || 0 : 0,
            bodyClientWidth: body ? body.clientWidth || 0 : 0,
            bodyClientHeight: body ? body.clientHeight || 0 : 0,
            bodyScrollWidth: body ? body.scrollWidth || 0 : 0,
            bodyScrollHeight: body ? body.scrollHeight || 0 : 0,
            bodyScrollLeft: body ? body.scrollLeft || 0 : 0,
            bodyScrollTop: body ? body.scrollTop || 0 : 0,
            windowScrollX: window.scrollX || window.pageXOffset || 0,
            windowScrollY: window.scrollY || window.pageYOffset || 0,
            readyState: document.readyState || "",
            visualViewportOffsetLeft: visual ? visual.offsetLeft : null,
            visualViewportOffsetTop: visual ? visual.offsetTop : null,
            visualViewportWidth: visual ? visual.width : null,
            visualViewportHeight: visual ? visual.height : null,
            visibleIntersection: visibleIntersection
          });
        })()
        """)
        guard let measurement = RendererAttachmentSpikeDOMMeasurement(body: body) else {
            throw RendererAttachmentSpikeHarnessError.missingDOMMeasurement(body: String(describing: body))
        }
        return measurement
    }

    /// Captures browser pixels after temporarily painting only the selected
    /// placeholder. This must stay separate from all DOM and production geometry.
    func captureSentinelRect() async throws -> CGRect? {
        let placeholderID = try requiredPlaceholderID()
        let selector = "#\(placeholderID)"
        let styleID = "renderer-attachment-spike-sentinel-style"
        let setup = """
        (function(){
          var card = document.querySelector(\(Self.javaScriptString(selector)));
          if (!card) { return 'missing'; }
          var existing = document.getElementById(\(Self.javaScriptString(styleID)));
          if (existing) { existing.remove(); }
          var style = document.createElement('style');
          style.id = \(Self.javaScriptString(styleID));
          // The sentinel measures the painted area against the card's
          // border-box rect, so the card's decoration is flattened without
          // resizing it: a radius would round the painted corners away, and a
          // border would paint its own colour over the sentinel fill and inset
          // the measured area. Recolouring the border keeps the box identical.
          style.textContent = \(Self.javaScriptString("\(selector) { background: \(Self.sentinelColor) !important; border-radius: 0 !important; border-color: \(Self.sentinelColor) !important; } \(selector) * { visibility: hidden !important; }"));
          document.head.appendChild(style);
          return 'styled';
        })()
        """
        guard await evaluateJavaScriptWithTimeout(webView, setup) == "styled" else {
            throw RendererAttachmentSpikeHarnessError.missingSentinelPlaceholder
        }
        let removal = "document.getElementById(\(Self.javaScriptString(styleID)))?.remove(); 'restored'"
        let image: NSImage
        do {
            image = try await Self.takeSnapshot(of: webView, timeout: Self.snapshotTimeout)
        } catch {
            _ = await evaluateJavaScriptWithTimeout(webView, removal)
            throw error
        }
        _ = await evaluateJavaScriptWithTimeout(webView, removal)
        return Self.sentinelRect(in: image, webViewBounds: webView.bounds)
    }

    func measureDOMAccessibility() async throws -> RendererAttachmentSpikeDOMAccessibility {
        let placeholderID = try requiredPlaceholderID()
        let body = await evaluateJavaScriptWithTimeout(webView, """
        (function(){
          var card = document.getElementById(\(Self.javaScriptString(placeholderID)));
          var action = card ? card.querySelector('a.sdw-renderer-card__action') : null;
          return JSON.stringify({
            present: !!card,
            role: card ? (card.getAttribute('role') || '') : '',
            label: card ? (card.getAttribute('aria-label') || '') : '',
            actionRole: action ? (action.getAttribute('role') || 'link') : '',
            actionName: action ? (action.getAttribute('aria-label') || action.textContent || '').trim() : ''
          });
        })()
        """)
        guard let accessibility = RendererAttachmentSpikeDOMAccessibility(body: body) else {
            throw RendererAttachmentSpikeHarnessError.missingDOMAccessibility(body: String(describing: body))
        }
        return accessibility
    }

    func isWebViewOrDescendant(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view === webView || view.isDescendant(of: webView)
    }

    func scrollTo(y: CGFloat) async throws {
        _ = await evaluateJavaScriptWithTimeout(webView, """
        (function(y){ window.scrollTo(0, y); return 'scrolled'; })(\(Self.posix(y)))
        """)
    }

    func insertSpacerBeforePlaceholder(height: CGFloat) async throws -> String {
        guard let result = await evaluateJavaScriptWithTimeout(webView, """
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
        """) else {
            throw RendererAttachmentSpikeHarnessError.missingDOMMeasurement(body: "spacer insertion timed out")
        }
        return result
    }

    func increasePlaceholderReservedHeight(by height: CGFloat) async throws -> String {
        let placeholderID = try requiredPlaceholderID()
        guard let result = await evaluateJavaScriptWithTimeout(webView, """
        (function(delta){
          var card=document.getElementById(\(Self.javaScriptString(placeholderID)));
          if(!card){ return 'missing'; }
          var rect=card.getBoundingClientRect();
          card.style.minHeight=(rect.height + delta)+'px';
          return 'mutated';
        })(\(Self.posix(height)))
        """) else {
            throw RendererAttachmentSpikeHarnessError.missingDOMMeasurement(body: "reserved-height mutation timed out")
        }
        return result
    }

    func installDOMOccluder() async throws -> String {
        let placeholderID = try requiredPlaceholderID()
        guard let result = await evaluateJavaScriptWithTimeout(webView, """
        (function(){
          var card=document.getElementById(\(Self.javaScriptString(placeholderID)));
          if(!card){ return 'missing'; }
          var existing=document.getElementById('renderer-attachment-spike-occluder');
          if(existing){ existing.remove(); }
          var rect=card.getBoundingClientRect();
          var occluder=document.createElement('div');
          occluder.id='renderer-attachment-spike-occluder';
          occluder.style.cssText='position:fixed;left:'+rect.left+'px;top:'+rect.top+'px;width:'+rect.width+'px;height:'+rect.height+'px;z-index:2147483647;background:rgb(9, 9, 9);pointer-events:auto';
          document.body.appendChild(occluder);
          return 'installed';
        })()
        """) else {
            throw RendererAttachmentSpikeHarnessError.missingDOMMeasurement(body: "occluder installation timed out")
        }
        return result
    }

    func removeDOMOccluder() async throws -> String {
        guard let result = await evaluateJavaScriptWithTimeout(webView, """
        (function(){
          var occluder=document.getElementById('renderer-attachment-spike-occluder');
          if(!occluder){ return 'missing'; }
          occluder.remove();
          return 'removed';
        })()
        """) else {
            throw RendererAttachmentSpikeHarnessError.missingDOMMeasurement(body: "occluder removal timed out")
        }
        return result
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
        overlay.configureAccessibility(placeholderID: snapshot.placeholderID)
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

    private func requiredPlaceholderID() throws -> String {
        guard let placeholderID = currentSnapshot?.placeholderID, placeholderID.isEmpty == false else {
            throw RendererAttachmentSpikeHarnessError.missingDOMMeasurement(body: "missing stable placeholder ID")
        }
        return placeholderID
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
                    once.fire {
                        continuation.resume(throwing: RendererAttachmentSpikeHarnessError.snapshotTimeout)
                    }
                } catch {
                    // The WebKit completion cancelled this timer after winning the one-shot race.
                }
            }
            webView.takeSnapshot(with: configuration) { image, error in
                once.fire {
                    timeoutTask.cancel()
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? RendererAttachmentSpikeHarnessError.missingSnapshot)
                    }
                }
            }
        }
    }

    private static func sentinelRect(in image: NSImage, webViewBounds: CGRect) -> CGRect? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              webViewBounds.width > 0, webViewBounds.height > 0 else {
            return nil
        }
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(Self.sentinelColorSpace) else { continue }
                let red = Int((color.redComponent * 255).rounded())
                let green = Int((color.greenComponent * 255).rounded())
                let blue = Int((color.blueComponent * 255).rounded())
                if red == 1, green == 2, blue == 3, color.alphaComponent > 0.99 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pixelsPerPointX = CGFloat(bitmap.pixelsWide) / webViewBounds.width
        let pixelsPerPointY = CGFloat(bitmap.pixelsHigh) / webViewBounds.height
        let width = CGFloat(maxX - minX + 1) / pixelsPerPointX
        let height = CGFloat(maxY - minY + 1) / pixelsPerPointY
        return CGRect(
            x: CGFloat(minX) / pixelsPerPointX,
            y: webViewBounds.height - (CGFloat(maxY + 1) / pixelsPerPointY),
            width: width,
            height: height)
    }

    private static func javaScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"" + escaped + "\""
    }

    private static func html(for markdown: String, documentIdentity: MarkdownDocumentIdentity) -> String {
        let projection = RendererEmbedProjection(
            sourceEmbeds: [:],
            richFenceClaims: RendererFenceClaimResolver.resolve(builtInDescriptors: [BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)]))
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
            return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
          }
          function viewportBounds(){
            var docEl = document.documentElement;
            var width = (docEl && docEl.clientWidth) || window.innerWidth || 0;
            var height = (docEl && docEl.clientHeight) || window.innerHeight || 0;
            return { left: 0, top: 0, right: width, bottom: height, width: width, height: height };
          }
          function intersectRects(a, b){
            if(!a || !b){ return null; }
            var left = Math.max(a.left, b.left);
            var top = Math.max(a.top, b.top);
            var right = Math.min(a.right, b.right);
            var bottom = Math.min(a.bottom, b.bottom);
            if(right > left && bottom > top){
              return { left: left, top: top, right: right, bottom: bottom, width: right - left, height: bottom - top };
            }
            return null;
          }
          function report(){
            var state = window.__rendererAttachmentSpikeState || { generation: 0, revision: 0 };
            state.revision = Number(state.revision || 0) + 1;
            window.__rendererAttachmentSpikeState = state;
            var docEl = document.documentElement;
            var body = document.body;
            var visual = window.visualViewport;
            var cards = document.querySelectorAll('\(Self.cardSelector)');
            var card = cards.length ? cards[0] : null;
            var viewport = viewportBounds();
            var cardRect = card ? rectFor(card) : null;
            var visibleIntersection = cardRect ? intersectRects(cardRect, viewport) : null;
            var centerTarget = cardRect ? document.elementFromPoint(cardRect.left + (cardRect.width / 2), cardRect.top + (cardRect.height / 2)) : null;
            var centerHit = !!(card && centerTarget && (centerTarget === card || card.contains(centerTarget)));
            var selectedCardClass = card ? (typeof card.className === 'string' ? card.className : String(card.className || '')) : "";
            if(!card){
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                generation: state.generation,
                revision: state.revision,
                placeholderID: "",
                present: false,
                centerHit: false,
                scrollY: window.scrollY || document.documentElement.scrollTop || 0,
                matchingCardCount: cards.length,
                selectedCardTag: "",
                selectedCardClass: "",
                selectedCardID: "",
                selectedCardConnected: false,
                selectedCardRect: null,
                layoutViewportClientWidth: viewport.width,
                layoutViewportClientHeight: viewport.height,
                windowInnerWidth: window.innerWidth || 0,
                windowInnerHeight: window.innerHeight || 0,
                documentElementClientWidth: docEl ? docEl.clientWidth || 0 : 0,
                documentElementClientHeight: docEl ? docEl.clientHeight || 0 : 0,
                documentElementScrollWidth: docEl ? docEl.scrollWidth || 0 : 0,
                documentElementScrollHeight: docEl ? docEl.scrollHeight || 0 : 0,
                documentElementScrollLeft: docEl ? docEl.scrollLeft || 0 : 0,
                documentElementScrollTop: docEl ? docEl.scrollTop || 0 : 0,
                bodyClientWidth: body ? body.clientWidth || 0 : 0,
                bodyClientHeight: body ? body.clientHeight || 0 : 0,
                bodyScrollWidth: body ? body.scrollWidth || 0 : 0,
                bodyScrollHeight: body ? body.scrollHeight || 0 : 0,
                bodyScrollLeft: body ? body.scrollLeft || 0 : 0,
                bodyScrollTop: body ? body.scrollTop || 0 : 0,
                windowScrollX: window.scrollX || window.pageXOffset || 0,
                windowScrollY: window.scrollY || window.pageYOffset || 0,
                readyState: document.readyState || "",
                visualViewportOffsetLeft: visual ? visual.offsetLeft : null,
                visualViewportOffsetTop: visual ? visual.offsetTop : null,
                visualViewportWidth: visual ? visual.width : null,
                visualViewportHeight: visual ? visual.height : null,
                visibleIntersection: null
              });
              return String(state.revision);
            }
            window.webkit.messageHandlers.\(Self.messageName).postMessage({
                generation: state.generation,
                revision: state.revision,
                placeholderID: card.id || "",
                present: true,
                cssRect: cardRect ? { x: cardRect.left, y: cardRect.top, width: cardRect.width, height: cardRect.height } : { x: 0, y: 0, width: 0, height: 0 },
                centerHit: centerHit,
                scrollY: window.scrollY || document.documentElement.scrollTop || 0,
                matchingCardCount: cards.length,
                selectedCardTag: card.tagName || "",
                selectedCardClass: selectedCardClass,
                selectedCardID: card.id || "",
                selectedCardConnected: !!card.isConnected,
                selectedCardRect: cardRect,
                layoutViewportClientWidth: viewport.width,
                layoutViewportClientHeight: viewport.height,
                windowInnerWidth: window.innerWidth || 0,
                windowInnerHeight: window.innerHeight || 0,
                documentElementClientWidth: docEl ? docEl.clientWidth || 0 : 0,
                documentElementClientHeight: docEl ? docEl.clientHeight || 0 : 0,
                documentElementScrollWidth: docEl ? docEl.scrollWidth || 0 : 0,
                documentElementScrollHeight: docEl ? docEl.scrollHeight || 0 : 0,
                documentElementScrollLeft: docEl ? docEl.scrollLeft || 0 : 0,
                documentElementScrollTop: docEl ? docEl.scrollTop || 0 : 0,
                bodyClientWidth: body ? body.clientWidth || 0 : 0,
                bodyClientHeight: body ? body.clientHeight || 0 : 0,
                bodyScrollWidth: body ? body.scrollWidth || 0 : 0,
                bodyScrollHeight: body ? body.scrollHeight || 0 : 0,
                bodyScrollLeft: body ? body.scrollLeft || 0 : 0,
                bodyScrollTop: body ? body.scrollTop || 0 : 0,
                windowScrollX: window.scrollX || window.pageXOffset || 0,
                windowScrollY: window.scrollY || window.pageYOffset || 0,
                readyState: document.readyState || "",
                visualViewportOffsetLeft: visual ? visual.offsetLeft : null,
                visualViewportOffsetTop: visual ? visual.offsetTop : null,
                visualViewportWidth: visual ? visual.width : null,
                visualViewportHeight: visual ? visual.height : null,
                visibleIntersection: visibleIntersection
            });
            return String(state.revision);
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

    static func accessibilityLabel(for placeholderID: String) -> String {
        "Renderer attachment overlay \(placeholderID)"
    }

    static func accessibilityIdentifier(for placeholderID: String) -> String {
        "renderer-attachment-overlay-\(placeholderID)"
    }

    func configureAccessibility(placeholderID: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.accessibilityLabel(for: placeholderID))
        setAccessibilityIdentifier(Self.accessibilityIdentifier(for: placeholderID))
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
    let matchingCardCount: Int

    init(
        generation: Int,
        revision: Int,
        placeholderID: String,
        present: Bool,
        cssRect: CGRect,
        centerHit: Bool,
        scrollY: CGFloat,
        matchingCardCount: Int = 1
    ) {
        self.generation = generation
        self.revision = revision
        self.placeholderID = placeholderID
        self.present = present
        self.cssRect = cssRect
        self.centerHit = centerHit
        self.scrollY = scrollY
        self.matchingCardCount = matchingCardCount
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
        let matchingCardCount = Self.int(dict["matchingCardCount"]) ?? 0
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
        self.matchingCardCount = matchingCardCount
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
    let matchingCardCount: Int
    let diagnostics: String
    let layoutViewportClientWidth: CGFloat
    let layoutViewportClientHeight: CGFloat

    init(
        present: Bool,
        placeholderID: String,
        cssRect: CGRect,
        centerHit: Bool,
        scrollY: CGFloat,
        matchingCardCount: Int = 0,
        diagnostics: String = "",
        layoutViewportClientWidth: CGFloat = 0,
        layoutViewportClientHeight: CGFloat = 0
    ) {
        self.present = present
        self.placeholderID = placeholderID
        self.cssRect = cssRect
        self.centerHit = centerHit
        self.scrollY = scrollY
        self.matchingCardCount = matchingCardCount
        self.diagnostics = diagnostics
        self.layoutViewportClientWidth = layoutViewportClientWidth
        self.layoutViewportClientHeight = layoutViewportClientHeight
    }

    init?(body: Any?) {
        guard let dict = Self.dictionary(body),
              let present = dict["present"] as? Bool,
              let placeholderID = dict["placeholderID"] as? String else {
            return nil
        }
        let centerHit = dict["centerHit"] as? Bool ?? false
        let scrollY = Self.cgFloat(dict["scrollY"]) ?? 0
        let matchingCardCount = Self.int(dict["matchingCardCount"]) ?? 0
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
        self.matchingCardCount = matchingCardCount
        self.layoutViewportClientWidth = Self.cgFloat(dict["layoutViewportClientWidth"]) ?? 0
        self.layoutViewportClientHeight = Self.cgFloat(dict["layoutViewportClientHeight"]) ?? 0
        self.diagnostics = Self.debugSummary(
            dict: dict,
            present: present,
            placeholderID: placeholderID,
            rect: rect,
            centerHit: centerHit,
            scrollY: scrollY)
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

    private static func cgFloatOptional(_ value: Any?) -> CGFloat? {
        guard let value, !(value is NSNull) else { return nil }
        return cgFloat(value)
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

    private static func bool(_ value: Any?) -> Bool {
        value as? Bool ?? false
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func rectOptional(_ value: Any?) -> CGRect? {
        guard let value, !(value is NSNull) else { return nil }
        return rect(value)
    }

    private static func debugSummary(
        dict: [String: Any],
        present: Bool,
        placeholderID: String,
        rect: CGRect,
        centerHit: Bool,
        scrollY: CGFloat
    ) -> String {
        let matchingCardCount = int(dict["matchingCardCount"]) ?? 0
        let selectedCardTag = string(dict["selectedCardTag"])
        let selectedCardClass = string(dict["selectedCardClass"])
        let selectedCardID = string(dict["selectedCardID"])
        let selectedCardConnected = bool(dict["selectedCardConnected"])
        let selectedCardRect = rectOptional(dict["selectedCardRect"])
        let layoutViewportClientWidth = cgFloat(dict["layoutViewportClientWidth"]) ?? 0
        let layoutViewportClientHeight = cgFloat(dict["layoutViewportClientHeight"]) ?? 0
        let windowInnerWidth = cgFloat(dict["windowInnerWidth"]) ?? 0
        let windowInnerHeight = cgFloat(dict["windowInnerHeight"]) ?? 0
        let documentElementClientWidth = cgFloat(dict["documentElementClientWidth"]) ?? 0
        let documentElementClientHeight = cgFloat(dict["documentElementClientHeight"]) ?? 0
        let documentElementScrollWidth = cgFloat(dict["documentElementScrollWidth"]) ?? 0
        let documentElementScrollHeight = cgFloat(dict["documentElementScrollHeight"]) ?? 0
        let documentElementScrollLeft = cgFloat(dict["documentElementScrollLeft"]) ?? 0
        let documentElementScrollTop = cgFloat(dict["documentElementScrollTop"]) ?? 0
        let bodyClientWidth = cgFloat(dict["bodyClientWidth"]) ?? 0
        let bodyClientHeight = cgFloat(dict["bodyClientHeight"]) ?? 0
        let bodyScrollWidth = cgFloat(dict["bodyScrollWidth"]) ?? 0
        let bodyScrollHeight = cgFloat(dict["bodyScrollHeight"]) ?? 0
        let bodyScrollLeft = cgFloat(dict["bodyScrollLeft"]) ?? 0
        let bodyScrollTop = cgFloat(dict["bodyScrollTop"]) ?? 0
        let windowScrollX = cgFloat(dict["windowScrollX"]) ?? 0
        let windowScrollY = cgFloat(dict["windowScrollY"]) ?? 0
        let readyState = string(dict["readyState"])
        let visualViewportOffsetLeft = cgFloatOptional(dict["visualViewportOffsetLeft"])
        let visualViewportOffsetTop = cgFloatOptional(dict["visualViewportOffsetTop"])
        let visualViewportWidth = cgFloatOptional(dict["visualViewportWidth"])
        let visualViewportHeight = cgFloatOptional(dict["visualViewportHeight"])
        let visibleIntersection = rectOptional(dict["visibleIntersection"])
        return [
            "present=\(present)",
            "placeholderID=\(placeholderID)",
            "centerHit=\(centerHit)",
            "scrollY=\(scrollY)",
            "matchingCardCount=\(matchingCardCount)",
            "selectedCardTag=\(selectedCardTag)",
            "selectedCardClass=\(selectedCardClass)",
            "selectedCardID=\(selectedCardID)",
            "selectedCardConnected=\(selectedCardConnected)",
            "cardRect=\(describe(rect))",
            "selectedCardRect=\(describe(selectedCardRect))",
            "visibleIntersection=\(describe(visibleIntersection))",
            "layoutViewport=(\(layoutViewportClientWidth),\(layoutViewportClientHeight))",
            "windowInner=(\(windowInnerWidth),\(windowInnerHeight))",
            "documentElementClient=(\(documentElementClientWidth),\(documentElementClientHeight))",
            "documentElementScroll=(\(documentElementScrollLeft),\(documentElementScrollTop),\(documentElementScrollWidth),\(documentElementScrollHeight))",
            "bodyClient=(\(bodyClientWidth),\(bodyClientHeight))",
            "bodyScroll=(\(bodyScrollLeft),\(bodyScrollTop),\(bodyScrollWidth),\(bodyScrollHeight))",
            "windowScroll=(\(windowScrollX),\(windowScrollY))",
            "readyState=\(readyState)",
            "visualViewport=(\(describe(value: visualViewportOffsetLeft)),\(describe(value: visualViewportOffsetTop)),\(describe(value: visualViewportWidth)),\(describe(value: visualViewportHeight)))"
        ].joined(separator: " ")
    }

    private static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return "(\(rect.minX),\(rect.minY),\(rect.width),\(rect.height))"
    }

    private static func describe(value: CGFloat?) -> String {
        guard let value else { return "nil" }
        return "\(value)"
    }
}

private struct RendererAttachmentSpikeAlignmentEvidence {
    let stage: String
    let iteration: Int
    let actualRect: CGRect
    let renderedRect: CGRect
    let pointResiduals: [CGFloat]
    let backingResiduals: [CGFloat]

    var maxPointResidual: CGFloat {
        pointResiduals.max() ?? 0
    }

    var maxBackingResidual: CGFloat {
        backingResiduals.max() ?? 0
    }

    var diagnostics: String {
        "alignment stage=\(stage) iteration=\(iteration) actual=\(actualRect) rendered=\(renderedRect) pointResiduals=\(pointResiduals) backingResiduals=\(backingResiduals)"
    }
}

private enum RendererAttachmentSpikeEvidenceError: LocalizedError {
    case diagnostic(String)

    var errorDescription: String? {
        switch self {
        case let .diagnostic(message): message
        }
    }
}

private struct RendererAttachmentSpikeDOMAccessibility: Sendable, Equatable {
    let present: Bool
    let role: String
    let label: String
    let actionRole: String
    let actionName: String

    init?(body: String?) {
        guard let body, let data = body.data(using: .utf8) else {
            return nil
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
        guard let dictionary = object as? [String: Any],
              let present = dictionary["present"] as? Bool,
              let role = dictionary["role"] as? String,
              let label = dictionary["label"] as? String,
              let actionRole = dictionary["actionRole"] as? String,
              let actionName = dictionary["actionName"] as? String else {
            return nil
        }
        self.present = present
        self.role = role
        self.label = label
        self.actionRole = actionRole
        self.actionName = actionName
    }
}

private enum RendererAttachmentSpikeHarnessError: LocalizedError {
    case timeout(description: String)
    case missingGeometry
    case missingDOMMeasurement(body: String)
    case missingDOMAccessibility(body: String)
    case missingPublishedRevision(body: String)
    case missingSentinelPlaceholder
    case missingSnapshot
    case snapshotTimeout

    var errorDescription: String? {
        switch self {
        case let .timeout(description):
            return "timed out waiting for \(description)"
        case .missingGeometry:
            return "missing attachment geometry"
        case let .missingDOMMeasurement(body):
            return "missing independent DOM measurement: \(body)"
        case let .missingDOMAccessibility(body):
            return "missing independent DOM accessibility evidence: \(body)"
        case let .missingPublishedRevision(body):
            return "missing published renderer attachment revision: \(body)"
        case .missingSentinelPlaceholder:
            return "missing sentinel placeholder"
        case .missingSnapshot:
            return "missing web view snapshot"
        case .snapshotTimeout:
            return "timed out waiting for web view snapshot"
        }
    }
}
#endif
