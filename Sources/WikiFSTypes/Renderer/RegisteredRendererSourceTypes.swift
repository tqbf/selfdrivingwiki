import Foundation

/// Immutable source-format claims projected from active, validated renderer descriptors.
public struct RegisteredRendererSourceTypes: Hashable, Sendable {
    public struct Claim: Hashable, Sendable {
        public let descriptor: RendererDescriptor
        public let reference: RendererReference
        public let displayName: String
        public let canonicalMIMEType: RendererMIMEType
        public let mimeAliases: Set<RendererMIMEType>
        public let filenameExtensions: Set<RendererFileExtension>

        public init(descriptor: RendererDescriptor) {
            guard let sourceType = descriptor.sourceType else {
                preconditionFailure("Claims require a descriptor with a source type declaration")
            }
            self.descriptor = descriptor
            reference = descriptor.reference
            displayName = descriptor.displayName
            canonicalMIMEType = sourceType.canonicalMIMEType
            mimeAliases = sourceType.mimeAliases
            filenameExtensions = sourceType.filenameExtensions
        }

        public var allMIMETypes: Set<RendererMIMEType> {
            mimeAliases.union([canonicalMIMEType])
        }
    }

    public struct Resolution: Hashable, Sendable {
        public let canonicalMIMEType: RendererMIMEType
        public let displayName: String
        public let reference: RendererReference
        public let descriptor: RendererDescriptor
        /// Every MIME value declared by the claims sharing this resolution's
        /// presentation identity (canonical MIME + display name). Claims that
        /// present identically accept each other's declared aliases, so
        /// repair can treat any of them as evidence for the shared identity.
        public let declaredMIMETypes: Set<RendererMIMEType>

        fileprivate init(claim: Claim, declaredMIMETypes: Set<RendererMIMEType>) {
            canonicalMIMEType = claim.canonicalMIMEType
            displayName = claim.displayName
            reference = claim.reference
            descriptor = claim.descriptor
            self.declaredMIMETypes = declaredMIMETypes
        }
    }

    public enum Outcome: Hashable, Sendable {
        case resolved(Resolution)
        case ambiguous
        case noMatch

        public var resolution: Resolution? {
            guard case let .resolved(value) = self else { return nil }
            return value
        }
    }

    public static let none = Self(claims: [])
    public let claims: Set<Claim>

    public init(descriptors: [RendererDescriptor]) {
        self.init(claims: Set(descriptors.filter(\.hasSourceTypeDeclaration).map(Claim.init)))
    }

    public init(claims: Set<Claim>) {
        self.claims = claims
    }

    public var isEmpty: Bool { claims.isEmpty }

    /// Resolves using the descriptor's full routing and artifact predicate.
    public func resolve(
        _ input: RendererMatchInput,
        allowInconclusiveMIMEExtensionFallback: Bool = false
    ) -> Outcome {
        let strong = eligibleClaims(for: input, tier: .strong)
        if strong.isEmpty == false { return coalesced(strong) }

        guard Self.mimeAllowsExtensionFallback(
            input.mimeType,
            allowInconclusive: allowInconclusiveMIMEExtensionFallback) else { return .noMatch }
        return coalesced(eligibleClaims(for: input, tier: .extensionFallback))
    }

