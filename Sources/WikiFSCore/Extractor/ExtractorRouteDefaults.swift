import Foundation

/// Host-owned default extractor selections loaded from bundled data.
/// Package registrations declare capability. This policy selects defaults when
/// the user has not configured a route.
public struct ExtractorRouteDefaults: Decodable, Sendable {
    public let routeExtractors: [ExtractorRouteSelectionRecord]
    /// Host-owned default fetcher selections. Keys are `FetcherRouteID`s —
    /// distinct from any extractor route — so a default fetcher can never be
    /// read as an extractor choice or the reverse. A missing key decodes to
    /// an empty table (older bundled data).
    public let routeFetchers: [FetcherRouteSelectionRecord]

    public init(
        routeExtractors: [ExtractorRouteSelectionRecord],
        routeFetchers: [FetcherRouteSelectionRecord] = []
    ) {
        self.routeExtractors = routeExtractors.normalizedForPersistence().records
        self.routeFetchers = routeFetchers.normalizedForPersistence().records
    }

    private enum CodingKeys: String, CodingKey { case routeExtractors, routeFetchers }

    /// The bundled fetcher default record for one route, if any.
    public func fetcherDefault(for route: FetcherRouteID) -> ExtractionBackendReference? {
        routeFetchers.first(where: { $0.route == route })?.fetcher
    }

    /// Defaults shipped with this build. A missing or invalid resource is a
    /// packaging error because fresh-install extraction depends on this policy.
    /// The resource ships via Package.swift's `.copy("Resources/Extraction")`,
    /// so only the module bundle is consulted.
    public static let bundled: ExtractorRouteDefaults = {
        let url = Bundle.module.url(
            forResource: "default-routes",
            withExtension: "json",
            subdirectory: "Extraction")
        guard let url else {
            preconditionFailure("Missing bundled extractor default-route policy")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ExtractorRouteDefaults.self, from: data)
        } catch {
            preconditionFailure("Invalid bundled extractor default-route policy: \(error)")
        }
    }()
}

public extension ExtractionConfig {
    /// Applies host defaults only to routes without a user or migrated legacy
    /// selection. The returned config contains one generic effective table.
    func applying(defaults: ExtractorRouteDefaults) -> ExtractionConfig {
        var result = self
        for record in defaults.routeExtractors
        where result.extractorSelection(for: record.route) == nil {
            result.setExtractorSelection(record.extractor, for: record.route)
        }
        for record in defaults.routeFetchers
        where result.fetcherSelection(for: record.route) == nil {
            result.setFetcherSelection(record.fetcher, for: record.route)
        }
        return result
    }

    /// The route's effective selection: the stored record when present,
    /// otherwise the bundled default-route record for that route. Routes the
    /// bundled policy does not cover (HTML today) return `nil` — no default.
    /// Execution and resolution consult this, never the retired typed fields.
    func selectionOrDefault(for route: ExtractorRouteID) -> ExtractionBackendReference? {
        extractorSelection(for: route)
            ?? ExtractorRouteDefaults.bundled.routeExtractors.first { $0.route == route }?.extractor
    }

    /// The fetcher route's effective selection: the stored record when
    /// present, otherwise the bundled default fetcher record for that route.
    /// Used by `prepareFetcher`, never the extractor tables.
    func fetcherSelectionOrDefault(for route: FetcherRouteID) -> ExtractionBackendReference? {
        fetcherSelection(for: route)
            ?? ExtractorRouteDefaults.bundled.fetcherDefault(for: route)
    }

    /// Presentation mapping for the HTML route: the effective selection as the
    /// legacy backend label the store's Extract path still carries, or `nil`
    /// when the selection names no known HTML adapter (the execution floor is
    /// the tag-based adapter). Session wiring feeds this to the store; the
    /// retired `htmlBackend` config key is never read again.
    var htmlSelectionLabel: HtmlExtractionBackend? {
        guard let selection = selectionOrDefault(for: .canonicalHTML) else { return nil }
        switch selection {
        case .none:
            return nil
        case .host(let host):
            switch host.adapterID.rawValue {
            case HtmlExtractionBackend.defuddle.rawValue: return .defuddle
            case HtmlExtractionBackend.tagBased.rawValue: return .tagBased
            default: return nil
            }
        case .installed(let logical):
            // The reviewed Defuddle lineage presents as the defuddle backend.
            // The identity literals mirror the engine's legacy host remap.
            return logical.packageID.rawValue == "org.selfdrivingwiki.defuddle"
                && logical.registrationID.rawValue == "article" ? .defuddle : nil
        }
    }
}
