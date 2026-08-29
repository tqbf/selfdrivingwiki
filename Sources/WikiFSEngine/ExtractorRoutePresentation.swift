import Foundation
import WikiFSCore

// pattern: Functional Core

/// One active exact registration's route-presentation data: manifest-derived
/// metadata plus the exact reference, projected by the extraction backend
/// registry. Settings consumes this snapshot to build route choices without
/// inspecting package payloads, paths, or manifests.
public struct ExtractorRouteRegistrationSnapshot: Hashable, Sendable {
    /// The exact active registration (revision + registration ID).
    public let reference: ExtractorReference
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
        displayName: String,
        packageName: String,
        kinds: Set<ExtractorKind>,
        mimeTypes: Set<ExtractorMIMEType>,
        filenameExtensions: Set<ExtractorFileExtension>,
        credentialRequirements: [ExtractorCredentialRequirement] = []
    ) {
        self.reference = reference
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

/// One host-owned route presentation: what the format column shows and what
/// the fixed fallback for that route is.
public struct ExtractorRouteDescriptor: Hashable, Sendable {
    public let route: ExtractorRouteID
    public let displayName: String
    public let systemImage: String?
    public let fallbackDescription: String

    public init(route: ExtractorRouteID, displayName: String, systemImage: String?, fallbackDescription: String) {
        self.route = route
        self.displayName = displayName
        self.systemImage = systemImage
        self.fallbackDescription = fallbackDescription
    }
}

/// One selectable default-extractor choice inside a route row.
public struct ExtractorRouteChoice: Hashable, Sendable, Identifiable {
    public let route: ExtractorRouteID
    /// The persisted value this choice writes. `nil` only for the prompt
    /// choice (no selection).
    public let reference: ExtractionBackendReference?
    public let displayName: String
    public let category: ExtractorRouteSourceCategory
    /// For installed-namespace choices (reviewed and installed packages): the
    /// exact revision summary of the highest active compatible registration,
    /// e.g. "2.0.0 · a1b2c3d4e5f6". `nil` when inactive or not installed.
    public let exactSummary: String?

    public init(
        route: ExtractorRouteID,
        reference: ExtractionBackendReference?,
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
        case .builtIn(let builtIn): referenceKey = "builtIn/\(builtIn)"
        case .installed(let logical): referenceKey = "installed/\(logical)"
        }
        return "\(route.description)/\(referenceKey)"
    }
}

/// What the status column reports for a route row.
public enum ExtractorRouteStatus: Hashable, Sendable {
    /// The resolved selection is usable right now.
    case available
    /// A saved installed selection is unavailable and a fixed fallback is active.
    case usingFallback(description: String)
    /// A saved installed selection has no active registration and no recorded
    /// activation failure or waiting run.
    case notInstalled
    /// The selected package is admitted but its host service has not activated it.
    case waitingForHostService
    /// The selected package's activation failed in this process.
    case failedActivation
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

/// Host-owned route descriptors and built-in/connected choices for the two
/// canonical routes. Future registrations can add routes and package choices,
/// but the host's own choices are fixed here — reviewed packages included.
public enum ExtractorRouteHostCatalog {
    /// Canonical routes in host display order (PDF first, then HTML).
    public static let descriptors: [ExtractorRouteDescriptor] = [
        ExtractorRouteDescriptor(
            route: .canonicalPDF,
            displayName: "PDF",
            systemImage: "doc.richtext",
            fallbackDescription: "Bundled pdf2md extraction"),
        ExtractorRouteDescriptor(
            route: .canonicalHTML,
            displayName: "HTML",
            systemImage: "safari",
            fallbackDescription: "Tag-based text extraction"),
    ]

    /// The host's fixed choices for one route. Only the canonical routes have
    /// host choices; a future registration-derived route offers package
    /// choices only.
    public static func choices(for route: ExtractorRouteID) -> [ExtractorRouteChoice] {
        if route == .canonicalPDF {
            return [
                ExtractorRouteChoice(
                    route: route,
                    reference: .installed(ProcessExtractionServices.reviewedPDFLogical),
                    displayName: "pdf2md",
                    category: .reviewedPackage),
                ExtractorRouteChoice(
                    route: route,
                    reference: .builtIn(.pdf(.acp)),
                    displayName: "ACP Provider",
                    category: .connectedService),
                ExtractorRouteChoice(
                    route: route,
                    reference: .builtIn(.pdf(.doclingServe)),
                    displayName: "Docling Serve",
                    category: .connectedService),
            ]
        }
        if route == .canonicalHTML {
            return [
                ExtractorRouteChoice(
                    route: route,
                    reference: nil,
                    displayName: "No default (ask each time)",
                    category: .prompt),
                ExtractorRouteChoice(
                    route: route,
                    reference: .installed(ProcessExtractionServices.reviewedHTMLLogical),
                    displayName: "Defuddle",
                    category: .reviewedPackage),
                ExtractorRouteChoice(
                    route: route,
                    reference: .builtIn(.html(.tagBased)),
                    displayName: "Tag-based",
                    category: .builtIn),
            ]
        }
        return []
    }

    /// Stable fallback label for a route without a host descriptor — derived
    /// from the normalized MIME type alone. Future-facing: no current
    /// registration produces a route outside the host catalog.
    public static func fallbackDescriptor(for route: ExtractorRouteID) -> ExtractorRouteDescriptor {
        ExtractorRouteDescriptor(
            route: route,
            displayName: route.mimeType.rawValue,
            systemImage: nil,
            fallbackDescription: "No built-in fallback for this format")
    }
}