    public func resolve(
        mimeType: String?,
        filenameExtension: String?,
        boundedBytes: Data,
        bytesAreComplete: Bool,
        artifactKind: RendererArtifactKind? = .source,
        allowInconclusiveMIMEExtensionFallback: Bool = false
    ) -> Outcome {
        do {
            let mime = try mimeType.flatMap { raw -> RendererMIMEType? in
                guard let normalized = Self.normalizedMIME(raw) else { return nil }
                return try RendererMIMEType(validating: normalized)
            }
            let ext = try filenameExtension.flatMap { raw -> RendererFileExtension? in
                let normalized = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)).lowercased()
                guard normalized.isEmpty == false else { return nil }
                return try RendererFileExtension(validating: normalized)
            }
            let artifactInput = BoundedArtifactInput(bytes: boundedBytes, isComplete: bytesAreComplete)
            let input = try RendererMatchInput(
                mimeType: mime,
                fileExtension: ext,
                sniffedBytes: Data(boundedBytes.prefix(RendererMatchingLimits.maximumSniffByteCount)),
                sniffedBytesAreComplete: bytesAreComplete && boundedBytes.count <= RendererMatchingLimits.maximumSniffByteCount,
                artifactInput: artifactInput,
                artifactKind: artifactKind)
            return resolve(input, allowInconclusiveMIMEExtensionFallback: allowInconclusiveMIMEExtensionFallback)
        } catch {
            return .noMatch
        }
    }

    /// Resolves metadata-only contexts. Claims with required artifact predicates
    /// cannot be proven without bytes and therefore fail closed.
    public func resolveWithoutBytes(
        mimeType: RendererMIMEType?,
        fileExtension: RendererFileExtension?
    ) -> Outcome {
        let byteFreeClaims = claims.filter { claim in
            claim.descriptor.matchers.contains(where: \.requiresArtifactValidation) == false
        }
        let strong = byteFreeClaims.filter { claim in
            guard let mimeType else { return false }
            return claim.allMIMETypes.contains(mimeType)
        }
        if strong.isEmpty == false { return coalesced(strong) }
        guard Self.mimeAllowsExtensionFallback(mimeType), let fileExtension else { return .noMatch }
        return coalesced(byteFreeClaims.filter { $0.filenameExtensions.contains(fileExtension) })
    }

    public func containsDeclaredMIME(_ mimeType: RendererMIMEType) -> Bool {
        claims.contains { $0.allMIMETypes.contains(mimeType) }
    }

    public func containsDeclaredExtension(_ extensionName: RendererFileExtension) -> Bool {
        claims.contains { $0.filenameExtensions.contains(extensionName) }
    }

    public var declaredFilenameExtensions: Set<RendererFileExtension> {
        claims.reduce(into: Set<RendererFileExtension>()) { $0.formUnion($1.filenameExtensions) }
    }

    /// Cheap metadata-only check for read paths: whether this MIME or
    /// extension could resolve to a text-producing claim. Does not prove a
    /// match; callers still resolve against bytes.
    public func mightPresentAsText(mimeType: String?, filenameExtension: String?) -> Bool {
        if let mimeType,
           let typed = RendererMIMEType(rawValue: mimeType.lowercased()) {
            let mimeMatches = claims.contains { claim in
                claim.allMIMETypes.contains(typed)
                    && claim.canonicalMIMEType.rawValue.hasPrefix("text/")
            }
            if mimeMatches { return true }
        }
        guard let filenameExtension,
              let typed = RendererFileExtension(rawValue: filenameExtension.lowercased()) else {
            return false
        }
        return claims.contains { claim in
            claim.filenameExtensions.contains(typed)
                && claim.canonicalMIMEType.rawValue.hasPrefix("text/")
        }
    }

    public var declaredMIMETypes: Set<RendererMIMEType> {
        claims.reduce(into: Set<RendererMIMEType>()) { $0.formUnion($1.allMIMETypes) }
    }

    private func eligibleClaims(for input: RendererMatchInput, tier: RendererMatchTier) -> Set<Claim> {
        Set(claims.filter { claim in
            guard claim.descriptor.matchTier(for: input) == tier else { return false }
            switch tier {
            case .strong:
                guard let mimeType = input.mimeType else { return false }
                return claim.allMIMETypes.contains(mimeType)
            case .extensionFallback:
                guard let fileExtension = input.fileExtension else { return false }
                return claim.filenameExtensions.contains(fileExtension)
            }
        })
    }

    private func coalesced(_ candidates: Set<Claim>) -> Outcome {
        guard let first = candidates.min(by: {
            $0.descriptor.stableTieBreakKey < $1.descriptor.stableTieBreakKey
        }) else { return .noMatch }
        // Ambiguity is about presentation identity: claims that agree on the
        // canonical MIME and display name present identically regardless of
        // differing extra routes or artifact predicates (each candidate
        // already passed its own full predicate to get here). Anything else
        // fails closed.
        let equivalent = candidates.allSatisfy {
            $0.canonicalMIMEType == first.canonicalMIMEType
                && $0.displayName == first.displayName
        }
        guard equivalent else { return .ambiguous }
        // The declared set spans the whole presentation group, not just the
        // winning descriptor: a mirror carrying another group member's alias
        // is evidence for the same identity, not a conflict.
        let presentation = claims.filter {
            $0.canonicalMIMEType == first.canonicalMIMEType
                && $0.displayName == first.displayName
        }
        return .resolved(Resolution(
            claim: first,
            declaredMIMETypes: Set(presentation.flatMap(\.allMIMETypes))))
    }

    private static func mimeAllowsExtensionFallback(
        _ mimeType: RendererMIMEType?,
        allowInconclusive: Bool = false
    ) -> Bool {
        guard let mimeType else { return true }
        return mimeType.rawValue == "application/octet-stream" || allowInconclusive
    }

    private static func normalizedMIME(_ value: String) -> String? {
        let base = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
        let normalized = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
