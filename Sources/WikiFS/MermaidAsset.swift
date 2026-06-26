import Foundation

/// Vendored mermaid v11 runtime (UMD build), read once from the app bundle and
/// cached. Callers inject `MermaidAsset.js` as an inline `<script>` into
/// WKWebView pages that contain ` ```mermaid ` diagram blocks.
///
/// The empty-string fallback is intentional: under `swift test` the process runs
/// outside a packaged `.app`, so `Bundle.main` won't contain the resource.
/// Callers treat an empty string as "runtime not available" and simply skip
/// injection — no crash, no forced unwrap.
///
/// The file (`Resources/mermaid.min.js`) is copied into
/// `Contents/Resources/mermaid.min.js` by `build.sh`. See
/// `Resources/mermaid.min.js.README` for version and provenance.
enum MermaidAsset {
    /// The contents of `mermaid.min.js`, or `""` if the resource is absent or
    /// unreadable (e.g. when running under `swift test`).
    static let js: String = {
        guard
            let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return contents
    }()
}
