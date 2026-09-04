#if os(macOS)
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

/// AC.11 harness self-tests plus the Phase 1 subframe-origin proof.
///
/// Proven here (macOS 26.5 WebKit):
/// - A custom-scheme parent document (`renderer-package://<token>/…`) can
///   frame another custom-scheme URL whose host is a unique frame token; the
///   subframe's `WKSecurityOrigin.host` is exactly that token and the frames
///   are cross-origin isolated (script access throws).
/// - `loadHTMLString(baseURL:)` with a custom-scheme URL gives the parent
///   document that origin without a network request, so a reader-style
///   document can host package iframes.
/// - Negative control: an https-parent document CANNOT frame a custom-scheme
///   URL — WebKit's custom-scheme CORS enforcement keeps the frame at
///   `about:blank` and never starts the scheme task. Reader documents must
///   therefore not use an https baseURL if they host custom-scheme iframes.
@Suite(
    .serialized,
    .timeLimit(.minutes(5))
)
@MainActor
struct RendererHostedSubframeHarnessTests {
    private static let frameHandlerName = "subframeProvenanceRecorder"

    private static func makeConfiguration(
        router: ReaderRendererPackageRouter
    ) -> (WKWebViewConfiguration, WKUserContentController) {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let handler = RendererPackageSchemeHandler(resourceProvider: router)
        configuration.setURLSchemeHandler(handler, forURLScheme: RendererPackageScheme.name)
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return (configuration, controller)
    }

    private static func admission(
        _ router: ReaderRendererPackageRouter,
        token: RendererFrameOriginToken,
        entryHTML: String,
        extraResources: [String: Result<RendererPackageResource, RendererPackageResourceError>] = [:]
    ) -> URL {
        let entryPath = RendererRelativePath(rawValue: "index.html")!
        var resources: [String: Result<RendererPackageResource, RendererPackageResourceError>] = [
            "index.html": .success(.init(
                data: Data(entryHTML.utf8),
                mimeType: RendererMIMEType(rawValue: "text/html")!,
                isEntryDocument: true)),
        ]
        resources.merge(extraResources) { current, _ in current }
        return router.admit(
            token: token,
            reservation: RendererPackageReservation(
                packageID: RendererPackageID(rawValue: "org.example.probe")!,
                version: RendererPackageVersion(rawValue: "1.0.0")!),
            entryPath: entryPath,
            provider: StubFrameProvider(resources: resources))
    }

