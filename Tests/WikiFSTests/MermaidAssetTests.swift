import Testing
@testable import WikiFS

/// Smoke tests for `MermaidAsset`. The bundled resource is not present under
/// `swift test` (no `.app` bundle), so only the empty-string fallback path is
/// exercised here. The real bundled-load assertion is a manual gate after `make`.
struct MermaidAssetTests {

    @Test func jsFallsBackToEmptyOutsideBundle() {
        // Under `swift test` there is no `.app`, so `Bundle.main` lacks the
        // resource and the loader must fall back to "" (not crash, not a stub).
        // Asserting the exact empty string also pins the fallback contract:
        // callers treat "" as "runtime unavailable → skip injection".
        #expect(MermaidAsset.js == "")
    }
}
