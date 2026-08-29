import Foundation
import WikiFSCore

// pattern: Functional Core

/// Builds the Settings extractor route table: one deterministic row per route
/// from the union of host-owned descriptors, validated package registration
/// snapshots, and saved selections (including unavailable ones). Pure — no
/// registry, catalog, or UI access; every input is a value.
///
/// Row union rules:
///
/// - Host descriptors seed the canonical PDF and HTML routes, so those rows
///   always exist even with no packages installed.
/// - Every available exact registration contributes one row per declared
///   (kind, MIME) pair, so a future registration can add a row without a
///   Settings layout change. Execution adapters for new kinds stay separate
///   work — such rows resolve to no selection.
/// - Saved route records seed their route even when nothing active backs it,
///   keeping a stale package selection visible with its blocked state.
///
/// Deterministic ordering: host descriptor order first (PDF, then HTML), then
/// remaining routes by the typed route order (kind raw value, then MIME raw
/// value). Choices order: host catalog choices first, then package choices by
/// package ID and registration ID.
public enum ExtractorRouteTableBuilder {
    /// All builder inputs as plain values.
    public struct Input: Sendable {
        public let configuration: ExtractionConfig
        /// Active registry entries. These are the only entries that resolution
        /// can execute now.
        public let registrations: [ExtractorRouteRegistrationSnapshot]
        /// Validated catalog entries offered by the picker, including reviewed
        /// overlay packages that have not activated yet.
        public let availableRegistrations: [ExtractorRouteRegistrationSnapshot]
        /// Exact revisions present in the installed-package lifecycle snapshot.
        public let installedRevisionIDs: Set<ExtractorPackageRevisionID>
        /// Exact revisions with a hosted definition waiting for activation.
        public let waitingRevisionIDs: Set<ExtractorPackageRevisionID>

        public init(
            configuration: ExtractionConfig,
            registrations: [ExtractorRouteRegistrationSnapshot],
            availableRegistrations: [ExtractorRouteRegistrationSnapshot]? = nil,
            installedRevisionIDs: Set<ExtractorPackageRevisionID> = [],
            waitingRevisionIDs: Set<ExtractorPackageRevisionID> = []
        ) {
            self.configuration = configuration
            self.registrations = registrations
            self.availableRegistrations = availableRegistrations ?? registrations
            self.installedRevisionIDs = installedRevisionIDs
            self.waitingRevisionIDs = waitingRevisionIDs
        }
    }

    public static func build(_ input: Input) -> [ExtractorRouteSettingsRow] {
        let routes = descriptors(for: input).map(\.route)
        return routes.map { route in
            buildRow(route: route, input: input)
        }
    }

    // MARK: - Route collection

    private static func descriptors(for input: Input) -> [ExtractorRouteDescriptor] {
        var descriptors = ExtractorRouteHostCatalog.descriptors
        let hostedRoutes = Set(descriptors.map(\.route))
        var extra: [ExtractorRouteID] = []
        for snapshot in input.availableRegistrations {
            for kind in snapshot.kinds {
                for mimeType in snapshot.mimeTypes {
                    let route = ExtractorRouteID(kind: kind, mimeType: mimeType)
                    if hostedRoutes.contains(route) == false, extra.contains(route) == false {
                        extra.append(route)
                    }
                }
            }
        }
        for record in input.configuration.routeExtractors
        where hostedRoutes.contains(record.route) == false && extra.contains(record.route) == false {
            extra.append(record.route)
        }
        // Deterministic: typed route order (kind raw value, then MIME raw value).
        descriptors.append(contentsOf: extra.sorted().map(ExtractorRouteHostCatalog.genericDescriptor(for:)))
        return descriptors
    }

    // MARK: - Row construction

    private static func buildRow(
        route: ExtractorRouteID,
        input: Input
    ) -> ExtractorRouteSettingsRow {
        let descriptor = descriptor(for: route, input: input)
        let savedSelection = input.configuration.extractorSelection(for: route)
        let choices = buildChoices(route: route, input: input, savedSelection: savedSelection)
        // Resolver compatibility is route-scoped: only registrations declaring
        // BOTH the route's kind and MIME participate, so a package that is
        // active for the kind but not this MIME cannot resolve (or report
        // Available) on this route.
        let decision = ExtractorSelectionResolver.resolve(
            route,
            configuration: input.configuration,
            activeRegistrations: activeResolverRegistrations(route: route, input: input))
        let status = buildStatus(
            route: route,
            input: input,
            savedSelection: savedSelection,
            decision: decision)
        return ExtractorRouteSettingsRow(
            descriptor: descriptor,
            savedSelection: savedSelection,
            resolvedSelection: decision?.selection,
            choices: choices,
            status: status)
    }

