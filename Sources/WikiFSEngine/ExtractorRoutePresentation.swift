import Foundation
import WikiFSCore

// pattern: Functional Core

/// One active exact registration's route-presentation data: manifest-derived
/// metadata plus the exact reference, projected by the extraction backend
/// registry. Settings consumes this snapshot to build route choices without
/// inspecting package payloads, paths, or manifests.
public struct ExtractorRouteRegistrationSnapshot: Hashable, Sendable {
    /// The exact package registration (revision + registration ID).
    public let reference: ExtractorReference
    /// The package source used for picker presentation.
    public let sourceCategory: ExtractorRouteSourceCategory
    /// User-facing registration name from the validated manifest.
    public let displayName: String
    /// User-facing package name from the validated manifest.
    public let packageName: String
    /// Declared operation kinds.
    public let kinds: Set<ExtractorKind>
    /// Declared input MIME types — each (kind, MIME) pair is a route.
    public let mimeTypes: Set<ExtractorMIMEType>
    /// Declared filename extensions — matching hints, never route identity.
    public let filenameExtensions: Set<ExtractorFileExtension>
    /// Declared credential requirements (non-secret declarations; #1159).
    public let credentialRequirements: [ExtractorCredentialRequirement]

    public init(
        reference: ExtractorReference,
        sourceCategory: ExtractorRouteSourceCategory = .installedPackage,
        displayName: String,
        packageName: String,
        kinds: Set<ExtractorKind>,
        mimeTypes: Set<ExtractorMIMEType>,
        filenameExtensions: Set<ExtractorFileExtension>,
        credentialRequirements: [ExtractorCredentialRequirement] = []
    ) {
        self.reference = reference
        self.sourceCategory = sourceCategory
        self.displayName = displayName
        self.packageName = packageName
        self.kinds = kinds
        self.mimeTypes = mimeTypes
        self.filenameExtensions = filenameExtensions
        self.credentialRequirements = credentialRequirements
    }
}

/// Where a route choice comes from. A closed enum — display strings are
/// presentation, never logic.
public enum ExtractorRouteSourceCategory: String, Hashable, Sendable, CaseIterable {
    case reviewedPackage = "reviewed-package"
    case installedPackage = "installed-package"
    case connectedService = "connected-service"
    case builtIn = "built-in"
    case prompt
    case unavailable
}

/// One host-owned route presentation for the format column.
public struct ExtractorRouteDescriptor: Hashable, Sendable {
    public let route: ExtractorRouteID
    public let displayName: String
    public let systemImage: String?

    public init(route: ExtractorRouteID, displayName: String, systemImage: String?) {
        self.route = route
        self.displayName = displayName
        self.systemImage = systemImage
    }
}

/// One selectable default-extractor choice inside a route row.
public struct ExtractorRouteChoice: Hashable, Sendable, Identifiable {
    public let route: ExtractorRouteID
    /// The persisted value this choice writes. The prompt choice writes
    /// `.none` (an explicit no-default record); there is no nil state.
    public let reference: ExtractionBackendReference
    public let displayName: String
    public let category: ExtractorRouteSourceCategory
    /// For installed-namespace choices (reviewed and installed packages): the
    /// exact revision summary of the highest active compatible registration,
    /// e.g. "2.0.0 · a1b2c3d4e5f6". `nil` when inactive or not installed.
    public let exactSummary: String?

    public init(
        route: ExtractorRouteID,
        reference: ExtractionBackendReference,
        displayName: String,
        category: ExtractorRouteSourceCategory,
        exactSummary: String? = nil
    ) {
        self.route = route
        self.reference = reference
        self.displayName = displayName
        self.category = category
        self.exactSummary = exactSummary
    }

    public var id: String {
        let referenceKey: String
        switch reference {
        case .none: referenceKey = "prompt"
        case .host(let host): referenceKey = "host/\(host.adapterID.rawValue)"
        case .installed(let logical): referenceKey = "installed/\(logical)"
        }
        return "\(route.description)/\(referenceKey)"
    }
}

public enum ExtractorRouteSetupReason: Hashable, Sendable {
    case missingACPProvider
    case unavailableACPProvider
    case invalidDoclingEndpoint
    case missingDoclingCredential
    case unauthorizedDoclingCredential
    case doclingConnectionFailed
}

/// Engine-owned lifecycle health for one route. App configuration facts can
/// refine this value in the recovery presenter.
public enum ExtractorRouteStatus: Hashable, Sendable {
    case ready
    case needsSetup(ExtractorRouteSetupReason)
    case packageNotInstalled
    case waitingForHostActivation
    case activationFailed(message: String?)
    case unavailableSelection
}

/// One route row in the Settings extractor route table: descriptor, the saved
/// and resolved selections, the compatible choices, and the status.
public struct ExtractorRouteSettingsRow: Hashable, Sendable, Identifiable {
    public let descriptor: ExtractorRouteDescriptor
    /// The persisted selection for this route (route record first, then the
    /// matching legacy reference field). `nil` = no selection.
    public let savedSelection: ExtractionBackendReference?
    /// What execution would resolve to today, via the selection resolver.
    public let resolvedSelection: ResolvedExtractionSelection?
    public let choices: [ExtractorRouteChoice]
    public let status: ExtractorRouteStatus

