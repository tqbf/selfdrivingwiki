#if os(macOS)
import CoreGraphics
import AppKit
import SwiftUI
import WebKit
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

@Suite("Reader renderer attachment coordinator", .serialized, .timeLimit(.minutes(5)))
struct RendererAttachmentCoordinatorTests {
    @Test("provisional navigation resets attachment state for the new DOM")
    @MainActor
    func provisionalNavigationResetsCoordinatorForCurrentGeneration() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        defer { container.teardown() }
        let coordinator = WikiReaderRep.Coordinator()
        coordinator.webView = webView
        coordinator.attachmentContainer = container
        Self.startLifecycleLoad(coordinator, webView: webView)
        let generation = try #require(coordinator.attachmentGeneration)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "navigation-row")

        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        // DOM era: the navigation replaces the whole document. Frame sessions
        // close, and the coordinator recreates for the new generation so
        // stale geometry and activations from the old document fail closed.
        #expect(coordinator.attachmentGeneration == generation)
        #expect(coordinator.attachmentState(for: placeholder) == .unresolved)
    }

    @Test("reserved height follows the syntax-owned embedding role")
    func reservedHeightFollowsEmbeddingRole() throws {
        let descriptor = BuiltInRendererDescriptors.all[0]

        #expect(RendererAttachmentHostPolicy.preferredReservedHeight(
            for: descriptor.reference,
            role: .inlineContent) == RendererAttachmentHostPolicy.dynamicInlineRendererReservedHeight)
        #expect(RendererAttachmentHostPolicy.preferredReservedHeight(
            for: descriptor.reference,
            role: .disclosureRow) == RendererAttachmentHostPolicy.minimumReservedHeight)
        #expect(RendererAttachmentHostPolicy.preferredReservedHeight(
            for: nil,
            role: .inlineContent) == RendererAttachmentHostPolicy.minimumReservedHeight)
    }

    @Test("inline and disclosure budgets are independent")
    @MainActor
    func inlineAndDisclosureBudgetsAreIndependent() throws {
        let coordinator = RendererAttachmentCoordinator(
            generation: 1,
            activeLimit: 1,
            inlineActiveLimit: 1)
        let row = try RendererAttachmentPlaceholderID(validating: "row")
        let firstInline = try RendererAttachmentPlaceholderID(validating: "inline-first")
        let secondInline = try RendererAttachmentPlaceholderID(validating: "inline-second")
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

        #expect(coordinator.ingest(.init(
            generation: 1, placeholderID: row, embeddingRole: .disclosureRow,
            cssRect: rect, visible: true, revision: 1)))
        #expect(coordinator.ingest(.init(
            generation: 1, placeholderID: firstInline, embeddingRole: .inlineContent,
            cssRect: rect, visible: true, revision: 1)))
        #expect(coordinator.ingest(.init(
            generation: 1, placeholderID: secondInline, embeddingRole: .inlineContent,
            cssRect: rect, visible: true, revision: 1)))

        #expect(coordinator.activate(row) == .activate)
        #expect(coordinator.admitInline(firstInline) == .activate)
        #expect(coordinator.admitInline(secondInline) == .refused(.resourcePressure))
        #expect(coordinator.state(for: row) == .active)
        #expect(coordinator.inlineState(for: firstInline) == .mounted)
        #expect(coordinator.inlineState(for: secondInline) == .waitingForResources)
    }

    @Test("inline pressure keeps fallback and becomes retryable after release")
    @MainActor
    func inlinePressurePreservesFallbackAndRetries() throws {
        let coordinator = RendererAttachmentCoordinator(generation: 1, inlineActiveLimit: 1)
        let first = try RendererAttachmentPlaceholderID(validating: "inline-mounted")
        let waiting = try RendererAttachmentPlaceholderID(validating: "inline-waiting")
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        for placeholder in [first, waiting] {
            #expect(coordinator.ingest(.init(
                generation: 1, placeholderID: placeholder, embeddingRole: .inlineContent,
                cssRect: rect, visible: true, revision: 1)))
        }
        #expect(coordinator.admitInline(first) == .activate)
        #expect(coordinator.admitInline(waiting) == .refused(.resourcePressure))
        coordinator.releaseInline(first)
        #expect(coordinator.admitInline(waiting) == .activate)
    }

    @Test("placeholder role cannot change after admission")
    @MainActor
    func placeholderRoleCannotChange() throws {
        let coordinator = RendererAttachmentCoordinator(generation: 1)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "stable-role")
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(coordinator.ingest(.init(
            generation: 1, placeholderID: placeholder, embeddingRole: .inlineContent,
            cssRect: rect, visible: true, revision: 1)))
        #expect(!coordinator.ingest(.init(
            generation: 1, placeholderID: placeholder, embeddingRole: .disclosureRow,
            cssRect: rect, visible: true, revision: 2)))
        #expect(coordinator.role(for: placeholder) == .inlineContent)
    }

    @Test("dynamic inline renderers reserve a full viewer surface")
    func dynamicInlineRenderersReserveViewerSurface() throws {
        #expect(RendererAttachmentHostPolicy.preferredReservedHeight(
            for: BuiltInRendererDescriptors.all[0].reference,
            role: .inlineContent) == 480)
        let installed = RendererReference(
            packageID: try RendererPackageID(validating: "org.example.viewer"),
            version: try RendererPackageVersion(validating: "1.0.1"),
            registrationID: try RendererRegistrationID(validating: "viewer"))
        #expect(RendererAttachmentHostPolicy.preferredReservedHeight(
            for: installed,
            role: .inlineContent) == 480)
    }

    @MainActor private static func runJS(_ source: String, in webView: WKWebView) async throws {
        _ = try await runJavaScript(source, in: webView) { _ in () }
    }

    @MainActor private static func javaScriptBoolean(_ source: String, in webView: WKWebView) async throws -> Bool {
        try await runJavaScript(source, in: webView) { $0 as? Bool ?? false }
    }

    @MainActor private static func javaScriptDouble(_ source: String, in webView: WKWebView) async throws -> Double {
        try await runJavaScript(source, in: webView) { ($0 as? NSNumber)?.doubleValue ?? .nan }
    }

    @MainActor private static func waitUntil(_ description: String, condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimeoutError(description: description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let javaScriptTimeout = Duration.seconds(5)
    @MainActor private static func runJavaScript<T: Sendable>(
        _ source: String,
        in webView: WKWebView,
        transform: @escaping @Sendable (Any?) -> T
    ) async throws -> T {
        let lock = NSLock()
        var completed = false
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            var timeout: Task<Void, Never>?
            func finish(_ result: Result<T, Error>) {
                lock.lock()
                guard completed == false else { lock.unlock(); return }
                completed = true
                lock.unlock()
                timeout?.cancel()
                continuation.resume(with: result)
            }
            timeout = Task { @MainActor in
                do {
                    try await Task.sleep(for: javaScriptTimeout)
                    finish(.failure(TimeoutError(description: "JavaScript evaluation")))
                } catch {
                    // Cancellation is expected when WebKit completes first.
                }
            }
            webView.evaluateJavaScript(source) { result, error in
                if let error { finish(.failure(error)) }
                else { finish(.success(transform(result))) }
            }
        }
    }

    @Test("inert inline renderer output scrolls as a DOM descendant without a native attachment")
    @MainActor
    func inertInlineRendererOutputScrollsWithDocument() async throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 500, height: 320)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let sourceID = SourceID(rawValue: "01JDOMSCROLLSOURCE000000001")
        let bytes = Data(##"{"type":"excalidraw","version":2,"elements":[{"type":"rectangle","x":0,"y":0,"width":100,"height":50,"angle":0,"strokeColor":"#112233","backgroundColor":"#ffffff","strokeWidth":2,"opacity":100,"roundness":null,"isDeleted":false}]}"##.utf8)
        let source = try RendererEmbeddedContent.Source(
            sourceID: sourceID,
            sourceVersionID: SourceVersionID(rawValue: "01JDOMSCROLLVERSION0000001"),
            mimeType: try .init(validating: "application/json"),
            bytes: bytes)
        let fallbackSource = try RendererEmbeddedContent.Source(
            sourceID: SourceID(rawValue: "01JDOMSCROLLSOURCE000000002"),
            sourceVersionID: SourceVersionID(rawValue: "01JDOMSCROLLVERSION0000002"),
            mimeType: try .init(validating: "image/svg+xml"),
            bytes: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><text>Fallback</text></svg>".utf8))
        let markdown = """
        <p style="height:500px">Leading content</p>

        ![Drawing](drawing.excalidraw)

        ![Generic image](generic.svg)

        <p style="height:500px">Trailing content</p>
        """
        let prepared = ReaderMarkdown.preparedDocument(markdown)
        let projection = ResolvedDocumentProjection(markdownImages: [
            "drawing.excalidraw": .renderer(
                rendererReference: .init(
                    packageID: PackageFenceTestSupport.installedPackageID,
                    version: PackageFenceTestSupport.installedPackageVersion,
                    registrationID: PackageFenceTestSupport.installedRegistrationID),
                source: source),
            "generic.svg": .renderer(
                rendererReference: RendererReference(
                    packageID: try RendererPackageID(validating: "org.selfdrivingwiki.json-canvas-readonly"),
                    version: try RendererPackageVersion(validating: "1.0.1"),
                    registrationID: try RendererRegistrationID(validating: "json-canvas")),
                source: fallbackSource),
        ])
        let body = MarkdownHTMLRenderer.render(prepared, projection: projection, options: .disabled)
        #expect(body.contains("class=\"sdw-inline-renderer\""))
        #expect(body.contains("alt=\"Generic image\""))
        #expect(body.components(separatedBy: "class=\"sdw-inline-renderer\"").count - 1 == 2)
        #expect(!body.contains("data-renderer-admitted=\"true\""))
        webView.loadHTMLString(WikiReaderView.documentHTML(body), baseURL: WikiReaderDocumentOrigin.url)
        try await Self.waitUntil("inert renderer document") { webView.isLoading == false }

        let initialY = try await Self.javaScriptDouble(
            "document.querySelector('.sdw-inline-renderer').getBoundingClientRect().y",
            in: webView)
        try await Self.runJS("window.scrollTo(0, 180)", in: webView)
        let scrolledY = try await Self.javaScriptDouble(
            "document.querySelector('.sdw-inline-renderer').getBoundingClientRect().y",
            in: webView)
        let genericImageY = try await Self.javaScriptDouble(
            "document.querySelector('img[alt=\\\"Generic image\\\"]').getBoundingClientRect().y",
            in: webView)

        #expect(scrolledY < initialY - 100)
        #expect(genericImageY.isFinite)
        #expect(try await Self.javaScriptBoolean(
            "document.querySelectorAll('.sdw-inline-renderer').length === 2",
            in: webView))
        #expect(try await Self.javaScriptBoolean(
            "document.querySelector('.sdw-inline-renderer[data-renderer-admitted=\\\"true\\\"]') === null",
            in: webView))
        // DOM era: no native attachment children exist at all.
        #expect(container.subviews.count == 1) // only the webview
    }

    private struct TimeoutError: Error { let description: String }
    @Test("unsupported disclosure stays collapsed without opening a window")
    @MainActor
    func unsupportedDisclosureStaysCollapsed() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let coordinator = WikiReaderRep.Coordinator()
        coordinator.webView = webView
        coordinator.attachmentContainer = container
        Self.startLifecycleLoad(coordinator, webView: webView)
        var presented: [RendererReference] = []
        webView.onRendererActivation = { reference, _ in presented.append(reference) }

        let generation = try #require(coordinator.attachmentGeneration)
        let admission = try #require(webView.rendererActivationAdmission)
        let identity = Self.lifecycleIdentity
        let bytes = Data(#"{"type":"excalidraw","version":2,"elements":[],"appState":{},"files":{}}"#.utf8)
        let block = try MarkdownFencedBlock(
            documentIdentity: identity,
            parserOrdinal: 0,
            rawInfoString: "excalidraw",
            bytes: bytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: identity.pageID,
            pageVersionID: identity.pageVersionID,
            blockID: try #require(block.blockID),
            fenceAlias: RendererFenceAlias(rawValue: "excalidraw")!,
            mimeType: try .init(validating: "application/json"),
            bytes: bytes)
        let reference = RendererReference(
            packageID: PackageFenceTestSupport.installedPackageID,
            version: PackageFenceTestSupport.installedPackageVersion,
            registrationID: PackageFenceTestSupport.installedRegistrationID)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "admitted-excalidraw")
        admission.register(context: .init(
            pageID: identity.pageID,
            pageVersionID: identity.pageVersionID,
            blockID: artifact.blockID,
            rendererReference: reference,
            input: .inlineArtifact(artifact),
            capability: admission.capability,
            generation: generation), attachmentPlaceholderID: placeholder)
        coordinator.handleAttachmentGeometry(.init(
            generation: generation,
            placeholderID: placeholder,
            cssRect: .init(x: 40, y: 80, width: 240, height: 160),
            visible: true,
            revision: 1))

        #expect(coordinator.activateAttachment(placeholder) == .rejected)
        #expect(presented.isEmpty)
        // No native child: a contentless mount would paint an empty bordered
        // rectangle over the row and show the reader nothing.
        #expect(container.subviews.flatMap(\.subviews).contains {
            $0.accessibilityIdentifier() == "renderer-attachment-admitted-excalidraw"
        } == false)
        // Expansion and Open in Window are separate actions. Unsupported inline
        // content stays collapsed and keeps its row-budget slot free.
        #expect(coordinator.attachmentState(for: placeholder) == .card)
        #expect(coordinator.activateAttachment(placeholder) == .rejected)
        #expect(presented.isEmpty)
    }

    @Test("an unadmitted placeholder fails closed instead of mounting an empty attachment")
    @MainActor
    func unadmittedPlaceholderFailsClosed() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let coordinator = WikiReaderRep.Coordinator()
        coordinator.webView = webView
        coordinator.attachmentContainer = container
        Self.startLifecycleLoad(coordinator, webView: webView)
        let generation = try #require(coordinator.attachmentGeneration)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "unadmitted-canvas")
        coordinator.handleAttachmentGeometry(.init(
            generation: generation,
            placeholderID: placeholder,
            cssRect: .init(x: 20, y: 20, width: 160, height: 96),
            visible: true,
            revision: 1))

        #expect(coordinator.activateAttachment(placeholder) == .rejected)
        #expect(coordinator.attachmentState(for: placeholder) == .failed)
        #expect(container.subviews.flatMap(\.subviews).contains {
            $0.accessibilityIdentifier() == "renderer-attachment-unadmitted-canvas"
        } == false)
    }

    @Test("geometry bridge accepts only a complete finite typed payload")
    func geometryBridgeDecodesTrustedShape() throws {
        let message = try #require(RendererAttachmentGeometryMessage(body: [
            "generation": 3, "placeholderID": "canvas-1", "embeddingRole": "disclosureRow",
            "x": 8.0, "y": 12.0, "width": 240.0, "height": 120.0,
            "visible": true, "revision": 4,
        ]))
        #expect(message.generation == 3)
        #expect(message.placeholderID.rawValue == "canvas-1")
        #expect(message.embeddingRole == .disclosureRow)
        #expect(message.cssRect == .init(x: 8, y: 12, width: 240, height: 120))
        #expect(RendererAttachmentGeometryMessage(body: ["generation": 3]) == nil)
        #expect(RendererAttachmentGeometryMessage(body: [
            "generation": 3, "placeholderID": "canvas-1", "embeddingRole": "invalid",
            "x": 0, "y": 0, "width": 1, "height": 1, "visible": true, "revision": 1,
        ]) == nil)
        #expect(RendererAttachmentGeometryMessage(body: [
            "generation": 3, "placeholderID": "canvas-1", "embeddingRole": "disclosureRow",
            "x": Double.nan, "y": 0, "width": 1, "height": 1, "visible": true, "revision": 1,
        ]) == nil)
    }

    @Test("geometry rejects a stale generation and clamps an excessive reserved height")
    @MainActor
    func staleGeometryAndHeightPolicy() throws {
        let coordinator = RendererAttachmentCoordinator(generation: 7)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "canvas-1")

        #expect(coordinator.ingest(.init(
            generation: 6,
            placeholderID: placeholder,
            cssRect: .init(x: 8, y: 16, width: 320, height: 200),
            visible: true,
            revision: 1)) == false)
        #expect(coordinator.state(for: placeholder) == .unresolved)

        #expect(coordinator.ingest(.init(
            generation: 7,
            placeholderID: placeholder,
            cssRect: .init(x: 8, y: 16, width: 320, height: 200),
            visible: true,
            revision: 1)))
        let reserved = coordinator.reserveHeight(
            RendererAttachmentHostPolicy.maximumReservedHeight + 1,
            for: placeholder)
        #expect(reserved <= RendererAttachmentHostPolicy.maximumReservedHeight)
        #expect(reserved >= RendererAttachmentHostPolicy.maximumReservedHeight - 0.001)
    }

    @Test("viewport transform flips DOM geometry and clips it to the reader")
    func viewportTransform() {
        let rect = RendererAttachmentGeometry.overlayRect(
            cssRect: .init(x: 10, y: 20, width: 100, height: 40),
            pageZoom: 1.25,
            readerBounds: .init(x: 0, y: 0, width: 400, height: 300))

        #expect(rect == .init(x: 12.5, y: 225, width: 125, height: 50))
        #expect(RendererAttachmentGeometry.clip(
            rect: rect,
            to: .init(x: 0, y: 240, width: 400, height: 60)) == .init(x: 12.5, y: 240, width: 125, height: 35))
    }

    @Test("fifth row remains a typed collapsed budget refusal")
    @MainActor
    func fifthRowCreatesNoImplicitWindow() throws {
        let coordinator = RendererAttachmentCoordinator(generation: 1)
        let placeholders = try (0...4).map { try RendererAttachmentPlaceholderID(validating: "fifth-contract-\($0)") }
        let geometry = { (id: RendererAttachmentPlaceholderID) in
            RendererAttachmentGeometryMessage(
                generation: 1, placeholderID: id,
                cssRect: .init(x: 0, y: 0, width: 100, height: 100), visible: true, revision: 1)
        }
        for placeholder in placeholders { #expect(coordinator.ingest(geometry(placeholder))) }
        for placeholder in placeholders.prefix(4) { #expect(coordinator.activate(placeholder) == .activate) }
        #expect(coordinator.activate(placeholders[4]) == .refused(.rowBudget))
        #expect(coordinator.state(for: placeholders[4]) == .card)
        #expect(coordinator.activationRefusal(for: placeholders[4]) == .rowBudget)
    }

    @Test("four attachments expand independently and the fifth is refused before work")
    @MainActor
    func fourAttachmentsExpandIndependently() throws {
        let coordinator = RendererAttachmentCoordinator(generation: 1)
        let placeholders = try (0...4).map { try RendererAttachmentPlaceholderID(validating: "budget-\($0)") }
        for placeholder in placeholders {
            #expect(coordinator.ingest(.init(
                generation: 1,
                placeholderID: placeholder,
                cssRect: .init(x: 0, y: 0, width: 100, height: 100),
                visible: true,
                revision: 1)))
        }
        for placeholder in placeholders.prefix(4) {
            #expect(coordinator.activate(placeholder) == .activate)
            #expect(coordinator.state(for: placeholder) == .active)
        }
        #expect(coordinator.activate(placeholders[4]) == .refused(.rowBudget))
        #expect(coordinator.state(for: placeholders[4]) == .card)
        #expect(coordinator.activationRefusal(for: placeholders[4]) == .rowBudget)
    }

    @Test("resource pressure stays retryable after a permit is released")
    @MainActor
    func retrySucceedsAfterPermitRelease() throws {
        let coordinator = RendererAttachmentCoordinator(generation: 1)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "retry-pressure")
        #expect(coordinator.ingest(.init(
            generation: 1,
            placeholderID: placeholder,
            cssRect: .init(x: 0, y: 0, width: 100, height: 100),
            visible: true,
            revision: 1)))
        coordinator.refuse(placeholder, reason: .resourcePressure)
        #expect(coordinator.state(for: placeholder) == .card)
        #expect(coordinator.activationRefusal(for: placeholder) == .resourcePressure)
        #expect(coordinator.activate(placeholder) == .activate)
        #expect(coordinator.activationRefusal(for: placeholder) == nil)
    }

    @Test("terminal failure cannot be resurrected by a refusal")
    @MainActor
    func terminalFailureCannotBeResurrected() throws {
        let coordinator = RendererAttachmentCoordinator(generation: 1)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "terminal-failure")
        #expect(coordinator.ingest(.init(generation: 1, placeholderID: placeholder, cssRect: .init(x: 0, y: 0, width: 10, height: 10), visible: true, revision: 1)))
        coordinator.fail(placeholder)
        coordinator.refuse(placeholder, reason: .resourcePressure)
        #expect(coordinator.state(for: placeholder) == .failed)
        #expect(coordinator.activationRefusal(for: placeholder) == nil)
    }

    @Test("attachment FSM does not expose synchronous transient states")
    func attachmentFSMDropsSynchronousTransientStates() throws {
        let source = try Self.attachmentCoordinatorSource()

        #expect(source.contains("case activating") == false)
        #expect(source.contains("case collapsing") == false)
    }

    @MainActor
    private static func containsHostingView(in view: NSView) -> Bool {
        String(describing: type(of: view)).contains("NSHostingView") ||
            view.subviews.contains(where: containsHostingView)
    }

    @MainActor
    private static func sendPointerClick(to window: NSWindow, view: NSView) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: eventType,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: eventType == .leftMouseDown ? 1 : 0)
            else {
                Issue.record("failed to construct attachment pointer event")
                return
            }
            window.sendEvent(event)
        }
    }

    private static let jsonCanvasBytes = Data("""
    {"nodes":[{"id":"first","type":"text","x":0,"y":0,"width":80,"height":40,"text":"First"}],"edges":[]}
    """.utf8)

    private static let lifecycleIdentity = MarkdownDocumentIdentity(
        pageID: PageID(rawValue: "01JATTACHMENTPAGE000000000001"),
        pageVersionID: PageVersionID(rawValue: "01JATTACHMENTPAGEVERSION00001"))

    /// Prepare a Coordinator whose activations resolve to a real admission.
    /// `startLoad` only mints one when the reader has both a document identity
    /// and a renderer presenter, so a lifecycle test that skips either can
    /// never reach the native attachment path.
    @MainActor
    private static func startLifecycleLoad(
        _ coordinator: WikiReaderRep.Coordinator,
        webView: WikiReaderWebView,
        markdown: String = "# Reader"
    ) {
        webView.onRendererActivation = { _, _ in }
        coordinator.startLoad(
            markdown: markdown,
            documentIdentity: lifecycleIdentity,
            isLoading: .constant(true))
    }

    /// The reviewed JSON Canvas renderer package reference. JSON Canvas is an
    /// installed Web package only; these lifecycle tests exercise the generic
    /// installed attachment path with a real review-scoped reference.
    private static func jsonCanvasPackageReference() throws -> RendererReference {
        RendererReference(
            packageID: try RendererPackageID(validating: "org.selfdrivingwiki.json-canvas-readonly"),
            version: try RendererPackageVersion(validating: "1.0.1"),
            registrationID: try RendererRegistrationID(validating: "json-canvas"))
    }

    @MainActor
    private static func admitInlineJSONCanvasPlaceholder(
        _ placeholderID: RendererAttachmentPlaceholderID,
        coordinator: WikiReaderRep.Coordinator,
        webView: WikiReaderWebView
    ) throws {
        let generation = try #require(coordinator.attachmentGeneration)
        let admission = try #require(webView.rendererActivationAdmission)
        coordinator.inlineAttachmentResolver = { _, _, _ in
            .content(AnyView(Text("installed-inline-renderer")))
        }
        let source = try RendererEmbeddedContent.Source(
            sourceID: SourceID(rawValue: "01JINLINECANVASSOURCE00000001"),
            sourceVersionID: SourceVersionID(rawValue: "01JINLINECANVASVERSION000001"),
            mimeType: try .init(validating: "application/json"),
            bytes: jsonCanvasBytes)
        admission.register(context: .init(
            pageID: lifecycleIdentity.pageID,
            pageVersionID: lifecycleIdentity.pageVersionID,
            identity: .source(source),
            embeddingRole: .inlineContent,
            rendererReference: try Self.jsonCanvasPackageReference(),
            input: .source(versionID: try #require(source.sourceVersionID)),
            capability: admission.capability,
            generation: generation), attachmentPlaceholderID: placeholderID)
    }

    /// Admit `placeholderID` with the reviewed package reference and a generic
    /// inline resolver. These tests exercise coordinator lifecycle behavior.
    /// The installed-renderer hosted suites cover the real Web renderer session.
    /// `parserOrdinal` keeps sibling placeholders on distinct block identities.
    @MainActor
    private static func admitJSONCanvasPlaceholder(
        _ placeholderID: RendererAttachmentPlaceholderID,
        coordinator: WikiReaderRep.Coordinator,
        webView: WikiReaderWebView,
        parserOrdinal: Int = 0
    ) throws {
        let generation = try #require(coordinator.attachmentGeneration)
        let admission = try #require(webView.rendererActivationAdmission)
        coordinator.inlineAttachmentResolver = { _, _, _ in
            .content(AnyView(Text("installed-fence-renderer")))
        }
        let block = try MarkdownFencedBlock(
            documentIdentity: lifecycleIdentity,
            parserOrdinal: parserOrdinal,
            rawInfoString: "jsoncanvas",
            bytes: jsonCanvasBytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: lifecycleIdentity.pageID,
            pageVersionID: lifecycleIdentity.pageVersionID,
            blockID: try #require(block.blockID),
            fenceAlias: RendererFenceAlias(rawValue: "jsoncanvas")!,
            mimeType: try .init(validating: "application/json"),
            bytes: jsonCanvasBytes)
        admission.register(context: .init(
            pageID: lifecycleIdentity.pageID,
            pageVersionID: lifecycleIdentity.pageVersionID,
            blockID: artifact.blockID,
            rendererReference: try Self.jsonCanvasPackageReference(),
            input: .inlineArtifact(artifact),
            capability: admission.capability,
            generation: generation), attachmentPlaceholderID: placeholderID)
    }

    private static func attachmentCoordinatorSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Reader/RendererAttachmentCoordinator.swift"),
            encoding: .utf8)
    }
}
#endif
