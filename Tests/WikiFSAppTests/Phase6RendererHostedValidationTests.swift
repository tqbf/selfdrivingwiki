#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

/// Real-window evidence for the two Phase 6 renderer surfaces. The tests use
/// the existing serialization gate and never relax the renderer session policy.
@Suite("Phase 6 hosted renderer validation", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct Phase6RendererHostedValidationTests {
    @Test("JSON Canvas mounts in an AppKit window with its deterministic outline")
    func jsonCanvasMountsWithDeterministicOutline() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let document = try JSONCanvasDocument.decode(Self.jsonCanvasInput)
        let host = NSHostingController(rootView: AnyView(JSONCanvasRendererView(document: document)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.setContentSize(NSSize(width: 720, height: 480))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        host.view.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        host.view.layoutSubtreeIfNeeded()
        let content = try #require(window.contentView)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))

        #expect(document.outline.map(\.label) == ["First note", "Second note"])
        #expect(host.view.window === window)
        #expect(host.view.frame.width == 720)
        #expect(host.view.frame.height == 480)
        #expect(png.count > 1_024)
    }

    @Test("Excalidraw loads through the restrictive package session and renders authorized input")
    func excalidrawLoadsAuthorizedInputThroughHostedSession() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let fixture = try ExcalidrawHostedFixture()
        defer { fixture.remove() }
        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let entryPoint = try #require(descriptor.webEntryPoint)
        let provider = try ValidatedRendererPackageResourceProvider(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            expectedPackageHash: package.packageHash,
            installedRoot: package.stagedRoot,
            validatedPackage: package)
        let entryURL = RendererPackageScheme.url(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            path: entryPoint.path)
        let reservation = RendererPackageReservation(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version)
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "hosted.excalidraw", data: Self.excalidrawInput)
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .source(versionID: version.id))
        let identity = InstalledRendererWebViewIdentity(
            rendererReference: descriptor.reference,
            entryURL: entryURL)
        var session: WikiAppWebViewSession?
        let view = WikiAppWebView(
            identity: identity,
            makeSession: { _, reportFailure in
                let value = WikiAppWebViewSession(
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
                session = value
                return value
            },
            onFailure: { failure in
                Issue.record("Hosted Excalidraw session failed: \(failure.kind)")
            })
        let host = NSHostingController(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.orderFront(nil)
        defer {
            host.rootView = AnyView(EmptyView())
            session?.close()
            window.orderOut(nil)
            window.contentView = nil
        }

        try await Self.waitFor(description: "hosted Excalidraw session") {
            session != nil
        }
        let liveSession = try #require(session)
        try await Self.waitForReady(liveSession, description: "hosted Excalidraw package session")
        let webView = try #require(liveSession.webView)

        #expect(webView.url?.scheme == RendererPackageScheme.name)
        #expect(webView.url?.host == "package")
        #expect(webView.url == entryURL)

        let requestAcknowledgement = await evaluateJavaScriptWithTimeout(webView, """
        (function() {
            const input = document.documentElement.dataset.rendererInput;
            window.postMessage({ rendererBridge: JSON.stringify({
                id: "excalidraw-initial-input",
                method: "input.read",
                input: JSON.parse(input)
            }) }, "*");
            return "authorized-input-requested";
        }())
        """)
        #expect(requestAcknowledgement == "authorized-input-requested")
        _ = try await Self.waitForJavaScriptString(
            "document.querySelector('svg.scene') ? 'scene-rendered' : 'pending'",
            expectedValue: "scene-rendered",
            in: webView,
            description: "authorized Excalidraw scene")

        let interaction = await evaluateJavaScriptWithTimeout(webView, """
        (function() {
            const viewer = document.getElementById("viewer");
            const scene = document.querySelector("svg.scene g");
            const before = scene.getAttribute("transform");
            viewer.dispatchEvent(new KeyboardEvent("keydown", { key: "+", bubbles: true, cancelable: true }));
            const zoomed = scene.getAttribute("transform");
            viewer.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true }));
            const panned = scene.getAttribute("transform");
            return before !== zoomed && zoomed !== panned ? "bounded-keyboard-interaction" : "interaction-missing";
        }())
        """)
        #expect(interaction == "bounded-keyboard-interaction")

        host.rootView = AnyView(EmptyView())
        try await Self.waitFor(description: "hosted Excalidraw session teardown") {
            if case .closed = liveSession.state { return true }
            return false
        }
    }

    /// The viewer must render from its OWN startup request. The test above
    /// re-posts `input.read` from the page after the session reports ready,
    /// which hides whether the package's document-load request is ever
    /// answered -- and that unassisted request is the only one production
    /// makes.
    @Test("Excalidraw renders from the package's own startup input request")
    func excalidrawRendersWithoutAReplayedBridgeRequest() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let fixture = try ExcalidrawHostedFixture()
        defer { fixture.remove() }
        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let entryPoint = try #require(descriptor.webEntryPoint)
        let provider = try ValidatedRendererPackageResourceProvider(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            expectedPackageHash: package.packageHash,
            installedRoot: package.stagedRoot,
            validatedPackage: package)
        let entryURL = RendererPackageScheme.url(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            path: entryPoint.path)
        let reservation = RendererPackageReservation(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version)
        // An inline artifact, not a source version: a fenced ```excalidraw
        // block on a page is the only input the reader's cards produce.
        let store = try GRDBWikiStore()
        let documentIdentity = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01JHOSTEDEXCALIDRAWPAGE00001"),
            pageVersionID: PageVersionID(rawValue: "01JHOSTEDEXCALIDRAWVERSION01"))
        let block = try MarkdownFencedBlock(
            documentIdentity: documentIdentity,
            parserOrdinal: 0,
            rawInfoString: "excalidraw",
            bytes: Self.excalidrawInput)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: documentIdentity.pageID,
            pageVersionID: documentIdentity.pageVersionID,
            blockID: try #require(block.blockID),
            fenceAlias: RendererFenceAlias(rawValue: "excalidraw")!,
            mimeType: try .init(validating: "application/json"),
            bytes: Self.excalidrawInput)
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .inlineArtifact(artifact))
        let identity = InstalledRendererWebViewIdentity(
            rendererReference: descriptor.reference,
            entryURL: entryURL)
        var session: WikiAppWebViewSession?
        let view = WikiAppWebView(
            identity: identity,
            makeSession: { _, reportFailure in
                let value = WikiAppWebViewSession(
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
                session = value
                return value
            },
            onFailure: { failure in
                Issue.record("Hosted Excalidraw session failed: \(failure.kind)")
            })
        let host = NSHostingController(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.orderFront(nil)
        defer {
            host.rootView = AnyView(EmptyView())
            session?.close()
            window.orderOut(nil)
            window.contentView = nil
        }

        try await Self.waitFor(description: "hosted Excalidraw session") { session != nil }
        let liveSession = try #require(session)
        try await Self.waitForReady(liveSession, description: "hosted Excalidraw package session")
        let webView = try #require(liveSession.webView)

        // No replayed envelope: whatever the page posted on its own must have
        // been answered.
        _ = try await Self.waitForJavaScriptString(
            "document.querySelector('svg.scene') ? 'scene-rendered' : 'pending'",
            expectedValue: "scene-rendered",
            in: webView,
            description: "unassisted Excalidraw scene")

        // The session creates its WKWebView inside `start()`, so a host that
        // reads `hostedView` before that runs attaches nothing and the
        // renderer draws off-screen. Evaluating JavaScript against the session
        // succeeds either way, so only the view hierarchy proves it is visible.
        #expect(webView.window === window)
        let attachedContainer = try #require(webView.superview)

        host.view.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        host.view.layoutSubtreeIfNeeded()
        #expect(attachedContainer.bounds.width > 0)
        #expect(attachedContainer.bounds.height > 0)
        #expect(webView.frame == attachedContainer.bounds)
    }

    private static func prepareApplication() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
    }

    private static func waitFor(
        description: String,
        timeout: Duration = .seconds(15),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                throw HostedRendererValidationError.timeout(description: description)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func waitForReady(
        _ session: WikiAppWebViewSession,
        description: String
    ) async throws {
        try await waitFor(description: description) {
            if case .ready = session.state { return true }
            return false
        }
    }

    private static func waitForJavaScriptString(
        _ javaScript: String,
        expectedValue: String,
        in webView: WKWebView,
        description: String,
        timeout: Duration = .seconds(15)
    ) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let value = await evaluateJavaScriptWithTimeout(webView, javaScript)
            if value == expectedValue { return expectedValue }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostedRendererValidationError.timeout(description: description)
    }

    private static let jsonCanvasInput = Data("""
    {
      "nodes": [
        {"id":"second","type":"text","x":240,"y":100,"width":180,"height":80,"text":"Second note"},
        {"id":"first","type":"text","x":20,"y":10,"width":180,"height":80,"text":"First note"}
      ],
      "edges": [{"id":"edge-1","fromNode":"first","toNode":"second"}]
    }
    """.utf8)

    private static let excalidrawInput = Data("""
    {
      "type":"excalidraw",
      "version":2,
      "elements":[
        {"id":"rectangle","type":"rectangle","x":0,"y":0,"width":160,"height":90,"strokeColor":"#007AFF"},
        {"id":"text","type":"text","x":24,"y":40,"width":100,"height":20,"text":"Hosted scene","strokeColor":"#000000"}
      ]
    }
    """.utf8)
}

private enum HostedRendererValidationError: LocalizedError {
    case timeout(description: String)

    var errorDescription: String? {
        switch self {
        case let .timeout(description): "timed out waiting for \(description)"
        }
    }
}

private final class ExcalidrawHostedFixture {
    let root: URL
    let packageDirectory: URL
    let validator: RendererPackageValidator

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tmp/Phase6RendererHostedValidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/Excalidraw", isDirectory: true)
        validator = RendererPackageValidator(packageRoot: root)
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Hosted Excalidraw fixture cleanup failed: \(error.localizedDescription)")
        }
    }
}

private extension RendererDescriptor {
    var webEntryPoint: RendererWebEntryPoint? {
        guard case let .webPackage(entryPoint) = implementation else { return nil }
        return entryPoint
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
#endif
