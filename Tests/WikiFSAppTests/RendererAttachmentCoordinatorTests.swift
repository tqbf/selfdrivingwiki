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
    @Test("Escape exits the hosted native attachment and restores reader focus")
    @MainActor
    func escapeExitsNativeAttachment() throws {
        let webView = WikiReaderWebView(); let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }
        let placeholder = try RendererAttachmentPlaceholderID(validating: "escape-canvas")
        container.updateAttachmentViewport(.init(x: 40, y: 80, width: 160, height: 96))
        container.activateAttachment(named: placeholder)
        let child = try #require(container.subviews.flatMap(\.subviews).first { $0.accessibilityIdentifier() == "renderer-attachment-escape-canvas" })
        #expect(window.firstResponder === child)
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        #expect(container.subviews.flatMap(\.subviews).contains { $0 === child } == false)
        #expect(window.firstResponder === webView)
    }
    private static let javaScriptTimeout = Duration.seconds(5)
    @Test("DOM placeholder removal closes its admitted native attachment")
    @MainActor
    func domRemovalClosesAttachment() async throws {
        let webView = WikiReaderWebView(); let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }
        let coordinator = WikiReaderRep.Coordinator(); coordinator.webView = webView; coordinator.attachmentContainer = container; webView.coordinator = coordinator; webView.navigationDelegate = coordinator
        coordinator.startLoad(markdown: "# Reader", documentIdentity: nil, isLoading: .constant(true))
        try await Self.waitUntil("reader document") { webView.isLoading == false }
        try await Self.waitForReporter(in: webView)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "dom-removal-canvas")
        let generation = try #require(coordinator.attachmentGeneration)
        try await Self.runJS("var e=document.createElement('section');e.id='dom-removal-canvas';e.className='sdw-renderer-card';e.style.cssText='width:160px;height:96px';document.body.appendChild(e);window.__sdwRendererAttachmentReport(\(generation));", in: webView)
        try await Self.waitUntil("placeholder admission") { coordinator.attachmentState(for: placeholder) == .card }
        #expect(coordinator.activateAttachment(placeholder) == .activate)
        #expect(coordinator.attachmentState(for: placeholder) == .active)
        #expect(container.subviews.flatMap(\.subviews).contains { $0.accessibilityIdentifier() == "renderer-attachment-dom-removal-canvas" })
        try await Self.runJS("document.getElementById('dom-removal-canvas').remove();", in: webView)
        try await Self.waitUntil("placeholder removal") { coordinator.attachmentState(for: placeholder) == .closed }
        #expect(container.subviews.flatMap(\.subviews).contains { $0.accessibilityIdentifier() == "renderer-attachment-dom-removal-canvas" } == false)
        #expect(window.firstResponder === webView)
    }

    @MainActor private static func runJS(_ source: String, in webView: WKWebView) async throws {
        _ = try await runJavaScript(source, in: webView) { _ in () }
    }

    @MainActor private static func javaScriptBoolean(_ source: String, in webView: WKWebView) async throws -> Bool {
        try await runJavaScript(source, in: webView) { $0 as? Bool ?? false }
    }

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

    @MainActor private static func waitForReporter(in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await javaScriptBoolean("typeof window.__sdwRendererAttachmentReport === 'function'", in: webView) == false {
            guard ContinuousClock.now < deadline else { throw TimeoutError(description: "attachment reporter") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @Test("new document generation closes its old attachment and rejects stale geometry")
    @MainActor
    func generationChangeRejectsOldGeometry() async throws {
        let webView = WikiReaderWebView(); let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }
        let coordinator = WikiReaderRep.Coordinator(); coordinator.webView = webView; coordinator.attachmentContainer = container; webView.navigationDelegate = coordinator
        coordinator.startLoad(markdown: "# First", documentIdentity: nil, isLoading: .constant(true))
        try await Self.waitUntil("first document") { webView.isLoading == false }
        let placeholder = try RendererAttachmentPlaceholderID(validating: "generation-canvas")
        let firstGeneration = try #require(coordinator.attachmentGeneration)
        coordinator.handleAttachmentGeometry(.init(generation: firstGeneration, placeholderID: placeholder, cssRect: .init(x: 20, y: 20, width: 160, height: 96), visible: true, revision: 1))
        #expect(coordinator.activateAttachment(placeholder) == .activate)
        #expect(coordinator.attachmentState(for: placeholder) == .active)
        #expect(container.subviews.flatMap(\.subviews).contains {
            $0.accessibilityIdentifier() == "renderer-attachment-generation-canvas"
        })
        coordinator.startLoad(markdown: "# Second", documentIdentity: nil, isLoading: .constant(true))
        try await Self.waitUntil("second document") { webView.isLoading == false }
        #expect(container.subviews.flatMap(\.subviews).contains { $0.accessibilityIdentifier() == "renderer-attachment-generation-canvas" } == false)
        #expect(window.firstResponder === webView)
        coordinator.handleAttachmentGeometry(.init(generation: firstGeneration, placeholderID: placeholder, cssRect: .init(x: 20, y: 20, width: 160, height: 96), visible: true, revision: 2))
        #expect(coordinator.attachmentState(for: placeholder) == .unresolved)
    }
    @Test("real WebKit reload removes an admitted native child")
    @MainActor
    func reloadClosesAttachmentAndRestoresReaderFocus() async throws {
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
        webView.navigationDelegate = coordinator
        coordinator.startLoad(markdown: "# Reader", documentIdentity: nil, isLoading: .constant(true))
        try await Self.waitUntil("initial reader navigation") { webView.isLoading == false }
        let placeholder = try RendererAttachmentPlaceholderID(validating: "reload-canvas")
        coordinator.handleAttachmentGeometry(.init(generation: 1, placeholderID: placeholder, cssRect: .init(x: 20, y: 20, width: 160, height: 96), visible: true, revision: 1))
        #expect(coordinator.activateAttachment(placeholder) == .activate)
        #expect(coordinator.attachmentState(for: placeholder) == .active)
        #expect(container.subviews.flatMap(\.subviews).contains { $0.accessibilityIdentifier() == "renderer-attachment-reload-canvas" })
        webView.reload()
        try await Self.waitUntil("reload removed native child") {
            container.subviews.flatMap(\.subviews).contains {
                $0.accessibilityIdentifier() == "renderer-attachment-reload-canvas"
            } == false
        }
        #expect(coordinator.attachmentState(for: placeholder) == .closed)
        #expect(window.firstResponder === webView)
    }

    @MainActor private static func waitUntil(_ description: String, condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimeoutError(description: description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct TimeoutError: Error { let description: String }
    @Test("hosted native child clips, routes focus, and tears down")
    @MainActor
    func hostedNativeChildLifecycle() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let placeholder = try RendererAttachmentPlaceholderID(validating: "hosted-canvas")
        let expectedVisibleRect = CGRect(x: 40, y: 80, width: 160, height: 96)
        container.updateAttachmentViewport(expectedVisibleRect)
        container.activateAttachment(named: placeholder)

        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-hosted-canvas"
        })
        #expect(child.frame == expectedVisibleRect)
        #expect(child.accessibilityRole() == .group)
        #expect(child.accessibilityLabel() == "Interactive renderer attachment")
        #expect(container.hitTest(.init(x: 80, y: 100)) === child)
        #expect(container.hitTest(.init(x: 300, y: 260)) === webView)

        container.collapseAttachment()
        #expect(container.subviews.flatMap(\.subviews).contains { $0 === child } == false)
        #expect(window.firstResponder === webView)

        container.activateAttachment(named: placeholder)
        #expect(container.subviews.flatMap(\.subviews).contains { $0.accessibilityIdentifier() == "renderer-attachment-hosted-canvas" })
        container.teardown()
        #expect(container.subviews.isEmpty)
    }

    @Test("hosted JSON Canvas attachment mounts the factory's native SwiftUI view")
    @MainActor
    func hostedJSONCanvasAttachmentMountsNativeView() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let source = try RendererEmbeddedContent.Source(
            sourceID: .init(rawValue: "01JATTACHMENTSOURCE0000000001"),
            sourceVersionID: .init(rawValue: "01JATTACHMENTVERSION000000001"),
            mimeType: try .init(validating: "application/json"),
            bytes: Self.jsonCanvasBytes)
        let input = NativeJSONCanvasAttachmentInput.source(try .init(validating: source))
        let factory = NativeJSONCanvasAttachmentFactory { _ in Self.jsonCanvasBytes }
        let placeholder = try RendererAttachmentPlaceholderID(validating: "mounted-json-canvas")
        container.updateAttachmentViewport(.init(x: 40, y: 80, width: 160, height: 96))

        container.activateAttachment(named: placeholder, content: try factory.makeView(for: input))

        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-mounted-json-canvas"
        })
        #expect(Self.containsHostingView(in: child))
        #expect(window.firstResponder === child)
    }

    @Test("admitted JSON Canvas fence mounts the native factory view through the reader lifecycle")
    @MainActor
    func admittedJSONCanvasFenceMountsThroughReaderLifecycle() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let pageID = PageID(rawValue: "01JATTACHMENTPAGE000000000001")
        let pageVersionID = PageVersionID(rawValue: "01JATTACHMENTPAGEVERSION00001")
        let identity = MarkdownDocumentIdentity(pageID: pageID, pageVersionID: pageVersionID)
        let coordinator = WikiReaderRep.Coordinator()
        coordinator.webView = webView
        coordinator.attachmentContainer = container
        webView.coordinator = coordinator
        webView.onRendererActivation = { _, _ in }
        coordinator.startLoad(markdown: "# Reader", documentIdentity: identity, isLoading: .constant(true))

        let generation = try #require(coordinator.attachmentGeneration)
        let admission = try #require(webView.rendererActivationAdmission)
        let block = try MarkdownFencedBlock(
            documentIdentity: identity,
            parserOrdinal: 0,
            rawInfoString: "jsoncanvas",
            bytes: Self.jsonCanvasBytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: try #require(block.blockID),
            fenceKind: .jsoncanvas,
            mimeType: try .init(validating: "application/json"),
            bytes: Self.jsonCanvasBytes)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "admitted-json-canvas")
        admission.register(context: .init(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: artifact.blockID,
            rendererReference: BuiltInRendererReference.reference(for: .jsonCanvas),
            input: .inlineArtifact(artifact),
            capability: admission.capability,
            generation: generation), attachmentPlaceholderID: placeholder)
        coordinator.handleAttachmentGeometry(.init(
            generation: generation,
            placeholderID: placeholder,
            cssRect: .init(x: 40, y: 80, width: 240, height: 160),
            visible: true,
            revision: 1))

        #expect(coordinator.activateAttachment(placeholder) == .activate)
        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-admitted-json-canvas"
        })
        #expect(Self.containsHostingView(in: child))
        #expect(window.firstResponder === child)
    }
    @Test("geometry bridge accepts only a complete finite typed payload")
    func geometryBridgeDecodesTrustedShape() throws {
        let message = try #require(RendererAttachmentGeometryMessage(body: [
            "generation": 3, "placeholderID": "canvas-1", "x": 8.0, "y": 12.0,
            "width": 240.0, "height": 120.0, "visible": true, "revision": 4,
        ]))
        #expect(message.generation == 3)
        #expect(message.placeholderID.rawValue == "canvas-1")
        #expect(message.cssRect == .init(x: 8, y: 12, width: 240, height: 120))
        #expect(RendererAttachmentGeometryMessage(body: ["generation": 3]) == nil)
        #expect(RendererAttachmentGeometryMessage(body: [
            "generation": 3, "placeholderID": "canvas-1", "x": Double.nan, "y": 0,
            "width": 1, "height": 1, "visible": true, "revision": 1,
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

    @Test("activation never silently evicts an existing active attachment")
    @MainActor
    func activationLimitPreservesExistingAttachment() throws {
        let coordinator = RendererAttachmentCoordinator(generation: 1, activeLimit: 1)
        let first = try RendererAttachmentPlaceholderID(validating: "first")
        let second = try RendererAttachmentPlaceholderID(validating: "second")
        let geometry = { (id: RendererAttachmentPlaceholderID) in
            RendererAttachmentGeometryMessage(
                generation: 1, placeholderID: id,
                cssRect: .init(x: 0, y: 0, width: 100, height: 100), visible: true, revision: 1)
        }
        #expect(coordinator.ingest(geometry(first)))
        #expect(coordinator.ingest(geometry(second)))
        #expect(coordinator.activate(first) == .activate)
        #expect(coordinator.activate(second) == .showInFullRenderer)
        #expect(coordinator.state(for: first) == .active)
        #expect(coordinator.state(for: second) == .card)
    }

    @MainActor
    private static func containsHostingView(in view: NSView) -> Bool {
        String(describing: type(of: view)).contains("NSHostingView") ||
            view.subviews.contains(where: containsHostingView)
    }

    private static let jsonCanvasBytes = Data("""
    {"nodes":[{"id":"first","type":"text","x":0,"y":0,"width":80,"height":40,"text":"First"}],"edges":[]}
    """.utf8)
}
#endif
