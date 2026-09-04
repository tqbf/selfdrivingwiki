#if os(macOS)
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

private enum ProbeVariant: String, CaseIterable {
    case plainURLResponse
    case httpURLResponseNoHeaders
    case httpURLResponseWithCSP
    // Production reader combination: https loadHTMLString parent, child
    // served WITH package CSP through the canonical handler.
    case httpsParentCSPChild
}

private final class VariantHandler: NSObject, WKURLSchemeHandler {
    var started: [URL] = []
    private let variant: ProbeVariant
    init(variant: ProbeVariant) { self.variant = variant }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        started.append(url)
        let body = "<!doctype html><html><body><p>inner-loaded</p></body></html>"
        let response: URLResponse
        switch variant {
        case .plainURLResponse:
            response = URLResponse(url: url, mimeType: "text/html", expectedContentLength: body.utf8.count, textEncodingName: "utf-8")
        case .httpURLResponseNoHeaders:
            response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
        case .httpURLResponseWithCSP:
            response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "text/html",
                "Content-Security-Policy": RendererContentSecurityPolicy.headerValue,
                "X-Content-Type-Options": "nosniff",
            ])!
        case .httpsParentCSPChild:
            response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "text/html",
                "Content-Security-Policy": RendererContentSecurityPolicy.headerValue,
                "X-Content-Type-Options": "nosniff",
            ])!
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data(body.utf8))
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Probe round 3: isolate the blocking variable. Round-1 raw handler worked;
/// the canonical handler fails. Difference: response type (URLResponse vs
/// HTTPURLResponse), status code, and headers. Matrix of response shapes.
@Suite(.serialized, .timeLimit(.minutes(4)))
@MainActor
struct RendererSubframeMatrix3ProbeTests {
    @Test("round 3 response-shape matrix")
    func round3() async throws {
        for variant in ProbeVariant.allCases where variant != .httpsParentCSPChild {
            let handler = VariantHandler(variant: variant)
            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(handler, forURLScheme: RendererPackageScheme.name)
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            let harness = try await RendererHostedWebKitHarness.custom(configuration: configuration)

            let parentURL = URL(string: "\(RendererPackageScheme.name)://parent-host/pkg/1.0.0/index.html")!
            let childURL = URL(string: "\(RendererPackageScheme.name)://child-host/pkg/1.0.0/index.html")!
            try await harness.loadURL(parentURL)
            try await harness.executeJavaScript(
                "var f=document.createElement('iframe');f.id='probe';f.src='\(childURL.absoluteString)';document.body.appendChild(f);'ok'",
                expectedValue: "ok", description: "inject \(variant)")
            try await Task.sleep(for: .seconds(2))
            let state = await harness.readJavaScriptString(
                "(function(){var f=document.getElementById('probe');try{return 'href='+f.contentWindow.location.href;}catch(e){return 'isolated';}})()")
            Issue.record("variant=\(variant): frame=\(state ?? "nil") started=\(handler.started.count)")
            harness.close()
        }
    }

    @Test("production combination: https parent frames CSP child")
    func httpsParentFramesCSPChild() async throws {
        let router = ReaderRendererPackageRouter()
        let token = RendererFrameOriginToken.generate()
        let childURL = admit(router, token: token)
        let configuration = WKWebViewConfiguration()
        let handler = RendererPackageSchemeHandler(resourceProvider: router)
        configuration.setURLSchemeHandler(handler, forURLScheme: RendererPackageScheme.name)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let harness = try await RendererHostedWebKitHarness.custom(configuration: configuration)
        defer { harness.close() }

        // EXACT production reader setup: loadHTMLString with https baseURL.
        try await harness.loadHTML(
            "<!doctype html><html><body><iframe id='probe' src='\(childURL.absoluteString)'></iframe></body></html>",
            baseURL: URL(string: "https://reader.wikifs.invalid")!)
        try await Task.sleep(for: .seconds(2))
        let state = await harness.readJavaScriptString(
            "(function(){var f=document.getElementById('probe');try{return 'href='+f.contentWindow.location.href;}catch(e){return 'isolated';}})()")
        let started = router.diagnosticStartedRequests
        Issue.record("httpsParentCSPChild: frame=\(state ?? "nil") started=\(started.count)")
    }

    private func admit(_ router: ReaderRendererPackageRouter, token: RendererFrameOriginToken) -> URL {
        let entryPath = RendererRelativePath(rawValue: "index.html")!
        return router.admit(
            token: token,
            reservation: RendererPackageReservation(
                packageID: RendererPackageID(rawValue: "org.example.probe")!,
                version: RendererPackageVersion(rawValue: "1.0.0")!),
            entryPath: entryPath,
            provider: CSPStubProvider())
    }
}

private struct CSPStubProvider: RendererPackageResourceProviding {
    func resource(for url: URL) throws -> RendererPackageResource {
        RendererPackageResource(
            data: Data("<!doctype html><html><body><p>inner-loaded</p></body></html>".utf8),
            mimeType: RendererMIMEType(rawValue: "text/html")!,
            isEntryDocument: true)
    }
}
#endif
