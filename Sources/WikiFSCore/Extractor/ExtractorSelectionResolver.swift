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

public enum ResolvedExtractionSelection: Hashable, Sendable {
    case pdfBuiltIn(ExtractionBackend)
    case htmlBuiltIn(HtmlExtractionBackend)
    case installed(kind: ExtractorKind, reference: ExtractorReference)
    case noHTMLSelection
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
    public static func resolvePDF(
        configuration: ExtractionConfig,
        activeRegistrations: [ActiveExtractorRegistration]
    ) -> ExtractionSelectionDecision {
        guard let logicalSelection = configuration.pdfExtractor else {
            return ExtractionSelectionDecision(selection: .pdfBuiltIn(configuration.backend))
        }
        switch logicalSelection {
        case .builtIn(.pdf(let backend)):
            return ExtractionSelectionDecision(selection: .pdfBuiltIn(backend))
        case .builtIn(.html):
            return ExtractionSelectionDecision(selection: .pdfBuiltIn(configuration.backend))
        case .installed(let logicalReference):
            if let exact = highestCompatible(
                logicalReference,
                kind: .pdf,
                activeRegistrations: activeRegistrations)
            {
                return ExtractionSelectionDecision(selection: .installed(kind: .pdf, reference: exact))
            }
            return ExtractionSelectionDecision(
                selection: .pdfBuiltIn(.localPdf2md),
                diagnostic: .unavailableInstalled(logicalReference))
        }
    }

    public static func resolveHTML(
        configuration: ExtractionConfig,
        activeRegistrations: [ActiveExtractorRegistration]
    ) -> ExtractionSelectionDecision {
        guard let logicalSelection = configuration.htmlExtractor else {
            guard let legacy = configuration.htmlBackend else {
                return ExtractionSelectionDecision(selection: .noHTMLSelection)
            }
            return ExtractionSelectionDecision(selection: .htmlBuiltIn(legacy))
        }
        switch logicalSelection {
        case .builtIn(.html(let backend)):
            return ExtractionSelectionDecision(selection: .htmlBuiltIn(backend))
        case .builtIn(.pdf):
            guard let legacy = configuration.htmlBackend else {
                return ExtractionSelectionDecision(selection: .noHTMLSelection)
            }
            return ExtractionSelectionDecision(selection: .htmlBuiltIn(legacy))
        case .installed(let logicalReference):
            if let exact = highestCompatible(
                logicalReference,
                kind: .html,
                activeRegistrations: activeRegistrations)
            {
                return ExtractionSelectionDecision(selection: .installed(kind: .html, reference: exact))
            }
            return ExtractionSelectionDecision(
                selection: .htmlBuiltIn(.tagBased),
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
                $0.protocolRevision == .v1
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
