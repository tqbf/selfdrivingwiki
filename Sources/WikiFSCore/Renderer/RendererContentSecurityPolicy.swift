import Foundation

// pattern: Functional Core

/// Restrictive package-document policy. This is a package-resource policy, not
/// a navigation delegate and not a claim to intercept general subresources.
public enum RendererContentSecurityPolicy {
    public static let headerName = "Content-Security-Policy"
    public static let packageSource = "\(RendererPackageScheme.name):"
    public static let headerValue = [
        "default-src 'none'",
        "script-src \(packageSource)",
        "style-src \(packageSource)",
        "connect-src 'none'",
        "img-src \(packageSource)",
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
