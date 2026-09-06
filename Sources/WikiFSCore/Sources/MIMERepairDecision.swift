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
        let nonNilMirrors = [sourceMIME, versionMIME].compactMap { $0 }
        let hasBinarySignature = input.detection.evidence.contains { $0.origin == .binarySignature }

        if sourceMIME == nil || versionMIME == nil {
            if let detected = input.detection.normalizedMIMEType {
                return .init(status: .detectorRepair, newMIMEType: detected)
            }
        }

        let packageOutcomes = Set(nonNilMirrors.map { mime in
            input.rendererSourceTypes.resolve(
                mimeType: mime,
                filenameExtension: input.filenameExtension,
                boundedBytes: bytes,
                bytesAreComplete: input.bytesAreComplete,
                artifactKind: .source)
        })
        if packageOutcomes.contains(.ambiguous) { return .init(status: .ambiguity) }
        let packageResolutions = packageOutcomes.compactMap(\.resolution)
        if packageResolutions.isEmpty == false {
            let canonicalValues = Set(packageResolutions.map { $0.canonicalMIMEType.rawValue })
            guard canonicalValues.count == 1, let canonical = canonicalValues.first else {
                return .init(status: .conflict)
            }
            let declaredMIMEs = Set(packageResolutions.flatMap {
                $0.descriptor.sourceType?.allMIMETypes ?? []
            })
            let mirrorMIMEs = Set(nonNilMirrors.compactMap { RendererMIMEType(rawValue: $0) })
            guard mirrorMIMEs.isSubset(of: declaredMIMEs) else {
                return .init(status: .conflict)
            }
            if nonNilMirrors.allSatisfy({ $0 == canonical }) {
                return .init(status: .canonicalNoOp)
            }
            guard hasBinarySignature == false else {
                return .init(status: .conflict)
            }
            return .init(status: .packageAliasNormalization, newMIMEType: canonical)
        }

        if sourceMIME != versionMIME { return .init(status: .conflict) }
        if input.bytesAreComplete == false { return .init(status: .inconclusive) }
        return .init(status: .inconclusive)
    }
}
