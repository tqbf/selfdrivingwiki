import Foundation

// pattern: Functional Core

/// The input claims declared by active extractor registrations.
///
/// Each claim keeps one registration's kind, MIME types, and filename
/// extensions together. This prevents an extension from one registration from
/// borrowing a MIME type from another registration of the same kind.
public struct RegisteredExtractionInputs: Hashable, Sendable {
    public let claims: Set<Claim>

    public init(claims: Set<Claim> = []) {
        self.claims = claims
    }

    public static let none = RegisteredExtractionInputs()

    public var isEmpty: Bool { claims.isEmpty }

    /// One active registration's declared input surface for one extractor kind.
    public struct Claim: Hashable, Sendable {
        public let kind: ExtractorKind
        public let mimeTypes: Set<String>
        public let filenameExtensions: Set<String>
        /// The registration's agent-cleanup claim (manifest revision 5,
        /// issue #1379): the markdown this registration produces wants a
        /// best-effort agent cleanup pass after it lands. Package data,
        /// never host policy.
        public let wantsAgentCleanup: Bool

        public init(
            kind: ExtractorKind,
            mimeTypes: Set<String>,
            filenameExtensions: Set<String>,
            wantsAgentCleanup: Bool = false
        ) {
            self.kind = kind
            self.mimeTypes = Set(mimeTypes.map { $0.lowercased() })
            self.filenameExtensions = Set(filenameExtensions.map { $0.lowercased() })
            self.wantsAgentCleanup = wantsAgentCleanup
        }

        fileprivate var preferredMIME: String? { mimeTypes.sorted().first }
    }

    /// One unambiguous registered MIME match.
    public struct RegisteredMIME: Hashable, Sendable, CustomStringConvertible {
        public let kind: ExtractorKind
        public let mimeType: String

        public init(kind: ExtractorKind, mimeType: String) {
            self.kind = kind
            self.mimeType = mimeType.lowercased()
        }

        public var description: String { "\(kind.rawValue) \(mimeType)" }
    }

    /// One unambiguous registered filename-extension match.
    public struct RegisteredExtension: Hashable, Sendable, CustomStringConvertible {
        public let kind: ExtractorKind
        public let ext: String

        public init(kind: ExtractorKind, ext: String) {
            self.kind = kind
            self.ext = ext.lowercased()
        }

        public var description: String { "\(kind.rawValue) .\(ext)" }
    }

    /// Returns a match only when all registrations that claim the MIME agree
    /// on its extractor kind.
    public func registeredMIME(forNormalizedMIME mime: String) -> RegisteredMIME? {
        let normalized = mime.lowercased()
        let kinds = Set(claims.lazy.filter { $0.mimeTypes.contains(normalized) }.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else { return nil }
        return RegisteredMIME(kind: kind, mimeType: normalized)
    }

    /// Returns a match only when all registrations that claim the extension
    /// agree on its extractor kind.
    public func registeredInput(forNormalizedExtension ext: String) -> RegisteredExtension? {
        let normalized = ext.lowercased()
        let kinds = Set(claims.lazy.filter {
            $0.filenameExtensions.contains(normalized)
        }.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else { return nil }
        return RegisteredExtension(kind: kind, ext: normalized)
    }

    /// Whether the registrations claiming this MIME declare the
    /// agent-cleanup claim (issue #1379). Fail-closed like every other
    /// registration ambiguity: `false` when no claim matches or when the
    /// matching claims disagree.
    public func wantsAgentCleanup(forNormalizedMIME mime: String) -> Bool {
        let normalized = mime.lowercased()
        let matching = claims.filter { $0.mimeTypes.contains(normalized) }
        guard matching.isEmpty == false else { return false }
        return matching.allSatisfy(\.wantsAgentCleanup)
    }

    /// Promotes a generic ZIP detection when one active registration claim
    /// identifies the input. Conflicting claims fail closed.
    public func promotedMIME(
        detectedMIME: String?,
        declaredMIME: String?,
        filenameExtension ext: String?
    ) -> String? {
        guard detectedMIME?.lowercased() == MimeType.zip else { return nil }

        if let declaredMIME {
            let normalized = declaredMIME.lowercased()
            if registeredMIME(forNormalizedMIME: normalized) != nil {
                return normalized
            }
        }

        guard let ext else { return nil }
        let normalized = ext.lowercased()
        let matches = claims.filter { $0.filenameExtensions.contains(normalized) }
        guard !matches.isEmpty,
              matches.allSatisfy({ $0.preferredMIME != nil }) else { return nil }

        let resolved = Set(matches.compactMap { claim -> RegisteredMIME? in
            guard let mime = claim.preferredMIME else { return nil }
            return RegisteredMIME(kind: claim.kind, mimeType: mime)
        })
        guard resolved.count == 1 else { return nil }
        return resolved.first?.mimeType
    }
}
