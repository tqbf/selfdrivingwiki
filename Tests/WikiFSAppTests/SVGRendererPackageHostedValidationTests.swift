#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// Real-window evidence for the reviewed SVG package's manifest-declared fence.
/// This suite hosts the production reader, clicks its real disclosure row, and
/// observes the package frame without loading the viewer as a standalone page.
/// Opt in with `WIKIFS_APP_TESTS=1`.
@Suite("SVG renderer hosted validation", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct SVGRendererPackageHostedValidationTests {
    @Test("an SVG fence expands, renders as an isolated image, and collapses")
    func svgFenceExpandsRendersAndCollapses() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = NSApplication.shared

        let fixture = try SVGHostedFixture()
        defer { fixture.remove() }
        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let claim = try #require(descriptor.fenceClaims.only)
        #expect(package.manifest.revision == RendererManifestRevision.fenceClaims)
        #expect(descriptor.reference.version.rawValue == "1.0.1")
        #expect(claim.alias.rawValue == "svg")
        #expect(claim.inlineMIMEType.rawValue == "image/svg+xml")

        let runtime = try await RendererRuntimeFactory(layout: fixture.layout).assemble()
        // Best-effort disposal on failure paths: a mid-test throw in a
        // serialized suite must not leak the runtime's store coordination.
        var disposedRuntime = false
        defer {
            // Best-effort disposal on failure paths; the happy path awaits
            // disposal below and flips the flag first.
            if !disposedRuntime {
                disposedRuntime = true
                Task { try? await runtime.dispose() }
            }
        }
        let installedHost = InstalledRendererHost(services: runtime.services)
        try #require(await installedHost.installRendererDirectory(fixture.packageDirectory))
        let installedDescriptor = try #require(installedHost.inputs.availableDescriptors.first {
            $0.reference == descriptor.reference
        })

        let store = try GRDBWikiStore()
        let model = WikiStoreModel(store: store)
        model.rendererBuiltInDescriptors = BuiltInRendererDescriptors.all
        model.rendererAvailableDescriptors = installedHost.inputs.availableDescriptors
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="48" height="32" viewBox="0 0 48 32">
          <rect width="48" height="32" fill="#4b7bec"/>
        </svg>
        """
        let document = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01HSVGFENCEPAGE00000000001"),
            pageVersionID: PageVersionID(rawValue: "01HSVGFENCEVERSION0000001"))
        let markdown = "```svg\n\(svg)\n```"
        // The reader loads the selected source's content through the store,
        // exactly as a real page surface does. The host-owned document
        // identity admits renderer activation, as on a real page surface.
        model.addSource(filename: "diagram.md", data: Data(markdown.utf8))
        #expect(model.selectSource(byDisplayName: "diagram"))
        let view = WikiReaderView(
            markdown: markdown,
            currentSelection: model.selection,
            store: model,
            documentIdentity: document,
            onRendererActivation: { _, _ in },
            inlineRendererDescriptors: [installedDescriptor],
            rendererPackageInputs: RendererPackageEmbedInputs.make(from: installedHost.inputs))
        let hosting = NSHostingController(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentViewController = hosting
        window.orderFrontRegardless()
        // The embed iframe is `loading="lazy"`: WebKit defers its load until
        // the window is visible and the frame intersects the viewport.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            hosting.rootView = AnyView(EmptyView())
            window.orderOut(nil)
        }

        let webView = try await Self.waitForReader(in: hosting.view)
        let observer = SVGFrameImageObserver()
        let probeScript = WKUserScript(
            source: SVGFrameImageObserver.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false)
        webView.configuration.userContentController.add(observer, name: SVGFrameImageObserver.messageName)
        webView.configuration.userContentController.addUserScript(probeScript)
        defer {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: SVGFrameImageObserver.messageName)
            // Teardown of a throwaway reader webview: clearing all user
            // scripts also drops the reader's own injections, which is fine
            // because nothing evaluates them after this point.
            webView.configuration.userContentController.removeAllUserScripts()
        }

        try await Self.waitForJavaScriptTrue(
            "document.querySelector('.sdw-renderer-card__row') !== null",
            in: webView,
            description: "production SVG disclosure row")
        let initialState = try #require(await evaluateJavaScriptWithTimeout(
            webView,
            "String(document.querySelectorAll('iframe.sdw-renderer-embed').length)",
            timeout: .seconds(5)))
        #expect(initialState == "0")

        let clickResult = try #require(await evaluateJavaScriptWithTimeout(
            webView,
            "document.querySelector('.sdw-renderer-card__row').click(); 'clicked'",
            timeout: .seconds(5)))
        #expect(clickResult == "clicked")

        // Keep viewport intersection guaranteed for the lazy frame.
        _ = try #require(await evaluateJavaScriptWithTimeout(
            webView,
            "var r=document.querySelector('.sdw-renderer-card__row'); r.scrollIntoView({block:'center'}); 'scrolled'",
            timeout: .seconds(5)))

        try await Self.waitForJavaScriptTrue(
            "document.querySelectorAll('iframe.sdw-renderer-embed').length === 1",
            in: webView,
            description: "production package frame mount")
        // The hosted window reports `document.visibilityState === "hidden"`
        // (background test process), so WebKit defers the production iframe's
        // `loading="lazy"` load indefinitely. A visible reader starts the
        // frame load; emulate that visibility by loading the frame eagerly.
        _ = try #require(await evaluateJavaScriptWithTimeout(
            webView,
            "(function(){var f=document.querySelector('iframe.sdw-renderer-embed');if(!f)return 'no-iframe';f.removeAttribute('loading');return 'eager';})()",
            timeout: .seconds(5)))
        let evidence = try await observer.waitForLoadedImage()
        #expect(evidence.width > 0)
        #expect(evidence.height > 0)
        #expect(evidence.source.hasPrefix("data:image/svg+xml;base64,"))
        // The viewer must mount the exact authorized bytes, not just any image.
        let mountedBase64 = String(evidence.source.dropFirst("data:image/svg+xml;base64,".count))
        let mountedBytes = try #require(Data(base64Encoded: mountedBase64))
        #expect(String(decoding: mountedBytes, as: UTF8.self).contains(#"<rect width="48" height="32""#))
        #expect(evidence.documentContainsSVGElement == false)
        let readerHTML = try #require(await evaluateJavaScriptWithTimeout(
            webView,
            "document.documentElement.outerHTML",
            timeout: .seconds(5)))
        #expect(readerHTML.contains("data:image/svg+xml;base64,") == false)
        #expect(readerHTML.contains("<rect width=\"48\"") == false)

        let collapseResult = try #require(await evaluateJavaScriptWithTimeout(
            webView,
            "document.querySelector('.sdw-renderer-card__row').click(); 'clicked'",
            timeout: .seconds(5)))
        #expect(collapseResult == "clicked")
        try await Self.waitForJavaScriptTrue(
            "document.querySelectorAll('iframe.sdw-renderer-embed').length === 0",
            in: webView,
            description: "package frame disposal after collapse")

        disposedRuntime = true
        try await runtime.dispose()
    }

    private static func waitForReader(
        in view: NSView,
        timeout: Duration = .seconds(15)
    ) async throws -> WikiReaderWebView {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let reader = findReader(in: view) { return reader }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SVGHostedValidationError.timeout("production reader WebView")
    }

    private static func findReader(in view: NSView) -> WikiReaderWebView? {
        if let reader = view as? WikiReaderWebView { return reader }
        for child in view.subviews {
            if let reader = findReader(in: child) { return reader }
        }
        return nil
    }

    private static func waitForJavaScriptTrue(
        _ javaScript: String,
        in webView: WKWebView,
        description: String,
        timeout: Duration = .seconds(20)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            // Poll with the non-recording API on purpose: the recording
            // helper's 2-second timeout would fire a spurious Issue while the
            // loop is still legitimately retrying under pool starvation.
            let raw: Any?
            do {
                raw = try await webView.evaluateJavaScript("String(\(javaScript))")
            } catch {
                // A single failed evaluation inside the retry loop is
                // expected; the deadline below bounds the total wait.
                raw = nil
            }
            if (raw as? String) == "true" { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SVGHostedValidationError.timeout(description)
    }
}

@MainActor
private final class SVGFrameImageObserver: NSObject, WKScriptMessageHandler {
    static let messageName = "svgHostedImageProbe"
    static let script = """
    (function () {
      function report(image) {
        if (!image || !image.src.startsWith('data:image/svg+xml;base64,')) return;
        window.webkit.messageHandlers.svgHostedImageProbe.postMessage({
          width: image.naturalWidth,
          height: image.naturalHeight,
          source: image.src,
          documentContainsSVGElement: document.querySelector('svg') !== null
        });
      }
      document.addEventListener('load', function (event) {
        if (event.target instanceof HTMLImageElement) report(event.target);
      }, true);
      addEventListener('DOMContentLoaded', function () {
        document.querySelectorAll('img').forEach(report);
      }, { once: true });
    }());
    """

    private var evidence: SVGFrameImageEvidence?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName,
              message.frameInfo.isMainFrame == false,
              let body = message.body as? [String: Any],
              let width = body["width"] as? Int,
              let height = body["height"] as? Int,
              let source = body["source"] as? String,
              let documentContainsSVGElement = body["documentContainsSVGElement"] as? Bool
        else { return }
        evidence = SVGFrameImageEvidence(
            width: width,
            height: height,
            source: source,
            documentContainsSVGElement: documentContainsSVGElement)
    }

    func waitForLoadedImage(timeout: Duration = .seconds(30)) async throws -> SVGFrameImageEvidence {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let evidence, evidence.width > 0, evidence.height > 0 { return evidence }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SVGHostedValidationError.timeout("nonzero SVG image load inside the package frame")
    }
}

private struct SVGFrameImageEvidence {
    let width: Int
    let height: Int
    let source: String
    let documentContainsSVGElement: Bool
}

private enum SVGHostedValidationError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let description): "Timed out waiting for \(description)."
        }
    }
}

private struct SVGHostedFixture {
    let root: URL
    let packageDirectory: URL
    let validator: RendererPackageValidator
    let layout: RendererPackageStoreLayout

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "SVGRendererHostedValidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "RendererPackages/SVG")
        validator = RendererPackageValidator(packageRoot: root.appending(path: "validation"))
        layout = try RendererPackageStoreLayout(appGroupContainerRoot: root.appending(path: "machine"))
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("SVG hosted fixture cleanup failed: \(error)") }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
#endif
