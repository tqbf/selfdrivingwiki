import Foundation

/// Host-owned default extractor selections loaded from bundled data.
/// Package registrations declare capability. This policy selects defaults when
/// the user has not configured a route.
public struct ExtractorRouteDefaults: Decodable, Sendable {
    public let routeExtractors: [ExtractorRouteSelectionRecord]

    public init(routeExtractors: [ExtractorRouteSelectionRecord]) {
        self.routeExtractors = routeExtractors.normalizedForPersistence().records
    }

    /// Defaults shipped with this build. A missing or invalid resource is a
    /// packaging error because fresh-install extraction depends on this policy.
    public static let bundled: ExtractorRouteDefaults = {
        let url = Bundle.main.url(
            forResource: "default-routes",
            withExtension: "json",
            subdirectory: "Extraction")
            ?? Bundle.module.url(
                forResource: "default-routes",
                withExtension: "json",
                subdirectory: "Extraction")
            ?? Bundle.module.url(
                forResource: "default-routes",
                withExtension: "json")
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
}
