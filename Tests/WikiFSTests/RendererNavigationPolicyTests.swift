import Foundation
import Testing
@testable import WikiFSCore

struct RendererNavigationPolicyTests {
    private let entryURL = URL(string: "renderer-package://package/org.example.session/1.0.0/index.html")!

    @Test("package entry and same-package resources are allowed")
    func allowsPackageResources() {
        #expect(RendererNavigationPolicy.decision(for: entryURL, entryURL: entryURL) == .allowPackageResource)
        let resource = URL(string: "renderer-package://package/org.example.session/1.0.0/assets/app.js")
        #expect(RendererNavigationPolicy.decision(for: resource, entryURL: entryURL) == .allowPackageResource)
    }

    @Test("external, malformed, and decorated URLs are cancelled")
    func cancelsOutsidePackageBoundary() {
        let urls = [
            URL(string: "https://example.invalid/collect"),
            URL(string: "renderer-package://other/org.example.session/1.0.0/index.html"),
            URL(string: "renderer-package://package/org.example.session/1.0.0/index.html?redirect=https://example.invalid"),
            URL(string: "renderer-package://package/org.example.session/1.0.0/../escape.html"),
            nil,
        ]
        for url in urls {
            #expect(RendererNavigationPolicy.decision(for: url, entryURL: entryURL) == .cancel)
        }
    }
}
