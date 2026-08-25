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
    @Test("provisional navigation accepts current document geometry")
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
        coordinator.handleAttachmentGeometry(.init(
            generation: generation,
            placeholderID: placeholder,
            embeddingRole: .disclosureRow,
            cssRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            visible: true,
            revision: 1))

        #expect(coordinator.attachmentGeneration == generation)
        #expect(coordinator.attachmentState(for: placeholder) == .card)
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

    @Test("JSON Canvas reserves an expanded inline surface")
    func jsonCanvasReservesExpandedInlineSurface() {
        #expect(RendererAttachmentHostPolicy.preferredReservedHeight(
            for: BuiltInRendererReference.reference(for: .jsonCanvas)) == 480)
    }

    @Test("Escape exits the hosted native attachment and restores reader focus")
    @MainActor
    func escapeExitsNativeAttachment() throws {
        let webView = WikiReaderWebView(); let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }
        let placeholder = try RendererAttachmentPlaceholderID(validating: "escape-canvas")
        container.updateAttachmentViewport(.init(x: 40, y: 80, width: 160, height: 96), for: placeholder)
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

    @Test("Escape synchronizes the coordinator before allowing attachment reactivation")
    @MainActor
    func escapeSynchronizesCoordinatorBeforeReactivation() throws {
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
        let placeholder = try RendererAttachmentPlaceholderID(validating: "escape-synchronized-canvas")
        try Self.admitJSONCanvasPlaceholder(placeholder, coordinator: coordinator, webView: webView)
        coordinator.handleAttachmentGeometry(.init(
            generation: generation,
            placeholderID: placeholder,
            cssRect: .init(x: 20, y: 20, width: 160, height: 96),
            visible: true,
            revision: 1))
        #expect(coordinator.activateAttachment(placeholder) == .activate)

        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53))
        window.sendEvent(escape)

        #expect(coordinator.attachmentState(for: placeholder) == .card)
        #expect(coordinator.activateAttachment(placeholder) == .activate)
        #expect(container.subviews.flatMap(\.subviews).contains {
            $0.accessibilityIdentifier() == "renderer-attachment-escape-synchronized-canvas"
        })
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
        Self.startLifecycleLoad(coordinator, webView: webView)
        try await Self.waitUntil("reader document") { webView.isLoading == false }
        try await Self.waitForReporter(in: webView)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "dom-removal-canvas")
        let generation = try #require(coordinator.attachmentGeneration)
        try Self.admitJSONCanvasPlaceholder(placeholder, coordinator: coordinator, webView: webView)
        try await Self.runJS("var e=document.createElement('section');e.id='dom-removal-canvas';e.className='sdw-renderer-card';e.style.cssText='width:160px;height:96px';document.body.appendChild(e);window.__sdwRendererAttachmentReport(\(generation));", in: webView)
        try await Self.waitUntil("placeholder card") { coordinator.attachmentState(for: placeholder) == .card }
        #expect(coordinator.activateAttachment(placeholder) == .activate)
        #expect(coordinator.attachmentState(for: placeholder) == .active)
        #expect(container.subviews.flatMap(\.subviews).contains { $0.accessibilityIdentifier() == "renderer-attachment-dom-removal-canvas" })
        try await Self.runJS("document.getElementById('dom-removal-canvas').remove();", in: webView)
        try await Self.waitUntil("placeholder removal") { coordinator.attachmentState(for: placeholder) == .closed }
        #expect(container.subviews.flatMap(\.subviews).contains { $0.accessibilityIdentifier() == "renderer-attachment-dom-removal-canvas" } == false)
        #expect(window.firstResponder === webView)
    }

    @Test("visible inline placeholder mounts automatically and DOM removal releases it")
    @MainActor
    func visibleInlinePlaceholderMountsAndRemoves() async throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let coordinator = WikiReaderRep.Coordinator()
        coordinator.webView = webView
        coordinator.attachmentContainer = container
        webView.coordinator = coordinator
        webView.navigationDelegate = coordinator
        Self.startLifecycleLoad(coordinator, webView: webView)
        try await Self.waitUntil("reader document") { webView.isLoading == false }
        try await Self.waitForReporter(in: webView)

        let placeholder = try RendererAttachmentPlaceholderID(validating: "inline-hosted-canvas")
        let generation = try #require(coordinator.attachmentGeneration)
        try Self.admitInlineJSONCanvasPlaceholder(
            placeholder,
            coordinator: coordinator,
            webView: webView)
        try await Self.runJS("""
        var e=document.createElement('span');
        e.id='inline-hosted-canvas';
        e.className='sdw-inline-renderer';
        e.style.cssText='display:block;width:240px;height:160px';
        e.innerHTML='<span class="sdw-inline-renderer__fallback">fallback</span>';
        document.body.appendChild(e);
        window.__sdwRendererAttachmentReport(\(generation));
        """, in: webView)

        try await Self.waitUntil("inline mount") {
            coordinator.inlineAttachmentState(for: placeholder) == .mounted
                && container.ownsMountedAttachment(named: placeholder)
        }
        #expect(coordinator.attachmentState(for: placeholder) == .unresolved)
        #expect(try await Self.javaScriptBoolean(
            "document.getElementById('inline-hosted-canvas').textContent.includes('fallback')",
            in: webView))

        try await Self.runJS("document.getElementById('inline-hosted-canvas').remove();", in: webView)
        try await Self.waitUntil("inline removal") {
            coordinator.inlineAttachmentState(for: placeholder) == .removed
                && !container.ownsMountedAttachment(named: placeholder)
        }
    }

    @Test("removing an inactive placeholder preserves the active native attachment")
    @MainActor
    func removingInactivePlaceholderPreservesActiveAttachment() throws {
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
        let active = try RendererAttachmentPlaceholderID(validating: "active-canvas")
        let inactive = try RendererAttachmentPlaceholderID(validating: "inactive-canvas")
        try Self.admitJSONCanvasPlaceholder(active, coordinator: coordinator, webView: webView)
        try Self.admitJSONCanvasPlaceholder(inactive, coordinator: coordinator, webView: webView, parserOrdinal: 1)
        let geometry = { (placeholderID: RendererAttachmentPlaceholderID) in
            RendererAttachmentGeometryMessage(
                generation: generation,
                placeholderID: placeholderID,
                cssRect: .init(x: 20, y: 20, width: 160, height: 96),
                visible: true,
                revision: 1)
        }
        coordinator.handleAttachmentGeometry(geometry(active))
        coordinator.handleAttachmentGeometry(geometry(inactive))
        #expect(coordinator.activateAttachment(active) == .activate)

        coordinator.handleAttachmentRemoval(inactive, generation: generation)

        #expect(coordinator.attachmentState(for: active) == .active)
        #expect(coordinator.attachmentState(for: inactive) == .closed)
        #expect(container.subviews.flatMap(\.subviews).contains {
            $0.accessibilityIdentifier() == "renderer-attachment-active-canvas"
        })
        #expect((window.firstResponder as? NSView)?.accessibilityIdentifier() == "renderer-attachment-active-canvas")
    }

    @Test("collapse and failure for another placeholder preserve the active native attachment")
    @MainActor
    func wrongPlaceholderCollapseAndFailurePreserveActiveAttachment() throws {
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
        let active = try RendererAttachmentPlaceholderID(validating: "active-ownership-canvas")
        let inactive = try RendererAttachmentPlaceholderID(validating: "inactive-ownership-canvas")
        try Self.admitJSONCanvasPlaceholder(active, coordinator: coordinator, webView: webView)
        try Self.admitJSONCanvasPlaceholder(inactive, coordinator: coordinator, webView: webView, parserOrdinal: 1)
        let geometry = { (placeholderID: RendererAttachmentPlaceholderID) in
            RendererAttachmentGeometryMessage(
                generation: generation,
                placeholderID: placeholderID,
                cssRect: .init(x: 20, y: 20, width: 160, height: 96),
                visible: true,
                revision: 1)
        }
        coordinator.handleAttachmentGeometry(geometry(active))
        coordinator.handleAttachmentGeometry(geometry(inactive))
        #expect(coordinator.activateAttachment(active) == .activate)

        coordinator.collapseAttachment(inactive)
        coordinator.failAttachment(inactive)

        #expect(coordinator.attachmentState(for: active) == .active)
        #expect(coordinator.attachmentState(for: inactive) == .failed)
        #expect(container.subviews.flatMap(\.subviews).contains {
            $0.accessibilityIdentifier() == "renderer-attachment-active-ownership-canvas"
        })
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
        Self.startLifecycleLoad(coordinator, webView: webView, markdown: "# First")
        try await Self.waitUntil("first document") { webView.isLoading == false }
        let placeholder = try RendererAttachmentPlaceholderID(validating: "generation-canvas")
        let firstGeneration = try #require(coordinator.attachmentGeneration)
        try Self.admitJSONCanvasPlaceholder(placeholder, coordinator: coordinator, webView: webView)
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
        Self.startLifecycleLoad(coordinator, webView: webView)
        try await Self.waitUntil("initial reader navigation") { webView.isLoading == false }
        let placeholder = try RendererAttachmentPlaceholderID(validating: "reload-canvas")
        let generation = try #require(coordinator.attachmentGeneration)
        try Self.admitJSONCanvasPlaceholder(placeholder, coordinator: coordinator, webView: webView)
        coordinator.handleAttachmentGeometry(.init(generation: generation, placeholderID: placeholder, cssRect: .init(x: 20, y: 20, width: 160, height: 96), visible: true, revision: 1))
        #expect(coordinator.activateAttachment(placeholder) == .activate)
        #expect(coordinator.attachmentState(for: placeholder) == .active)
        #expect(container.subviews.flatMap(\.subviews).contains { $0.accessibilityIdentifier() == "renderer-attachment-reload-canvas" })
        webView.reload()
        try await Self.waitUntil("reload removed native child") {
            container.subviews.flatMap(\.subviews).contains {
                $0.accessibilityIdentifier() == "renderer-attachment-reload-canvas"
            } == false
        }
        #expect(coordinator.attachmentGeneration == generation)
        #expect(coordinator.attachmentState(for: placeholder) == .unresolved)
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
        container.updateAttachmentViewport(expectedVisibleRect, for: placeholder)
        container.activateAttachment(named: placeholder)

        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-hosted-canvas"
        })
        #expect(child.frame == expectedVisibleRect)
        #expect(child.accessibilityRole() == .group)
        #expect(child.accessibilityLabel() == "Interactive renderer")
        #expect(container.hitTest(.init(x: 80, y: 100)) === child)
        #expect(container.hitTest(.init(x: 300, y: 260)) === webView)

        container.removeAttachment(named: placeholder)
        #expect(container.subviews.flatMap(\.subviews).contains { $0 === child } == false)
        #expect(window.firstResponder === webView)

        container.activateAttachment(named: placeholder)
        #expect(container.subviews.flatMap(\.subviews).contains { $0.accessibilityIdentifier() == "renderer-attachment-hosted-canvas" })
        container.teardown()
        #expect(container.subviews.isEmpty)
    }

    @Test("keyed children retain independent frames and route overlap to the focused child")
    @MainActor
    func keyedChildrenRetainFramesAndRouteOverlapToFocusedChild() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let first = try RendererAttachmentPlaceholderID(validating: "keyed-first-canvas")
        let second = try RendererAttachmentPlaceholderID(validating: "keyed-second-canvas")
        let firstRect = CGRect(x: 20, y: 20, width: 140, height: 120)
        let secondRect = CGRect(x: 220, y: 20, width: 140, height: 120)
        container.updateAttachmentViewport(firstRect, for: first)
        container.updateAttachmentViewport(secondRect, for: second)
        container.activateAttachment(named: first, takesFocus: false)
        container.activateAttachment(named: second, takesFocus: false)

        let firstChild = try #require(container.attachmentChild(named: first))
        let secondChild = try #require(container.attachmentChild(named: second))
        #expect(container.mountedAttachmentCount == 2)
        #expect(firstChild.frame == firstRect)
        #expect(secondChild.frame == secondRect)
        #expect(container.hitTest(.init(x: 260, y: 80)) === secondChild)

        let overlapRect = CGRect(x: 80, y: 20, width: 140, height: 120)
        container.updateAttachmentViewport(overlapRect, for: first)
        container.focusAttachment(named: first)
        #expect(container.hitTest(.init(x: 100, y: 80)) === firstChild)

        container.updateAttachmentViewport(overlapRect, for: second)
        container.focusAttachment(named: second)
        #expect(container.hitTest(.init(x: 100, y: 80)) === secondChild)
    }

    @Test("removing one keyed child preserves the other mounted child")
    @MainActor
    func removingOneKeyedChildPreservesOtherMountedChild() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let first = try RendererAttachmentPlaceholderID(validating: "removal-first-canvas")
        let second = try RendererAttachmentPlaceholderID(validating: "removal-second-canvas")
        container.updateAttachmentViewport(.init(x: 20, y: 20, width: 140, height: 120), for: first)
        container.updateAttachmentViewport(.init(x: 220, y: 20, width: 140, height: 120), for: second)
        container.activateAttachment(named: first, takesFocus: false)
        container.activateAttachment(named: second, takesFocus: false)
        let retainedChild = try #require(container.attachmentChild(named: second))

        container.removeAttachment(named: first)

        #expect(container.attachmentChild(named: first) == nil)
        #expect(container.attachmentChild(named: second) === retainedChild)
        #expect(container.mountedAttachmentCount == 1)
    }

    @Test("auto-mounted attachment shows the focus indicator only while focused")
    @MainActor
    func autoMountedAttachmentFocusIndicatorTracksResponder() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let placeholder = try RendererAttachmentPlaceholderID(validating: "focus-indicator-canvas")
        container.updateAttachmentViewport(.init(x: 40, y: 80, width: 240, height: 160), for: placeholder)
        _ = window.makeFirstResponder(webView)
        container.activateAttachment(named: placeholder, takesFocus: false)

        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-focus-indicator-canvas"
        })
        #expect(window.firstResponder === webView)
        #expect(child.layer?.borderWidth == 0)

        container.focusAttachment(named: placeholder)
        #expect(window.firstResponder === child)
        #expect(child.layer?.borderWidth == 2)

        _ = window.makeFirstResponder(webView)
        #expect(window.firstResponder === webView)
        #expect(child.layer?.borderWidth == 0)
    }

    @Test("hosted attachment exposes renderer content without duplicate native controls")
    @MainActor
    func hostedAttachmentHasNoDuplicateNativeControls() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let placeholder = try RendererAttachmentPlaceholderID(validating: "renderer-content-canvas")
        let authoredTitle = "System architecture with a long descriptive title"
        let content = AnyView(Color.blue.accessibilityIdentifier("renderer-content"))
        container.updateAttachmentViewport(.init(x: 40, y: 80, width: 240, height: 160), for: placeholder)
        container.activateAttachment(named: placeholder, title: authoredTitle, content: content)
        container.layoutSubtreeIfNeeded()

        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-renderer-content-canvas"
        })
        #expect(child.accessibilityLabel() == "\(authoredTitle) renderer")
        #expect(child.subviews.flatMap(\.subviews).contains { $0 is NSButton } == false)
        let center = child.convert(NSPoint(x: child.bounds.midX, y: child.bounds.midY), to: container)
        #expect(container.hitTest(center) !== webView)
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
        container.updateAttachmentViewport(.init(x: 40, y: 80, width: 160, height: 96), for: placeholder)

        container.activateAttachment(named: placeholder, content: try factory.makeView(for: input))
        container.layoutSubtreeIfNeeded()

        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-mounted-json-canvas"
        })
        #expect(Self.containsHostingView(in: child))
        let canvasHit = container.hitTest(.init(x: 100, y: 100))
        #expect(canvasHit !== child)
        #expect(canvasHit !== webView)
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

    @Test("an admitted JSON Canvas fence mounts only after disclosure activation")
    @MainActor
    func admittedJSONCanvasFenceMountsAfterDisclosureActivation() throws {
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
        let placeholder = try RendererAttachmentPlaceholderID(validating: "auto-mounted-canvas")
        try Self.admitJSONCanvasPlaceholder(placeholder, coordinator: coordinator, webView: webView)
        let geometry = RendererAttachmentGeometryMessage(
            generation: generation,
            placeholderID: placeholder,
            cssRect: .init(x: 40, y: 80, width: 240, height: 160),
            visible: true,
            revision: 1)

        _ = window.makeFirstResponder(webView)
        coordinator.handleAttachmentGeometry(geometry)

        #expect(coordinator.attachmentState(for: placeholder) == .card)
        #expect(window.firstResponder === webView)

        #expect(coordinator.activateAttachment(placeholder) == .activate)
        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-auto-mounted-canvas"
        })
        #expect(Self.containsHostingView(in: child))
        #expect(child.frame == .zero)
        #expect(window.firstResponder === child)

        coordinator.collapseAttachment(placeholder)

        #expect(coordinator.attachmentState(for: placeholder) == .card)
        #expect(container.ownsMountedAttachment(named: placeholder) == false)
        #expect(window.firstResponder === webView)
    }

    @Test("reader attachment composition accepts package-style inline renderers through a generic resolver")
    func packageStyleInlineRendererUsesGenericComposition() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Reader/WikiReaderView.swift"),
            encoding: .utf8)

        #expect(source.contains("RendererInlineAttachmentResolver"))
        #expect(source.contains("BuiltInRendererReference.reference(for: .jsonCanvas)") == false)
        #expect(source.contains(#"__sdwRendererAttachmentReserve(\"\(identifier)\""#))
        #expect(source.contains("setRowExpansion(true, for: placeholderID)"))
        #expect(source.contains("setCollapseControl") == false)

        let pageDetail = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Pages/PageDetailView.swift"),
            encoding: .utf8)
        #expect(pageDetail.contains("RendererInlineAttachmentResolverFactory.make"))
        #expect(pageDetail.contains("installedRendererFactory"))
        #expect(pageDetail.contains("installedRendererFactoryInputs"))
    }

    @Test("a package-style renderer remains collapsed until its disclosure activates generic composition")
    @MainActor
    func packageStyleInlineRendererStartsCollapsedUntilDisclosureActivation() throws {
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
        var resolverCalls = 0
        var presented = 0
        webView.onRendererActivation = { _, _ in presented += 1 }
        coordinator.inlineAttachmentResolver = { _, _, _ in
            resolverCalls += 1
            return .content(AnyView(Text("package-style-inline-renderer")))
        }

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
            fenceKind: .excalidraw,
            mimeType: try .init(validating: "application/json"),
            bytes: bytes)
        let packageReference = RendererReference(
            packageID: try .init(validating: "org.example.package-renderer"),
            version: try .init(validating: "1.0.0"),
            registrationID: try .init(validating: "package-viewer"))
        let placeholder = try RendererAttachmentPlaceholderID(validating: "package-inline-renderer")
        admission.register(context: .init(
            pageID: identity.pageID,
            pageVersionID: identity.pageVersionID,
            blockID: artifact.blockID,
            rendererReference: packageReference,
            input: .inlineArtifact(artifact),
            capability: admission.capability,
            generation: generation), attachmentPlaceholderID: placeholder)

        coordinator.handleAttachmentGeometry(.init(
            generation: generation,
            placeholderID: placeholder,
            cssRect: .init(x: 40, y: 80, width: 240, height: 160),
            visible: true,
            revision: 1))

        // Geometry registers the collapsed card only. It must not start the
        // resolver/factory path, mount a host child, begin a session, or open
        // the full renderer before the row's explicit disclosure action.
        #expect(resolverCalls == 0)
        #expect(coordinator.attachmentState(for: placeholder) == .card)
        #expect(container.subviews.flatMap(\.subviews).contains {
            $0.accessibilityIdentifier() == "renderer-attachment-package-inline-renderer"
        } == false)
        #expect(presented == 0)

        // This is the same explicit entry point used by the disclosure bridge.
        #expect(coordinator.activateAttachment(placeholder) == .activate)
        #expect(resolverCalls == 1)
        #expect(coordinator.attachmentState(for: placeholder) == .active)
        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-package-inline-renderer"
        })
        #expect(Self.containsHostingView(in: child))
        #expect(child.subviews.flatMap(\.subviews).contains { $0 is NSButton } == false)
        #expect(presented == 0)
    }

    @Test("a stale package failure cannot fail a remounted attachment in a newer reader generation")
    @MainActor
    func stalePackageFailurePreservesNewGenerationAttachment() throws {
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
        var failures: [@MainActor (RendererSessionFailure) -> Void] = []
        coordinator.inlineAttachmentResolver = { _, _, onFailure in
            failures.append(onFailure)
            return .content(AnyView(Text("package-generation-marker")))
        }

        let reference = RendererReference(
            packageID: try .init(validating: "org.example.package-renderer"),
            version: try .init(validating: "1.0.0"),
            registrationID: try .init(validating: "package-viewer"))
        let placeholder = try RendererAttachmentPlaceholderID(validating: "stale-package-placeholder")
        let admitAndReport: () throws -> Void = {
            let generation = try #require(coordinator.attachmentGeneration)
            let admission = try #require(webView.rendererActivationAdmission)
            let identity = Self.lifecycleIdentity
            let bytes = Self.jsonCanvasBytes
            let block = try MarkdownFencedBlock(
                documentIdentity: identity,
                parserOrdinal: 0,
                rawInfoString: "excalidraw",
                bytes: bytes)
            let artifact = try RendererEmbeddedContent.InlineArtifact(
                pageID: identity.pageID,
                pageVersionID: identity.pageVersionID,
                blockID: try #require(block.blockID),
                fenceKind: .excalidraw,
                mimeType: try .init(validating: "application/json"),
                bytes: bytes)
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
        }

        try admitAndReport()
        #expect(coordinator.attachmentState(for: placeholder) == .card)
        #expect(coordinator.activateAttachment(placeholder) == .activate)
        #expect(coordinator.attachmentState(for: placeholder) == .active)
        coordinator.startLoad(markdown: "# New generation", documentIdentity: Self.lifecycleIdentity, isLoading: .constant(true))
        try admitAndReport()
        #expect(coordinator.attachmentState(for: placeholder) == .card)
        #expect(coordinator.activateAttachment(placeholder) == .activate)
        #expect(coordinator.attachmentState(for: placeholder) == .active)

        let staleFailure = try #require(failures.first)
        staleFailure(.init(sessionID: .init(rawValue: UUID()), kind: .navigationFailed))

        #expect(coordinator.attachmentState(for: placeholder) == .active)
        #expect(container.subviews.flatMap(\.subviews).contains {
            $0.accessibilityIdentifier() == "renderer-attachment-stale-package-placeholder"
        })
    }

    @Test("geometry from an inactive placeholder cannot move the active attachment")
    @MainActor
    func inactivePlaceholderGeometryPreservesActiveAttachment() throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 400, height: 300)
        container.layout()
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        let coordinator = WikiReaderRep.Coordinator()
        coordinator.webView = webView
        coordinator.attachmentContainer = container
        Self.startLifecycleLoad(coordinator, webView: webView)
        let generation = try #require(coordinator.attachmentGeneration)
        let active = try RendererAttachmentPlaceholderID(validating: "geometry-active-canvas")
        let inactive = try RendererAttachmentPlaceholderID(validating: "geometry-inactive-canvas")
        try Self.admitJSONCanvasPlaceholder(active, coordinator: coordinator, webView: webView)
        try Self.admitJSONCanvasPlaceholder(inactive, coordinator: coordinator, webView: webView, parserOrdinal: 1)

        coordinator.handleAttachmentGeometry(.init(
            generation: generation,
            placeholderID: active,
            cssRect: .init(x: 20, y: 20, width: 160, height: 96),
            visible: true,
            revision: 1))
        #expect(coordinator.activateAttachment(active) == .activate)
        container.layoutSubtreeIfNeeded()
        let child = try #require(container.subviews.flatMap(\.subviews).first {
            $0.accessibilityIdentifier() == "renderer-attachment-geometry-active-canvas"
        })
        let activeFrame = child.frame

        coordinator.handleAttachmentGeometry(.init(
            generation: generation,
            placeholderID: inactive,
            cssRect: .init(x: 220, y: 180, width: 140, height: 80),
            visible: true,
            revision: 1))

        #expect(coordinator.attachmentState(for: active) == .active)
        #expect(coordinator.attachmentState(for: inactive) == .card)
        #expect(child.frame == activeFrame)
    }

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
            fenceKind: .excalidraw,
            mimeType: try .init(validating: "application/json"),
            bytes: bytes)
        let reference = RendererReference(
            packageID: BundledRendererPackages.excalidrawPackageID,
            version: BundledRendererPackages.excalidrawVersion,
            registrationID: BundledRendererPackages.excalidrawRegistrationID)
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

    @MainActor
    private static func admitInlineJSONCanvasPlaceholder(
        _ placeholderID: RendererAttachmentPlaceholderID,
        coordinator: WikiReaderRep.Coordinator,
        webView: WikiReaderWebView
    ) throws {
        let generation = try #require(coordinator.attachmentGeneration)
        let admission = try #require(webView.rendererActivationAdmission)
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
            rendererReference: BuiltInRendererReference.reference(for: .jsonCanvas),
            input: .source(versionID: try #require(source.sourceVersionID)),
            capability: admission.capability,
            generation: generation), attachmentPlaceholderID: placeholderID)
    }

    /// Admit `placeholderID` as a JSON Canvas fence — the one renderer with a
    /// native inline attachment. Activation mounts the factory's SwiftUI view,
    /// so these lifecycle tests exercise the same path production takes rather
    /// than an unadmitted placeholder. `parserOrdinal` keeps sibling
    /// placeholders on distinct block identities.
    @MainActor
    private static func admitJSONCanvasPlaceholder(
        _ placeholderID: RendererAttachmentPlaceholderID,
        coordinator: WikiReaderRep.Coordinator,
        webView: WikiReaderWebView,
        parserOrdinal: Int = 0
    ) throws {
        let generation = try #require(coordinator.attachmentGeneration)
        let admission = try #require(webView.rendererActivationAdmission)
        let block = try MarkdownFencedBlock(
            documentIdentity: lifecycleIdentity,
            parserOrdinal: parserOrdinal,
            rawInfoString: "jsoncanvas",
            bytes: jsonCanvasBytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: lifecycleIdentity.pageID,
            pageVersionID: lifecycleIdentity.pageVersionID,
            blockID: try #require(block.blockID),
            fenceKind: .jsoncanvas,
            mimeType: try .init(validating: "application/json"),
            bytes: jsonCanvasBytes)
        admission.register(context: .init(
            pageID: lifecycleIdentity.pageID,
            pageVersionID: lifecycleIdentity.pageVersionID,
            blockID: artifact.blockID,
            rendererReference: BuiltInRendererReference.reference(for: .jsonCanvas),
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
