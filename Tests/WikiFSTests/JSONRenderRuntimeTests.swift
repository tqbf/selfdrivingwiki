import Testing
import Foundation
@testable import WikiFS

/// AC.1 — The built `.app` bundle contains a loadable `jsonrender-form.js`
/// resource, AND the SwiftPM package declares it so tests can find it.
///
/// Under `swift test`, the JS is resolved via `Bundle.module` (SwiftPM
/// resource access). Under the built `.app`, `Bundle.main` hits (build.sh
/// copies it). The runtime code uses `Bundle.main` first; the test verifies
/// the `Bundle.module` path (since `swift test` has no `Bundle.main`).
@Suite struct JSONRenderRuntimeTests {

    @Test func test_runtime_resources_bundled() {
        // The form renderer JS must resolve — unlike Mermaid (which degrades
        // gracefully), the form renderer IS the feature and has no fallback.
        let js = JSONRenderWebView.formRendererJS
        #expect(js != nil, "jsonrender-form.js not found in Bundle.main or Bundle.module")
        #expect(js?.isEmpty == false, "jsonrender-form.js resolved but is empty")

        // Verify the JS contains the expected public API.
        #expect(js?.contains("window.WikiJSONRender") == true, "missing WikiJSONRender global")
        #expect(js?.contains("applyBase64") == true, "missing applyBase64 method")
        #expect(js?.contains("getState") == true, "missing getState method")
    }
}