    private static func descriptor(for route: ExtractorRouteID, input: Input) -> ExtractorRouteDescriptor {
        ExtractorRouteHostCatalog.descriptors.first { $0.route == route }
            ?? ExtractorRouteHostCatalog.genericDescriptor(for: route)
    }

    private static func buildChoices(
        route: ExtractorRouteID,
        input: Input,
        savedSelection: ExtractionBackendReference?
    ) -> [ExtractorRouteChoice] {
        let hostChoices = ExtractorRouteHostCatalog.choices(for: route)
        let packages = packageChoices(route: route, input: input)
        // Package choices precede host services and built-ins. HTML's prompt
        // choice stays first.
        var choices = hostChoices
        let insertIndex = choices.lastIndex { $0.category == .prompt }.map { $0 + 1 } ?? 0
        choices.insert(contentsOf: packages, at: insertIndex)
        // A saved installed selection with no active registration stays
        // selectable so the picker keeps showing it as unavailable. Every
        // other saved value is already represented.
        if case .installed(let logical)? = savedSelection,
           choices.contains(where: { $0.reference == .installed(logical) }) == false {
            let staleIndex = choices.lastIndex { $0.category == .reviewedPackage }.map { $0 + 1 } ?? 0
            choices.insert(
                ExtractorRouteChoice(
                    route: route,
                    reference: .installed(logical),
                    displayName: logical.packageID.rawValue,
                    category: .unavailable),
                at: staleIndex)
        }
        return choices
    }

    /// Package choices for one route: registrations whose declared kinds and
    /// MIME types cover the route. Multiple exact versions of one logical
    /// (package, registration) deduplicate into one choice showing the highest
    /// active exact revision; the lifecycle rows below the table keep every
    /// exact version for inspection and removal.
    private static func packageChoices(route: ExtractorRouteID, input: Input) -> [ExtractorRouteChoice] {
        let matching = input.availableRegistrations.filter { snapshot in
            snapshot.kinds.contains(route.kind) && snapshot.mimeTypes.contains(route.mimeType)
        }
        var highestByLogical: [LogicalExtractorReference: ExtractorRouteRegistrationSnapshot] = [:]
        for snapshot in matching {
            let logical = LogicalExtractorReference(
                packageID: snapshot.reference.revision.packageID,
                registrationID: snapshot.reference.registrationID)
            if let current = highestByLogical[logical],
               snapshot.reference.revision <= current.reference.revision {
                continue
            }
            highestByLogical[logical] = snapshot
        }
        return highestByLogical
            .sorted { lhs, rhs in
                let lhsPriority = Self.packageChoicePriority(lhs.value.sourceCategory)
                let rhsPriority = Self.packageChoicePriority(rhs.value.sourceCategory)
                return lhsPriority == rhsPriority ? lhs.key < rhs.key : lhsPriority < rhsPriority
            }
            .map { logical, snapshot in
                ExtractorRouteChoice(
                    route: route,
                    reference: .installed(logical),
                    displayName: snapshot.displayName,
                    category: snapshot.sourceCategory,
                    exactSummary: Self.exactSummary(snapshot.reference.revision))
            }
    }

    private enum PackageChoiceOrder: Comparable {
        case reviewed
        case installed
        case nonPackage
    }

    private static func packageChoicePriority(
        _ category: ExtractorRouteSourceCategory
    ) -> PackageChoiceOrder {
        switch category {
        case .reviewedPackage: .reviewed
        case .installedPackage: .installed
        case .connectedService, .builtIn, .prompt, .unavailable: .nonPackage
        }
    }

    // MARK: - Status

    private static func buildStatus(
        route: ExtractorRouteID,
        input: Input,
        savedSelection: ExtractionBackendReference?,
        decision: ExtractionSelectionDecision?
    ) -> ExtractorRouteStatus {
        guard case .installed(let logical)? = savedSelection else {
            return .ready
        }
        if case .installed? = decision?.selection {
            return .ready
        }
        if input.waitingRevisionIDs.contains(where: { $0.packageID == logical.packageID }) {
            return .waitingForHostActivation
        }
        if input.installedRevisionIDs.contains(where: { $0.packageID == logical.packageID }) {
            return .unavailableSelection
        }
        return .packageNotInstalled
    }

    // MARK: - Resolver inputs

    private static func activeResolverRegistrations(
        route: ExtractorRouteID,
        input: Input
    ) -> [ActiveExtractorRegistration] {
        input.registrations
            .filter { $0.kinds.contains(route.kind) && $0.mimeTypes.contains(route.mimeType) }
            .map { snapshot in
                ActiveExtractorRegistration(
                    reference: snapshot.reference,
                    kinds: snapshot.kinds,
                    protocolRevision: .v1)
            }
    }

    private static func exactSummary(_ revision: ExtractorPackageRevisionID) -> String {
        "\(revision.version.rawValue) · \(revision.digest.hex.prefix(12))"
    }
}
