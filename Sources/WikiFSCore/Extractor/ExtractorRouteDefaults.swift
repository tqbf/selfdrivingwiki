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
    /// Host-owned routes whose bundled policy selects import-time conversion:
    /// when an active package registration claims the kind, sources of that
    /// kind convert at ingest instead of waiting for a manual Extract tap.
    /// Package-only kinds (DOCX) convert on import WITHOUT appearing here —
    /// their rule is "claim + no host backend". This table exists for
    /// host-backend kinds where import conversion is a deliberate product
    /// decision (HTML converts at ingest via the reviewed Defuddle package,
    /// issue #1380) that must stay bundled data rather than a kind branch.
    /// Execution still requires the registration claim and resolves through
    /// the route's installed-package selection; a removed package drops the
    /// claim and the source lands verbatim. A missing key decodes to an empty
    /// table (bundled data predating #1380).
    public let routeAutoExtraction: [RouteAutoExtractionRecord]

    public init(
        routeExtractors: [ExtractorRouteSelectionRecord],
        routeFetchers: [FetcherRouteSelectionRecord] = [],
        routeAutoExtraction: [RouteAutoExtractionRecord] = []
    ) {
        self.routeExtractors = routeExtractors.normalizedForPersistence().records
        self.routeFetchers = routeFetchers.normalizedForPersistence().records
        self.routeAutoExtraction = routeAutoExtraction
    }

    private enum CodingKeys: String, CodingKey {
        case routeExtractors, routeFetchers, routeAutoExtraction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            routeExtractors: try container.decodeIfPresent(
                [ExtractorRouteSelectionRecord].self, forKey: .routeExtractors) ?? [],
            routeFetchers: try container.decodeIfPresent(
                [FetcherRouteSelectionRecord].self, forKey: .routeFetchers) ?? [],
            routeAutoExtraction: try container.decodeIfPresent(
                [RouteAutoExtractionRecord].self, forKey: .routeAutoExtraction) ?? [])
    }

    /// The kinds whose bundled policy selects import-time conversion. The
    /// session wiring intersects this with the active registrations' claimed
    /// kinds, so an entry without a live claiming package is inert.
    public var autoExtractKinds: Set<ExtractorKind> {
        Set(routeAutoExtraction.map(\.route.kind))
    }

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

/// One route the bundled policy selects for import-time conversion. Only the
/// route identity is declared here; execution is still gated on an active
/// package registration claiming the kind and on the route's selection
/// resolving to an installed package (built-in execution floors never
/// convert at import).
public struct RouteAutoExtractionRecord: Decodable, Hashable, Sendable {
    public let route: ExtractorRouteID

    public init(route: ExtractorRouteID) {
        self.route = route
    }
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
    /// bundled policy does not cover return `nil` — no default.
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
