import Foundation
import WikiFSCore

// pattern: Functional Core

/// Builds the Settings extractor route table: one deterministic row per route
/// from the union of host-owned descriptors, active package registration
/// snapshots, and saved selections (including unavailable ones). Pure — no
/// registry, catalog, or UI access; every input is a value.
///
/// Row union rules:
///
/// - Host descriptors seed the canonical PDF and HTML routes, so those rows
///   always exist even with no packages installed.
/// - Every active exact registration contributes one row per declared
///   (kind, MIME) pair, so a future registration can add a row without a
///   Settings layout change. Execution adapters for new kinds stay separate
///   work — such rows resolve to no selection.
/// - Saved route records seed their route even when nothing active backs it,
///   keeping a stale package selection visible with its fallback state.
///
/// Deterministic ordering: host descriptor order first (PDF, then HTML), then
/// remaining routes by the typed route order (kind raw value, then MIME raw
/// value). Choices order: host catalog choices first, then package choices by
/// package ID and registration ID.
public enum ExtractorRouteTableBuilder {
    /// All builder inputs as plain values.
    public struct Input: Sendable {
        public let configuration: ExtractionConfig
        public let registrations: [ExtractorRouteRegistrationSnapshot]
        /// Retained reconciler failures — the "failed to activate" signal.
        public let activationFailures: [ExtractorPackageReconciliationFailure]
        /// Exact revisions with a hosted definition waiting for activation.
        public let waitingRevisionIDs: Set<ExtractorPackageRevisionID>

        public init(
            configuration: ExtractionConfig,
            registrations: [ExtractorRouteRegistrationSnapshot],
            activationFailures: [ExtractorPackageReconciliationFailure] = [],
            waitingRevisionIDs: Set<ExtractorPackageRevisionID> = []
        ) {
            self.configuration = configuration
            self.registrations = registrations
            self.activationFailures = activationFailures
            self.waitingRevisionIDs = waitingRevisionIDs
        }
    }

    public static func build(_ input: Input) -> [ExtractorRouteSettingsRow] {
        let routes = descriptors(for: input).map(\.route)
        let activeRegistrations = activeResolverRegistrations(input.registrations)
        return routes.map { route in
            buildRow(route: route, input: input, activeRegistrations: activeRegistrations)
        }
    }

    // MARK: - Route collection

    private static func descriptors(for input: Input) -> [ExtractorRouteDescriptor] {
        var descriptors = ExtractorRouteHostCatalog.descriptors
        let hostedRoutes = Set(descriptors.map(\.route))
        var extra: [ExtractorRouteID] = []
        for snapshot in input.registrations {
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
        descriptors.append(contentsOf: extra.sorted().map(ExtractorRouteHostCatalog.fallbackDescriptor(for:)))
        return descriptors
    }

    // MARK: - Row construction

    private static func buildRow(
        route: ExtractorRouteID,
        input: Input,
        activeRegistrations: [ActiveExtractorRegistration]
    ) -> ExtractorRouteSettingsRow {
        let descriptor = descriptor(for: route, input: input)
        let choices = buildChoices(route: route, input: input)
        let savedSelection = input.configuration.extractorSelection(for: route)
        let decision = ExtractorSelectionResolver.resolve(
            route,
            configuration: input.configuration,
            activeRegistrations: activeRegistrations)
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
            ?? ExtractorRouteHostCatalog.fallbackDescriptor(for: route)
    }

    private static func buildChoices(route: ExtractorRouteID, input: Input) -> [ExtractorRouteChoice] {
        let hostChoices = ExtractorRouteHostCatalog.choices(for: route)
        let packages = packageChoices(route: route, input: input)
        // Installed packages slot directly after the reviewed package (mirroring
        // the long-standing picker order), before connected services and
        // built-ins. HTML's prompt choice stays first.
        var choices = hostChoices
        let insertIndex = choices.lastIndex { $0.category == .reviewedPackage }.map { $0 + 1 } ?? 0
        choices.insert(contentsOf: packages, at: insertIndex)
        return choices
    }

    /// Package choices for one route: registrations whose declared kinds and
    /// MIME types cover the route. Multiple exact versions of one logical
    /// (package, registration) deduplicate into one choice showing the highest
    /// active exact revision; the lifecycle rows below the table keep every
    /// exact version for inspection and removal.
    private static func packageChoices(route: ExtractorRouteID, input: Input) -> [ExtractorRouteChoice] {
        let matching = input.registrations.filter { snapshot in
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
            .sorted { $0.key < $1.key }
            .map { logical, snapshot in
                ExtractorRouteChoice(
                    route: route,
                    reference: .installed(logical),
                    displayName: snapshot.displayName,
                    category: .installedPackage,
                    exactSummary: Self.exactSummary(snapshot.reference.revision))
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
            // Built-in, connected, prompt, and no selection: what resolves is
            // what runs.
            return .available
        }
        if case .installed? = decision?.selection {
            return .available
        }
        // Unavailable installed selection: keep it selected and report the
        // live fallback, or the package-level lifecycle state when one exists.
        if input.waitingRevisionIDs.contains(where: { $0.packageID == logical.packageID }) {
            return .waitingForHostService
        }
        if input.activationFailures.contains(where: { $0.packageID == logical.packageID.rawValue }) {
            return .failedActivation
        }
        return .usingFallback(description: fallbackDescription(route: route, input: input))
    }

    private static func fallbackDescription(route: ExtractorRouteID, input: Input) -> String {
        descriptor(for: route, input: input).fallbackDescription
    }

    // MARK: - Resolver inputs

    private static func activeResolverRegistrations(
        _ snapshots: [ExtractorRouteRegistrationSnapshot]
    ) -> [ActiveExtractorRegistration] {
        snapshots.map { snapshot in
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