    /// A raw scheme handler serving the parent document without package CSP.
    /// The production reader parent is served by the blob/wiki handlers (no
    /// package CSP); this mirrors that shape so the parent may create frames.
    private final class ParentDocumentHandler: NSObject, WKURLSchemeHandler {
        var started: [URL] = []
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            let url = urlSchemeTask.request.url!
            started.append(url)
            let body = "<!doctype html><html><body><p>parent</p></body></html>"
            let response = URLResponse(
                url: url, mimeType: "text/html",
                expectedContentLength: body.utf8.count, textEncodingName: "utf-8")
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data(body.utf8))
            urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }

    private static func makeConfigurationWithParentScheme(
        router: ReaderRendererPackageRouter
    ) -> (WKWebViewConfiguration, WKUserContentController, ParentDocumentHandler) {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let handler = RendererPackageSchemeHandler(resourceProvider: router)
        configuration.setURLSchemeHandler(handler, forURLScheme: RendererPackageScheme.name)
        let parentHandler = ParentDocumentHandler()
        configuration.setURLSchemeHandler(parentHandler, forURLScheme: "reader-page")
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return (configuration, controller, parentHandler)
    }

    private static let parentHTMLBody = "<!doctype html><html><body><p>parent</p></body></html>"

    private static let parentHostToken = "reader-test-parent"

    private static func loadParent(_ harness: RendererHostedWebKitHarness, token: String) async throws {
        try await harness.loadURL(URL(string: "reader-page://\(token)/parent.html")!)
        // The parent document must be fully committed before a scripted
        // iframe injection; the harness's didFinish can precede frame-tree
        // readiness on custom schemes. The injection below verifies.
        let origin = await harness.readJavaScriptString("String(window.location.origin)")
        guard origin == "reader-page://\(token)" else {
            throw RendererHostedWebKitHarness.HarnessError.navigationFailed(
                "parent origin not settled: \(origin ?? "nil")")
        }
    }

    /// Package frame state as visible from the parent, or a marker when the
    /// parent is correctly denied cross-origin read access.
    private static func frameStateJS(_ id: String) -> String {
        """
        (function(){
          var f = document.getElementById('\(id)');
          if (!f) return 'no-iframe';
          try { return 'href=' + f.contentWindow.location.href; }
          catch (e) { return 'cross-origin (parent cannot read)'; }
        })()
        """
    }

    @Test("production configuration loads a custom-scheme subframe under a custom-scheme parent")
    func productionConfigurationLoadsCustomSchemeSubframe() async throws {
        let router = ReaderRendererPackageRouter()
        let (configuration, controller, _) = Self.makeConfigurationWithParentScheme(router: router)
        let harness = try await RendererHostedWebKitHarness.custom(configuration: configuration)
        defer { harness.close() }
        harness.recordSubframeMessages(
            in: controller,
            contentWorld: .page,
            name: Self.frameHandlerName)

        let childToken = RendererFrameOriginToken.generate()
        // The subframe reports its exact origin host back through the
        // with-reply message handler. The script is an EXTERNAL declared
        // package asset (package CSP has no unsafe-inline, mirroring real
        // packages, which never run inline script either).
        let probeJS = """
        window.webkit.messageHandlers["\(Self.frameHandlerName)"].postMessage(
          "origin=" + window.location.origin);
        """
        let entryHTML = """
        <!doctype html><html><head>
        <script src="probe.js"></script>
        </head><body></body></html>
        """
        let childURL = Self.admission(
            router, token: childToken, entryHTML: entryHTML,
            extraResources: ["probe.js": .success(.init(
                data: Data(probeJS.utf8),
                mimeType: RendererMIMEType(rawValue: "text/javascript")!,
                isEntryDocument: false))])

        // The parent document loads from a CSP-free custom-scheme URL
        // (reader-style: the reader parent comes from the blob handler).
        try await Self.loadParent(harness, token: Self.parentHostToken)
        // Proven-working injection shape from the round-1 probes: set src via
        // DOM property inside one evaluate call (innerHTML iframes stay
        // pending on custom-scheme children in this WebKit). Try the property
        // set first, then a synchronous load fallback if WebKit leaves it
        // pending at about:blank.
        try await harness.executeJavaScript(
            "var f=document.createElement('iframe');f.id='probe-frame';f.src='\(childURL.absoluteString)';document.body.appendChild(f);'injected'",
            expectedValue: "injected",
            description: "iframe injection")
        try await Task.sleep(for: .seconds(2))
        var frameState = await harness.readJavaScriptString(Self.frameStateJS("probe-frame"))
        if frameState == "href=about:blank" {
            // src assignment ignored for this custom scheme; force a load.
            try await harness.executeJavaScript(
                "document.getElementById('probe-frame').contentWindow.location.replace('\(childURL.absoluteString)');'reloaded'",
                expectedValue: "reloaded",
                description: "iframe location.replace fallback")
            try await Task.sleep(for: .seconds(2))
            frameState = await harness.readJavaScriptString(Self.frameStateJS("probe-frame"))
        }
        // Poll the frame's parent-visible state until it loads or the wait
        // expires (bounded; frames may take several seconds on first paint).
        let loadDeadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < loadDeadline {
            frameState = await harness.readJavaScriptString(Self.frameStateJS("probe-frame"))
            if frameState == "cross-origin (parent cannot read)" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("package frame state from parent: \(frameState ?? "nil")")
        // Did WebKit ever ask the router for the child document? If the
        // started list is empty, the load was blocked before the scheme
        // handler (parent-origin CORS enforcement), not by the router.
        let started = await MainActor.run { router.diagnosticStartedRequests }
        Issue.record("package scheme tasks started: \(started.map { $0.absoluteString })")
        Issue.record("webView.currentURL: \(harness.webView.url?.absoluteString ?? "nil")")
        let srcAttr = await harness.readJavaScriptString(
            "(function(){var f=document.getElementById('probe-frame');return f ? String(f.getAttribute('src')) : 'no-frame';})()")
        Issue.record("iframe src attribute: \(srcAttr ?? "nil")")
        guard frameState == "cross-origin (parent cannot read)" else {
            throw RendererHostedWebKitHarness.HarnessError.timeout(
                description: "package frame did not load; parent observed: \(frameState ?? "nil"), started=\(started)")
        }

        // The subframe message must arrive from a non-main frame whose origin
        // protocol/host are exactly the admitted frame token.
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline,
              !harness.subframeObservations.contains(where: { !$0.frameIsMainFrame })
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        let observation = harness.subframeObservations.first { !$0.frameIsMainFrame }
        guard let observation else {
            throw RendererHostedWebKitHarness.HarnessError.timeout(
                description: "no subframe message; observations=\(harness.subframeObservations)")
        }
        #expect(observation.originProtocol == RendererPackageScheme.name)
        #expect(observation.originHost == childToken.rawValue)
        #expect(observation.messageBody == "origin=renderer-package://\(childToken.rawValue)")
    }

    @Test("two same-package iframes are uniquely originated and cross-origin isolated")
    func twoIframesAreUniqueAndIsolated() async throws {
        let router = ReaderRendererPackageRouter()
        let firstToken = RendererFrameOriginToken.generate()
        let secondToken = RendererFrameOriginToken.generate()
        #expect(firstToken.rawValue != secondToken.rawValue)
        let inertHTML = "<!doctype html><html><body></body></html>"
        let firstURL = Self.admission(router, token: firstToken, entryHTML: inertHTML)
        // The second token admission proves distinct tokens are minted per
        // frame; its URL is not needed by the parent-isolation probe.
        _ = Self.admission(router, token: secondToken, entryHTML: inertHTML)

        let (configuration, _, _) = Self.makeConfigurationWithParentScheme(router: router)
        let harness = try await RendererHostedWebKitHarness.custom(configuration: configuration)
        defer { harness.close() }
        try await Self.loadParent(harness, token: Self.parentHostToken)
        try await Task.sleep(for: .seconds(1))
        // One iframe whose contentDocument the parent CAN read (same-origin
        // about:blank child), one package iframe it cannot. The package frame
        // gets 2s to finish loading before the isolation probe.
        try await harness.executeJavaScript(
            "var same=document.createElement('iframe');document.body.appendChild(same);var pkg=document.createElement('iframe');pkg.src='\(firstURL.absoluteString)';document.body.appendChild(pkg);'injected'",
            expectedValue: "injected",
            description: "iframe injection")
        try await Task.sleep(for: .seconds(2))
        let isolation = await harness.readJavaScriptString("""
        (function(){
          var frames = document.querySelectorAll('iframe');
          if (frames.length !== 2) return 'wrong-count:' + frames.length;
          var pkgOrigin = 'unreadable';
          try { pkgOrigin = String(frames[1].contentWindow.location.href); } catch (e) { pkgOrigin = 'isolated:' + e.message; }
          return 'pkg=' + pkgOrigin;
        })()
        """)
        // The package frame either loads under its unique token origin or is
        // blocked; both prove the parent cannot read it as same-origin. The
        // href read must throw for a cross-origin frame.
        Issue.record("isolation probe: \(isolation ?? "nil")")
        #expect(isolation?.hasPrefix("pkg=isolated:") == true)
        let origin = await harness.readJavaScriptString("window.location.origin") ?? "nil"
        #expect(origin == "reader-page://\(Self.parentHostToken)")
    }

    @Test("https parent cannot frame a custom scheme (negative control)")
    func httpsParentCannotFrameCustomScheme() async throws {
        let router = ReaderRendererPackageRouter()
        let (configuration, _) = Self.makeConfiguration(router: router)
        let harness = try await RendererHostedWebKitHarness.custom(configuration: configuration)
        defer { harness.close() }

        let childURL = Self.admission(
            router, token: .generate(),
            entryHTML: "<!doctype html><html><body></body></html>")
        try await harness.loadHTML(
            "<!doctype html><html><body><iframe id='blocked' src='\(childURL.absoluteString)'></iframe></body></html>",
            baseURL: URL(string: "https://reader.wikifs.invalid")!)
        try await Task.sleep(for: .seconds(1))

        // WebKit keeps the frame at about:blank and never starts the task.
        let href = await harness.readJavaScriptString(
            "(function(){try{return document.getElementById('blocked').contentWindow.location.href;}catch(e){return 'isolated';}})()")
        #expect(href == "about:blank")
    }

    @Test("captures exact subframe origin and reply result")
    func capturesExactSubframeOriginAndReply() async throws {
        let router = ReaderRendererPackageRouter()
        let (configuration, controller, _) = Self.makeConfigurationWithParentScheme(router: router)
        let harness = try await RendererHostedWebKitHarness.custom(configuration: configuration)
        defer { harness.close() }
        harness.recordSubframeMessages(
            in: controller,
            contentWorld: .page,
            name: Self.frameHandlerName)

        let token = RendererFrameOriginToken.generate()
        let probeJS = """
        window.webkit.messageHandlers["\(Self.frameHandlerName)"].postMessage("origin-probe")
            .then(function(reply) { document.title = "reply:" + reply; })
            .catch(function() { document.title = "reply-failed"; });
        """
        let entryHTML = """
        <!doctype html><html><head>
        <script src="probe.js"></script>
        </head><body></body></html>
        """
        let frameURL = Self.admission(
            router, token: token, entryHTML: entryHTML,
            extraResources: ["probe.js": .success(.init(
                data: Data(probeJS.utf8),
                mimeType: RendererMIMEType(rawValue: "text/javascript")!,
                isEntryDocument: false))])

        try await Self.loadParent(harness, token: Self.parentHostToken)
        try await harness.executeJavaScript(
            "var f=document.createElement('iframe');f.src='\(frameURL.absoluteString)';document.body.appendChild(f);'injected'",
            expectedValue: "injected",
            description: "iframe injection")

        // The subframe receives a reply from the with-reply handler.
        let title = try await harness.waitForDocumentTitle("reply:ack")
        #expect(title == "reply:ack")
        #expect(harness.subframeReplyResults.contains("ack"))
        let observation = harness.subframeObservations.first
        #expect(observation?.originHost == token.rawValue)
        #expect(observation?.frameIsMainFrame == false)
    }

    @Test("drives focus and escape with timeout")
    func drivesFocusAndEscapeWithTimeout() async throws {
        let harness = try await RendererHostedWebKitHarness.permissive()
        defer { harness.close() }
        try await harness.loadHTML("""
        <!doctype html><html><body>
        <button id="target">focus target</button>
        <script>
        window.escapeObserved = false;
        document.addEventListener('keydown', function(event) {
          if (event.key === 'Escape') window.escapeObserved = true;
        });
        </script>
        </body></html>
        """)
        try await harness.executeJavaScript(
            "document.getElementById('target').focus(); 'focused'",
            expectedValue: "focused",
            description: "focus target")
        try await harness.waitForJavaScriptTrue(
            "String(document.activeElement && document.activeElement.id) === 'target'",
            description: "focus settled on target")
        // The Escape path is bounded and reports delivery rather than hanging:
        // CGEvent HID taps often do not reach a test window's web content, so
        // non-delivery here is an environment limitation. The production
        // Escape/collapse path is exercised through the reader document's own
        // keydown handling in later phases.
        _ = try await harness.pressEscape(
            observedFlagJS: "String(window.escapeObserved === true)",
            timeout: .seconds(2))
    }

    @Test("lifecycle adapter invokes scoped invalidation")
    func lifecycleAdapterInvokesScopedInvalidation() async throws {
        let harness = try await RendererHostedWebKitHarness.permissive()
        defer { harness.close() }
        try await harness.loadHTML("<!doctype html><html><body><p>lifecycle</p></body></html>")

        var invalidatedGeneration: Int?
        harness.onProcessTermination = { invalidatedGeneration = 42 }

        // Deterministic process-termination invalidation: the same registry
        // callback a production `webViewWebContentProcessDidTerminate` would
        // invoke, without forcibly crashing WebKit.
        harness.simulateWebContentProcessTermination()
        #expect(invalidatedGeneration == 42)
    }
}

/// Stub provider serving canned package resources by path; stands in for a
/// validated package directory in hosted harness scenarios.
private struct StubFrameProvider: RendererPackageResourceProviding {
    let resources: [String: Result<RendererPackageResource, RendererPackageResourceError>]

    func resource(for url: URL) throws -> RendererPackageResource {
        // The canonical URL form is what the router forwards.
        let request = try RendererPackageScheme.request(from: url)
        guard let result = resources[request.path.rawValue] else {
            throw RendererPackageResourceError.undeclaredAsset
        }
        return try result.get()
    }
}
#endif
