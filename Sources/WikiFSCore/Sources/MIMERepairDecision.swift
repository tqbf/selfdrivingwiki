import Foundation
import WikiFSTypes

public struct MIMERepairDecisionInput: Sendable {
    public let sourceMIMEType: String?
    public let versionMIMEType: String?
    public let filenameExtension: String?
    public let detection: ContentTypeDetectionResult
    public let boundedBytes: Data?
    public let bytesAreComplete: Bool
    public let rendererSourceTypes: RegisteredRendererSourceTypes

    public init(
        sourceMIMEType: String?,
        versionMIMEType: String?,
        filenameExtension: String?,
        detection: ContentTypeDetectionResult,
        boundedBytes: Data?,
        bytesAreComplete: Bool,
        rendererSourceTypes: RegisteredRendererSourceTypes
    ) {
        self.sourceMIMEType = sourceMIMEType
        self.versionMIMEType = versionMIMEType
        self.filenameExtension = filenameExtension
        self.detection = detection
        self.boundedBytes = boundedBytes
        self.bytesAreComplete = bytesAreComplete
        self.rendererSourceTypes = rendererSourceTypes
    }
}

public struct MIMERepairDecision: Equatable, Sendable {
    public let status: MIMERepairStatus
    public let newMIMEType: String?

    public init(status: MIMERepairStatus, newMIMEType: String? = nil) {
        self.status = status
        self.newMIMEType = newMIMEType
    }

    public static func decide(_ input: MIMERepairDecisionInput) -> Self {
        guard let bytes = input.boundedBytes else { return .init(status: .byteless) }
        let sourceMIME = ContentTypeDetector.normalizeMIMEType(input.sourceMIMEType)
        let versionMIME = ContentTypeDetector.normalizeMIMEType(input.versionMIMEType)
        let mirrors = [sourceMIME, versionMIME]
        let hasBinarySignature = input.detection.evidence.contains { $0.origin == .binarySignature }
        // Repair mirrors ingest precedence: the catalog gets the first look.
        // A mirror that is nil, octet-stream, or the sniffer's generic text
        // verdict is inconclusive about format identity, so the extension
        // claim may resolve it; any other mirror must belong to the resolved
        // presentation group's declared MIME values or the row conflicts.
        func isInconclusive(_ mime: String?) -> Bool {
            mime == nil || mime == MimeType.octetStream || mime == "text/plain"
        }
        let nonNilMirrors = mirrors.compactMap { $0 }
        let candidateMIME = nonNilMirrors.first { !isInconclusive($0) }
            ?? nonNilMirrors.first
        let resolution = input.rendererSourceTypes.resolve(
            mimeType: candidateMIME,
            filenameExtension: input.filenameExtension,
            boundedBytes: bytes,
            bytesAreComplete: input.bytesAreComplete,
            artifactKind: .source,
            allowInconclusiveMIMEExtensionFallback: candidateMIME == nil
                || isInconclusive(candidateMIME))
        switch resolution {
        case .ambiguous:
            return .init(status: .ambiguity)
        case .resolved(let claim):
            if hasBinarySignature {
                return .init(status: .conflict)
            }
            for mirror in nonNilMirrors where !isInconclusive(mirror) {
                guard let typed = RendererMIMEType(rawValue: mirror),
                      claim.declaredMIMETypes.contains(typed) else {
                    return .init(status: .conflict)
                }
            }
            let canonical = claim.canonicalMIMEType.rawValue
            // A no-op requires BOTH stored mirrors to already carry the
            // canonical value. Comparing only the non-NULL mirrors would
            // strand a NULL sibling outside the candidate set forever.
            if mirrors.allSatisfy({ $0 == canonical }) {
                return .init(status: .canonicalNoOp)
            }
            return .init(status: .packageAliasNormalization, newMIMEType: canonical)
        case .noMatch:
            break
        }

        // Detector repair keeps precedence for NULL mirrors the catalog could
        // not resolve.
        if sourceMIME == nil || versionMIME == nil {
            if let detected = input.detection.normalizedMIMEType {
                return .init(status: .detectorRepair, newMIMEType: detected)
            }
        }

        if sourceMIME != versionMIME { return .init(status: .conflict) }
        return .init(status: .inconclusive)
    }
}
