import Foundation
import WikiFSMarkdown
import WikiFSTypes

/// One active exact registration visible to logical selection.
public struct ActiveExtractorRegistration: Hashable, Sendable {
    public let reference: ExtractorReference
    public let kinds: Set<ExtractorKind>
    public let protocolRevision: ExtractorProtocolRevision

    public init(
        reference: ExtractorReference,
        kinds: Set<ExtractorKind>,
        protocolRevision: ExtractorProtocolRevision
    ) {
        self.reference = reference
        self.kinds = kinds
        self.protocolRevision = protocolRevision
    }
}

/// What execution would run for one route today. The route supplies the input
/// format; these cases name only the implementation — a host adapter, an exact
/// installed registration, a saved-but-absent lineage, or nothing.
public enum ResolvedExtractionSelection: Hashable, Sendable {
    /// Execution would run the named host adapter (a connected service or the
    /// built-in floor adapter), registered under this route's kind.
    case host(HostExtractorReference)
    case installed(kind: ExtractorKind, reference: ExtractorReference)
    /// The saved installed selection has no compatible active registration.
    /// The logical identity stays selected and no other extractor may run.
    case unavailableInstalled(kind: ExtractorKind, reference: LogicalExtractorReference)
    /// No default: nothing runs until a selection is made (the HTML prompt
    /// state, or an explicit disable of the shipped default).
    case noSelection
}

/// Redacted selection diagnostic. It contains no version, digest, path, or package output.
public enum ExtractionSelectionDiagnostic: Hashable, Sendable {
    case unavailableInstalled(LogicalExtractorReference)
}

public struct ExtractionSelectionDecision: Hashable, Sendable {
    public let selection: ResolvedExtractionSelection
    public let diagnostic: ExtractionSelectionDiagnostic?

    public init(selection: ResolvedExtractionSelection, diagnostic: ExtractionSelectionDiagnostic? = nil) {
        self.selection = selection
        self.diagnostic = diagnostic
    }
}

/// Applies the version-free selection precedence without changing the persisted configuration.
public enum ExtractorSelectionResolver {
    /// Route-aware selection entry. Resolves one route through the same
    /// precedence as the per-kind entry points; returns `nil` for routes without
    /// a host execution path (a future registration's MIME type has no resolver
    /// until an execution adapter exists).
    public static func resolve(
        _ route: ExtractorRouteID,
        configuration: ExtractionConfig,
        activeRegistrations: [ActiveExtractorRegistration]
    ) -> ExtractionSelectionDecision? {
        if route == .canonicalPDF { return resolvePDF(configuration: configuration, activeRegistrations: activeRegistrations) }
        if route == .canonicalHTML { return resolveHTML(configuration: configuration, activeRegistrations: activeRegistrations) }
        if route == .canonicalDOCX { return resolveDOCX(configuration: configuration, activeRegistrations: activeRegistrations) }
        return nil
    }

    public static func resolvePDF(
        configuration: ExtractionConfig,
        activeRegistrations: [ActiveExtractorRegistration]
    ) -> ExtractionSelectionDecision {
        resolve(.canonicalPDF, kind: .pdf, configuration: configuration, activeRegistrations: activeRegistrations)
    }

    public static func resolveHTML(
        configuration: ExtractionConfig,
        activeRegistrations: [ActiveExtractorRegistration]
    ) -> ExtractionSelectionDecision {
        resolve(.canonicalHTML, kind: .html, configuration: configuration, activeRegistrations: activeRegistrations)
    }

    /// DOCX resolution is the same generic shape as every other route: DOCX is
    /// package-only, so the bundled default record (the reviewed docx2md
    /// lineage) supplies the default and an explicit `.none` disables it.
    public static func resolveDOCX(
        configuration: ExtractionConfig,
        activeRegistrations: [ActiveExtractorRegistration]
    ) -> ExtractionSelectionDecision {
        resolve(.canonicalDOCX, kind: .docx, configuration: configuration, activeRegistrations: activeRegistrations)
    }

    /// The single generic precedence: the stored route record first, then the
    /// bundled default-route record, then no selection. An installed reference
    /// resolves to the highest compatible active registration or fails closed
    /// with the redacted diagnostic; a host reference passes through.
    private static func resolve(
        _ route: ExtractorRouteID,
        kind: ExtractorKind,
        configuration: ExtractionConfig,
        activeRegistrations: [ActiveExtractorRegistration]
    ) -> ExtractionSelectionDecision {
        guard let selection = configuration.selectionOrDefault(for: route) else {
            return ExtractionSelectionDecision(selection: .noSelection)
        }
        switch selection {
        case .none:
            return ExtractionSelectionDecision(selection: .noSelection)
        case .host(let host):
            return ExtractionSelectionDecision(selection: .host(host))
        case .installed(let logicalReference):
            if let exact = highestCompatible(
                logicalReference,
                kind: kind,
                activeRegistrations: activeRegistrations)
            {
                return ExtractionSelectionDecision(selection: .installed(kind: kind, reference: exact))
            }
            return ExtractionSelectionDecision(
                selection: .unavailableInstalled(kind: kind, reference: logicalReference),
                diagnostic: .unavailableInstalled(logicalReference))
        }
    }

    private static func highestCompatible(
        _ logicalReference: LogicalExtractorReference,
        kind: ExtractorKind,
        activeRegistrations: [ActiveExtractorRegistration]
    ) -> ExtractorReference? {
        activeRegistrations
            .filter {
                // #1159: protocol revision 2 registrations are selectable
                // alongside revision 1.
                ($0.protocolRevision == .v1 || $0.protocolRevision == .v2)
                    && $0.kinds.contains(kind)
                    && $0.reference.revision.packageID == logicalReference.packageID
                    && $0.reference.registrationID == logicalReference.registrationID
            }
            .map(\.reference)
            .max(by: isLowerRank)
    }

    private static func isLowerRank(_ lhs: ExtractorReference, _ rhs: ExtractorReference) -> Bool {
        let precedence = lhs.revision.version.semanticPrecedence(comparedTo: rhs.revision.version)
        if precedence != .orderedSame { return precedence == .orderedAscending }
        if lhs.revision.digest != rhs.revision.digest { return lhs.revision.digest < rhs.revision.digest }
        if lhs.revision.version.rawValue != rhs.revision.version.rawValue {
            return lhs.revision.version.rawValue < rhs.revision.version.rawValue
        }
        return lhs.registrationID < rhs.registrationID
    }
}
