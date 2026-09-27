import Foundation
import WikiFSTypes

/// The acquisition route one source resolves to.
public enum SourceAcquisitionRoute: Sendable, Equatable {
    /// A byteless source whose validated plan URL and MIME an active fetcher
    /// registration claims — resolve the fetch operation.
    case fetch
    /// A source with acquired bytes — resolve by its actual MIME into the
    /// standard format route.
    case format
}

/// The shared pure acquisition-route decision. NO origin-provider branch:
/// whether a fetcher runs is derived only from the source's own data (does
/// it already hold bytes, does it carry a validated plan URL, does its MIME
/// fall inside the active fetcher registrations' claims). The same function
/// serves the app and the daemon providers, so the two hosts can never
/// disagree about what acquires and what converts.
public enum FetchRouteDecision {
    /// - Parameters:
    ///   - hasBytes: whether the source already holds content bytes (an
    ///     empty read means "not yet acquired"; a FAILED read is a typed
    ///     error at the caller, never this decision).
    ///   - planURL: the acquisition plan URL the sync recorded.
    ///   - mimeType: the source's stored MIME (for a byteless fetch source,
    ///     the synthetic source MIME).
    ///   - fetcherClaimedMIMETypes: the synthetic input MIME types the
    ///     currently ACTIVE fetcher registrations claim.
    public static func resolve(
        hasBytes: Bool,
        planURL: String?,
        mimeType: String?,
        fetcherClaimedMIMETypes: Set<String>
    ) -> SourceAcquisitionRoute? {
        // A source with acquired bytes belongs to the standard format route:
        // its actual MIME picks the format extractor. Re-acquiring is never
        // a decision this function makes.
        guard hasBytes == false else { return .format }
        // The plan URL becomes the typed operation input only after host URL
        // validation; invalid data never launches a package.
        guard let planURL,
              ExtractorRemoteSourceURL(rawValue: planURL) != nil else { return nil }
        // Fetch eligibility comes from active registration claims — the
        // fetcher role's claimed input MIME set — never from a provider
        // name, package ID, or URL shape.
        guard let mimeType,
              fetcherClaimedMIMETypes.contains(mimeType.lowercased()) else { return nil }
        return .fetch
    }
}
