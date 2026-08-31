import Foundation
import Testing

/// The wrapper contract for the committed D2 package templates
/// (`tools/d2/index.html` + `tools/d2/d2-viewer.js`): no workers, no dynamic
/// code, no storage, no cookies, and package-local fetches only. These are the
/// forbidden patterns the generated package inherits.
@Suite("D2 viewer template contract", .serialized)
struct D2ViewerTemplateTests {
    private let html: String
    private let viewer: String

    init() throws {
        let tools = D2PackageFixtures.toolsDirectory()
        html = try String(contentsOf: tools.appending(path: "index.html"), encoding: .utf8)
        viewer = try String(contentsOf: tools.appending(path: "d2-viewer.js"), encoding: .utf8)
    }

    @Test("templates forbid workers, dynamic code, storage, and cookies")
    func forbiddenPatternsAreAbsent() {
        let forbidden = [
            "Worker",
            "importScripts",
            "XMLHttpRequest",
            "eval(",
            "new Function",
            "localStorage",
            "sessionStorage",
            "indexedDB",
            "document.cookie",
            "WebSocket",
            "EventSource",
            "sendBeacon",
            "import(",
            "caches",
            "window.open",
            "RTCPeerConnection",
            "navigator.storage",
            "document.write",
            "serviceWorker",
        ]
        for pattern in forbidden {
            #expect(!html.contains(pattern), "index.html must not contain \(pattern)")
            #expect(!viewer.contains(pattern), "d2-viewer.js must not contain \(pattern)")
        }
    }

    @Test("templates contain no external URL in any form")
    func externalURLsAreAbsent() {
        let forbidden = ["http://", "https://", "\"//", "'//", "url(//"]
        for pattern in forbidden {
            #expect(!html.contains(pattern), "index.html must not contain \(pattern)")
            #expect(!viewer.contains(pattern), "d2-viewer.js must not contain \(pattern)")
        }
    }

    @Test("index.html loads only package-local scripts and has no inline script")
    func scriptsArePackageLocalAndExternalOnly() {
        #expect(html.contains("<html lang=\"en\">"))
        #expect(html.contains("role=\"status\""))

        // Every script opening tag must carry a package-relative src.
        for match in html.components(separatedBy: "<script").dropFirst() {
            guard let sourceRange = match.range(of: "src=\"") else {
                Issue.record("script tag without src found in index.html")
                continue
            }
            let source = match[sourceRange.upperBound...].prefix(while: { $0 != "\"" })
            #expect(!source.hasPrefix("/"), "script src must be relative, got \(source)")
            for schemePattern in ["http:", "https:", "data:", "blob:"] where source.hasPrefix(schemePattern) {
                Issue.record("script src must be package-local, got \(source)")
            }
        }

        // No script tag may carry an inline body: any text between the opening
        // tag's close and the closing tag is an inline script.
        for range in html.ranges(of: "<script") {
            if let tagEnd = html[range.lowerBound...].firstIndex(of: ">") {
                let afterTag = html.index(after: tagEnd)
                if afterTag < html.endIndex, html[afterTag] != "<" {
                    Issue.record("inline script body found in index.html")
                }
            }
        }
    }

    @Test("the viewer fetches only the pinned module, by literal relative path")
    func fetchesArePackageRelative() {
        // All fetching funnels through fetchLocalBuffer, and its call sites
        // must pass string literals. The total fetch surface is exactly the
        // pinned module.
        #expect(viewer.components(separatedBy: "fetch(").count - 1 == 1, "all fetching must funnel through fetchLocalBuffer")
        let callArguments = Array(viewer.components(separatedBy: "fetchLocalBuffer(\"").dropFirst())
        #expect(callArguments.isEmpty == false, "the viewer must fetch the wasm locally")
        var fetchedPaths: Set<String> = []
        for argument in callArguments {
            let literal = argument.prefix(while: { $0 != "\"" })
            #expect(!literal.hasPrefix("/"), "fetch target must be relative, got \(literal)")
            for schemePattern in ["http:", "https:", "data:", "blob:"] where literal.hasPrefix(schemePattern) {
                Issue.record("fetch target must be package-local, got \(literal)")
            }
            fetchedPaths.insert(String(literal))
        }
        #expect(fetchedPaths == ["d2.wasm"])
    }

    @Test("the viewer reads the authorized source exactly once through input.read")
    func sourceIsReadExactlyOnce() {
        #expect(viewer.components(separatedBy: "input.read").count - 1 == 1)
        #expect(viewer.contains("rendererBridge"))
        #expect(viewer.contains("rendererBridgeResponse"))
    }

    @Test("the mount path is static and accessible")
    func mountPathIsStaticSVG() {
        #expect(viewer.contains("role\", \"img") || viewer.contains("setAttribute(\"role\""))
        #expect(viewer.contains("aria-label"))
        #expect(viewer.contains("darkThemeID"))
        // The watchdog budget is a named constant.
        #expect(viewer.contains("renderBudgetMilliseconds"))
    }
}
