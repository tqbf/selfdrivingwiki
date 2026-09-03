#if os(macOS)
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

/// Probe: does a handler-served wiki-reader: parent load same-scheme
/// subresources (iframe and img)? Decides whether package frames can collapse
/// to the single wiki-reader: scheme.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct SameSchemeSubresourceProbeTests {
    private final class ReaderParentHandler: NSObject, WKURLSchemeHandler {
        var started: [URL] = []
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            let url = urlSchemeTask.request.url!
            started.append(url)
            let body = """
            <!doctype html><html><body><p>parent</p></body></html>
            """
            let response = URLResponse(url: url, mimeType: "text/html",
                                       expectedContentLength: body.utf8.count,
                                       textEncodingName: "utf-8")
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data(body.utf8))
            urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }

    private final class PackageHandler: NSObject, WKURLSchemeHandler {
        var started: [URL] = []
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            started.append(urlSchemeTask.request.url!)
            let body = "<!doctype html><html><body><p>frame-loaded</p></body></html>"
            let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
                                       expectedContentLength: body.utf8.count,
                                       textEncodingName: "utf-8")
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data(body.utf8))
            urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }

    @Test("same-scheme iframe and img from handler-served parent")
    func sameSchemeSubresources() async throws {
        let parent = ReaderParentHandler()
        let package = PackageHandler()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(parent, forURLScheme: "wiki-reader")
        configuration.setURLSchemeHandler(package, forURLScheme: RendererPackageScheme.name)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 500, height: 400),
                                configuration: configuration)

        // Handler-served parent navigation (production shape).
        webView.load(URLRequest(url: URL(string: "wiki-reader://reader/document.html")!))
        let loadDeadline = ContinuousClock.now + .seconds(10)
        while webView.isLoading, ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        Issue.record("parent started: \(parent.started.map(\.absoluteString))")

        let frameURL = URL(string: "\(RendererPackageScheme.name)://0123456789abcdef0123456789abcdef/org.example.pkg/1.0.0/index.html")!
        let result = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript("""
            (function(){
              var f = document.createElement('iframe');
              f.id = 'probe-frame';
              f.src = '\(frameURL.absoluteString)';
              document.body.appendChild(f);
              var i = document.createElement('img');
              i.id = 'probe-img';
              i.src = '\(frameURL.absoluteString)';
              document.body.appendChild(i);
              return 'injected';
            })()
            """) { r, e in
                cont.resume(returning: e.map { "JS-ERROR: \($0.localizedDescription)" } ?? (r as? String ?? "nil"))
            }
        }
        Issue.record("injection: \(result)")

        // Give both requests a generous window.
        let deadline = ContinuousClock.now + .seconds(5)
        while package.started.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("package handler started: \(package.started.count) [\(package.started.map { $0.absoluteString })]")
        let frameState = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(
                "(function(){var f=document.getElementById('probe-frame');try{return 'href='+f.contentWindow.location.href;}catch(e){return 'isolated-or-blocked';}})()"
            ) { r, _ in cont.resume(returning: r as? String ?? "nil") }
        }
        Issue.record("frame state: \(frameState)")
    }
}
#endif