    public init(
        descriptor: ExtractorRouteDescriptor,
        savedSelection: ExtractionBackendReference?,
        resolvedSelection: ResolvedExtractionSelection?,
        choices: [ExtractorRouteChoice],
        status: ExtractorRouteStatus
    ) {
        self.descriptor = descriptor
        self.savedSelection = savedSelection
        self.resolvedSelection = resolvedSelection
        self.choices = choices
        self.status = status
    }

    public var route: ExtractorRouteID { descriptor.route }
    public var id: String { descriptor.route.description }
}

/// Host-owned route descriptors and non-package choices for the canonical
/// routes. Package choices come from validated catalog records.
public enum ExtractorRouteHostCatalog {
    /// The connected-service ACP adapter identity (host namespace). The
    /// retired direct-API host IDs (anthropic, gemini) never appear as
    /// choices; migrated selections of those values display as ACP.
    public static let acpReference = hostReference(ExtractionBackend.acp.rawValue)

    /// The built-in tag-based HTML adapter identity (host namespace).
    public static let tagBasedReference = hostReference(HtmlExtractionBackend.tagBased.rawValue)

    /// Legacy-only host identities: names older configs migrated onto host
    /// references. Execution remaps them to their reviewed package lineages;
    /// presentation maps them to the reviewed-package choices. They are never
    /// offered as new choices.
    public static let legacyPDF2mdReference = hostReference(ExtractionBackend.localPdf2md.rawValue)
    public static let legacyDoclingServeReference = hostReference(ExtractionBackend.doclingServe.rawValue)
    public static let legacyDefuddleReference = hostReference(HtmlExtractionBackend.defuddle.rawValue)

    /// Builds a validated host reference for a known-good adapter literal.
    public static func hostReference(_ rawValue: String) -> ExtractionBackendReference {
        guard let adapterID = HostExtractorID(rawValue: rawValue) else {
            preconditionFailure("Invalid host adapter literal: \(rawValue)")
        }
        return .host(HostExtractorReference(adapterID: adapterID))
    }

    /// Canonical routes in host display order (PDF first, then HTML, then
    /// DOCX).
    public static let descriptors: [ExtractorRouteDescriptor] = [
        ExtractorRouteDescriptor(
            route: .canonicalPDF,
            displayName: "PDF",
            systemImage: "doc.richtext"),
        ExtractorRouteDescriptor(
            route: .canonicalHTML,
            displayName: "HTML",
            systemImage: "safari"),
        ExtractorRouteDescriptor(
            route: .canonicalDOCX,
            displayName: "Word",
            systemImage: "doc.text"),
    ]

    /// The host's fixed choices for one route. Only canonical routes have
    /// host choices; a future registration-derived route offers package
    /// choices only. The DOCX route has no built-in backend, so its only
    /// host choice is the explicit "no default" entry — the reviewed docx2md
    /// package appears as a choice when its registration is active (from the
    /// validated catalog record), and never as a hardcoded host row.
    public static func choices(for route: ExtractorRouteID) -> [ExtractorRouteChoice] {
        if route == .canonicalPDF {
            return [
                ExtractorRouteChoice(
                    route: route,
                    reference: acpReference,
                    displayName: "ACP Provider",
                    category: .connectedService),
            ]
        }
        if route == .canonicalHTML {
            return [
                ExtractorRouteChoice(
                    route: route,
                    reference: .none,
                    displayName: "No default (ask each time)",
                    category: .prompt),
                ExtractorRouteChoice(
                    route: route,
                    reference: tagBasedReference,
                    displayName: "Tag-based",
                    category: .builtIn),
            ]
        }
        if route == .canonicalDOCX {
            return [
                ExtractorRouteChoice(
                    route: route,
                    reference: .none,
                    displayName: "No default (use the reviewed package)",
                    category: .prompt),
            ]
        }
        return []
    }

    /// Kinds the HOST itself can execute without any package: a route with a
    /// `.builtIn` or `.connectedService` choice (PDF's connected ACP service,
    /// HTML's built-in tag adapter). A route whose only host-side choice is
    /// `.prompt` (DOCX today) is package-only — the host has no backend for
    /// it, and the package registration is the only execution path.
    ///
    /// Host capability DATA derived from the choice table, not kind policy:
    /// import auto-extraction derives its package-only kinds from this set,
    /// so a future package-only kind converts on import with no host-policy
    /// change. NOTE: route DESCRIPTORS alone are the wrong signal — the DOCX
    /// Settings row is a display row for its package-only route; only the
    /// choice categories say whether the host can execute the kind.
    public static var hostBackendKinds: Set<ExtractorKind> {
        Set(descriptors
            .filter { descriptor in
                choices(for: descriptor.route)
                    .contains { $0.category == .builtIn || $0.category == .connectedService }
            }
            .map(\.route.kind))
    }

    /// Stable descriptor for a route without host-owned presentation metadata.
    public static func genericDescriptor(for route: ExtractorRouteID) -> ExtractorRouteDescriptor {
        ExtractorRouteDescriptor(
            route: route,
            displayName: route.mimeType.rawValue,
            systemImage: nil)
    }
}
