#if os(macOS)
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

/// Regression: the DOM embed injection once threw a SyntaxError on every call
/// because the sandbox JSON was wrapped in a JS string literal whose inner
/// quotes terminated it. The injection must succeed and the package frame
/// must load under its token origin.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct InjectionReproTests {
    @Test("injection reproduces the JS exception")
    func repro() async throws {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        container.frame = .init(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { container.teardown(); window.orderOut(nil) }

        // A card shaped like a real JSON Canvas fence row.
        let body = """
        <section class="sdw-renderer-card" id="row-1" data-renderer-expanded="true">
          <div class="sdw-renderer-card__row" style="display:flex">x</div>
          <div class="sdw-renderer-card__expansion" id="row-1-expansion"></div>
        </section>
        """
        // Load via handler-served navigation — the production reader path.
        // (HTML-string parents never reach scheme handlers for subframes.)
        WikiReaderDocumentSchemeHandler.setPendingHTML(WikiReaderView.documentHTML(body))
        webView.load(URLRequest(url: WikiReaderDocumentOrigin.url!))
        let deadline = ContinuousClock.now + .seconds(10)
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))

        let frameToken = RendererFrameOriginToken.generate()
        let plan = RendererDOMEmbedPlan.packageFrame(RendererPackageFramePlan(
            rendererReference: RendererReference(
                packageID: RendererPackageID(rawValue: "org.selfdrivingwiki.json-canvas-readonly")!,
                version: RendererPackageVersion(rawValue: "1.1.6")!,
                registrationID: RendererRegistrationID(rawValue: "json-canvas")!),
            frameToken: frameToken,
            entryURL: RendererFramePackageURL.frameURL(
                token: frameToken,
                packageID: RendererPackageID(rawValue: "org.selfdrivingwiki.json-canvas-readonly")!,
                version: RendererPackageVersion(rawValue: "1.1.6")!,
                path: RendererRelativePath(rawValue: "index.html")!),
            accessibleTitle: "JSON Canvas fence"))
        let entryURL = plan.entryURL
        guard entryURL != URL(string: "about:blank") else { return }

        let script = try #require(RendererDOMEmbedInjection.injectionScript(
            plan: plan, placeholderID: try RendererAttachmentPlaceholderID(validating: "row-1"),
            expansionID: "row-1-expansion"))

        // The reader webview already registered its canonical package scheme
        // handler and router in init; admit the frame route through them.
        // (Registering a second handler for the scheme throws NSException.)
        let router = webView.rendererPackageRouter
        let entryPath = RendererRelativePath(rawValue: "index.html")!
        let entryHTML = "<!doctype html><html><body><p>json-canvas-viewer</p></body></html>"
        _ = router.admit(
            token: frameToken,
            reservation: RendererPackageReservation(
                packageID: RendererPackageID(rawValue: "org.selfdrivingwiki.json-canvas-readonly")!,
                version: RendererPackageVersion(rawValue: "1.1.6")!),
            entryPath: entryPath,
            provider: CanvasStubProvider(html: entryHTML))

        // Run exactly as the coordinator does, then verify the frame loaded
        // through the router under its token origin.
        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    cont.resume(returning: "JS-ERROR: \(error.localizedDescription)")
                } else {
                    cont.resume(returning: "OK: \(String(describing: result))")
                }
            }
        }
        #expect(outcome == "OK: Optional(injected)")

        // Ground truth: the router served the entry document to the frame.
        // Also probe with a same-scheme <img> subresource (M7 proved https
        // parents load custom-scheme images).
        let imgSrc = entryURL.absoluteString
        _ = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(
                "var i = document.createElement('img'); i.src = '\(imgSrc)'; document.body.appendChild(i); 'img-appended'"
            ) { result, _ in
                cont.resume(returning: result as? String ?? "nil")
            }
        }
        let loadDeadline = ContinuousClock.now + .seconds(5)
        while router.diagnosticStartedRequests.isEmpty, ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(router.diagnosticStartedRequests.isEmpty == false,
                "router never served the package frame request; started=\(router.diagnosticStartedRequests)")
        let srcAttribute = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(
                "String(document.getElementById('row-1-expansion-embed')?.src || 'no-frame')"
            ) { result, _ in cont.resume(returning: result as? String ?? "nil") }
        }
        #expect(srcAttribute.hasPrefix("renderer-package://\(plan.frameTokenHost)/"))

        // The parent must NOT be able to read the frame's document — the
        // frame is cross-origin isolated under its token origin (a core
        // security property). Content verification happens through the
        // router ground-truth assertion above.
        let contentProbe = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(
                "(function(){try{return 'parent-read:'+document.getElementById('row-1-expansion-embed').contentDocument.body.textContent;}catch(e){return 'cross-origin-isolated';}})()"
            ) { result, _ in cont.resume(returning: result as? String ?? "nil") }
        }
        #expect(contentProbe == "cross-origin-isolated",
                "frame access state: \(contentProbe)")
    }

}

private extension RendererDOMEmbedPlan {
    /// Test accessor for the package frame's token host.
    var frameTokenHost: String {
        if case .packageFrame(let framePlan) = self { return framePlan.frameToken.rawValue }
        return ""
    }

    /// Test accessor for the package frame's entry URL.
    var entryURL: URL {
        if case .packageFrame(let framePlan) = self { return framePlan.entryURL }
        return URL(string: "about:blank")!
    }
}

/// Serves the canned entry document for the regression test's frame.
private struct CanvasStubProvider: RendererPackageResourceProviding {
    let html: String

    func resource(for url: URL) throws -> RendererPackageResource {
        let request = try RendererPackageScheme.request(from: url)
        guard request.path.rawValue == "index.html" else {
            throw RendererPackageResourceError.undeclaredAsset
        }
        return RendererPackageResource(
            data: Data(html.utf8),
            mimeType: RendererMIMEType(rawValue: "text/html")!,
            isEntryDocument: true)
    }
}
#endif
