import Testing
@testable import WikiFS

/// Smoke tests for `MermaidAsset`. The bundled resource is not present under
/// `swift test` (no `.app` bundle), so only the empty-string fallback path is
/// exercised here. The real bundled-load assertion is a manual gate after `make`.
struct MermaidAssetTests {

    @Test func jsIsStringAndDoesNotCrash() {
        // Outside the app bundle the resource is absent; the fallback returns "".
        // Regardless, accessing MermaidAsset.js must never crash or force-unwrap.
        let js = MermaidAsset.js
        // count >= 0 is always true for String — this just proves no crash / trap.
        #expect(js.count >= 0)
    }
}
