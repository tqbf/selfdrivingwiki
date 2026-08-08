import Foundation

// pattern: Functional Core

public enum RendererNavigationDecision: Equatable, Sendable {
    case allowPackageResource
    case cancel
}

/// The package WebView may navigate only within the package origin. The
/// scheme provider remains the authority for whether the path is declared.
public enum RendererNavigationPolicy {
    public static func decision(for url: URL?, entryURL: URL) -> RendererNavigationDecision {
        guard let url,
              url.scheme == RendererPackageScheme.name,
              url.host == entryURL.host,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil
        else { return .cancel }

        do {
            _ = try RendererPackageScheme.request(from: url)
            return .allowPackageResource
        } catch {
            return .cancel
        }
    }
}
