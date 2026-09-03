import Foundation

// pattern: Functional Core

/// Restrictive package-document policy. This is a package-resource policy, not
/// a navigation delegate and not a claim to intercept general subresources.
///
/// `script-src` admits `'wasm-unsafe-eval'` so a package may compile and run
/// WebAssembly modules without enabling JavaScript `eval`. `connect-src`
/// admits the package scheme so a package may fetch its own declared,
/// hash-pinned assets through the scheme handler; every network origin stays
/// blocked. Workers and frames remain forbidden. `img-src` admits `data:` so
/// a package may mount inert image bytes (SVG image mode never runs script
/// or loads references); the surface is read-only regardless of payload.
public enum RendererContentSecurityPolicy {
    public static let headerName = "Content-Security-Policy"
    public static let packageSource = "\(RendererPackageScheme.name):"
    public static let wasmSource = "'wasm-unsafe-eval'"
    public static let headerValue = [
        "default-src 'none'",
        "script-src \(packageSource) \(wasmSource)",
        "style-src \(packageSource)",
        "connect-src \(packageSource)",
        "img-src \(packageSource) data:",
        "media-src \(packageSource)",
        "font-src \(packageSource)",
        "frame-src 'none'",
        "worker-src 'none'",
        "object-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    public static let noSniffHeaderName = "X-Content-Type-Options"
    public static let noSniffHeaderValue = "nosniff"
}
