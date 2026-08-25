import Foundation
import WikiFSTypes

public enum OKFConceptType: String, Sendable {
    case page = "Page"
    case source = "Source"
}

public struct OKFActor: Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(pageAuthorRawValue: String?) {
        self = Self.pageActor(from: PageAuthor(rawValue: pageAuthorRawValue))
    }

    public static func pageActor(from author: PageAuthor) -> OKFActor {
        switch author {
        case .user:
            return OKFActor(rawValue: "human:user")
        case .chat(let id):
            return OKFActor(rawValue: "process:chat:\(id)")
        case .agent(let kind):
            return OKFActor(rawValue: "process:agent:\(kind)")
        case .legacyImport:
            return OKFActor(rawValue: "process:legacy-import")
        case .other(let rawValue):
            return Self.normalizedProducer(rawName: rawValue, version: nil)
        }
    }

    public static func sourceActor(
        producerName: String?,
        producerVersion: String?,
        fallbackOrigin: SourceMarkdownOrigin
    ) -> OKFActor {
        if let producerName, !producerName.isEmpty {
            return normalizedProducer(rawName: producerName, version: producerVersion)
        }

        switch fallbackOrigin {
        case .user:
            return OKFActor(rawValue: "human:user")
        case .revert:
            return OKFActor(rawValue: "process:revert")
        case .source:
            return OKFActor(rawValue: "process:source")
        case .transcript:
            return OKFActor(rawValue: "process:transcript")
        case .extraction:
            return OKFActor(rawValue: "process:extraction")
        }
    }

    private static func normalizedProducer(rawName: String, version: String?) -> OKFActor {
        if rawName.hasPrefix("human:") || rawName.hasPrefix("process:") || rawName.contains("/") {
            return OKFActor(rawValue: rawName)
        }
        if rawName == PageAuthor.user.rawValue {
            return OKFActor(rawValue: "human:user")
        }
        if let version, !version.isEmpty {
            return OKFActor(rawValue: "\(rawName)/\(version)")
        }
        return OKFActor(rawValue: "process:\(rawName)")
    }
}

public enum OKFConceptStatus: String, CaseIterable, Codable, Sendable {
    case draft
    case stable
    case deprecated
}

public struct OKFVerificationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct OKFActivityID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum OKFVerificationBasisKind: String, CaseIterable, Codable, Sendable {
    case humanReview = "human-review"
    case sourceChecked = "source-checked"
    case externalRevalidation = "external-revalidation"
}

public enum OKFEvidenceReference: Equatable, Codable, Sendable {
    case source(SourceID)
    case external(URL)

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case source, external }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .source:
            self = .source(SourceID(rawValue: try container.decode(String.self, forKey: .value)))
        case .external:
            let rawValue = try container.decode(String.self, forKey: .value)
            guard let url = URL(string: rawValue),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container,
                    debugDescription: "External evidence must be an absolute HTTP or HTTPS URL")
            }
            self = .external(url)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .source(let id):
            try container.encode(Kind.source, forKey: .type)
            try container.encode(id.rawValue, forKey: .value)
        case .external(let url):
            try container.encode(Kind.external, forKey: .type)
            try container.encode(url.absoluteString, forKey: .value)
        }
    }
}

public struct OKFVerificationBasis: Equatable, Codable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let kind: OKFVerificationBasisKind
    public let evidence: [OKFEvidenceReference]
    public let note: String?

    public init(
        kind: OKFVerificationBasisKind,
        evidence: [OKFEvidenceReference] = [],
        note: String? = nil
    ) {
        self.version = Self.currentVersion
        self.kind = kind
        self.evidence = evidence
        self.note = note
    }

    public func validateVersion() throws {
        guard version == Self.currentVersion else {
            throw OKFMetadataError.unsupportedPayloadVersion(version)
        }
    }
}

public struct OKFVerificationCorrectionReason: Equatable, Codable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let reason: String

    public init(reason: String) {
        self.version = Self.currentVersion
        self.reason = reason
    }

    public func validateVersion() throws {
        guard version == Self.currentVersion else {
            throw OKFMetadataError.unsupportedPayloadVersion(version)
        }
    }
}

public enum OKFFreshnessAnchor: Equatable, Codable, Sendable {
    case generated
    case verification(OKFVerificationID)
    /// Valid only while recording a verification in the same transaction.
    case recordedVerification
}

public enum OKFFreshnessPolicy: Equatable, Codable, Sendable {
    case fixed(Date)
    case ttl(seconds: Int64, anchor: OKFFreshnessAnchor)

    public static func ttl(_ duration: Duration, anchor: OKFFreshnessAnchor) throws -> Self {
        let components = duration.components
        guard components.attoseconds == 0, components.seconds > 0 else {
            throw OKFMetadataError.invalidFreshnessDuration
        }
        return .ttl(seconds: components.seconds, anchor: anchor)
    }

    public var duration: Duration? {
        guard case .ttl(let seconds, _) = self else { return nil }
        return .seconds(seconds)
    }
}

public enum OKFTrustTier: String, Codable, Sendable {
    case unverified
    case machineConfirmed = "machine-confirmed"
    case humanReviewed = "human-reviewed"
}

public struct OKFVerifierIdentity: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case human, process, producer }

    public let rawValue: String
    public let kind: Kind
    public let name: String
    public let version: String?

    public var isHuman: Bool { kind == .human }

    public init(_ rawValue: String) throws {
        if rawValue.hasPrefix("human:") || rawValue.hasPrefix("process:") {
            let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty,
                  parts[1].trimmingCharacters(in: .whitespacesAndNewlines) == parts[1]
            else { throw OKFMetadataError.invalidVerifier(rawValue) }
            self.rawValue = rawValue
            self.kind = parts[0] == "human" ? .human : .process
            self.name = String(parts[1])
            self.version = nil
            return
        }

        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              rawValue.trimmingCharacters(in: .whitespacesAndNewlines) == rawValue
        else { throw OKFMetadataError.invalidVerifier(rawValue) }
        self.rawValue = rawValue
        self.kind = .producer
        self.name = String(parts[0])
        self.version = String(parts[1])
    }

    public var agentKind: String {
        switch kind {
        case .human: return "human"
        case .process, .producer: return "software"
        }
    }
}

public enum OKFMetadataError: Error, Equatable, LocalizedError, Sendable {
    case invalidVerifier(String)
    case invalidFreshnessDuration
    case unsupportedPayloadVersion(Int)
    case invalidEvidence(String)
    case corruptPersistedMetadata(String)
    case targetNotFound
    case verificationNotFound
    case verificationTargetMismatch
    case verificationAlreadyCorrected

    public var errorDescription: String? {
        switch self {
        case .invalidVerifier(let value): return "Invalid OKF verifier identity: \(value)"
        case .invalidFreshnessDuration: return "Freshness TTL must be a positive whole-second duration"
        case .unsupportedPayloadVersion(let version): return "Unsupported OKF metadata payload version: \(version)"
        case .invalidEvidence(let detail): return "Invalid OKF verification evidence: \(detail)"
        case .corruptPersistedMetadata(let detail): return "Corrupt persisted OKF metadata: \(detail)"
        case .targetNotFound: return "The selected concept version does not exist"
        case .verificationNotFound: return "The selected verification does not exist"
        case .verificationTargetMismatch: return "The verification does not belong to the selected concept version"
        case .verificationAlreadyCorrected: return "The selected verification has already been corrected"
        }
    }
}

public struct OKFVerificationEvent: Equatable, Sendable {
    public let id: OKFVerificationID
    public let by: OKFVerifierIdentity
    public let verifiedAt: Date
    public let basis: OKFVerificationBasis
    public let removedAt: Date?
    public let correctionActivityID: OKFActivityID?
    public let correctedBy: OKFVerifierIdentity?
    public let correctionReason: OKFVerificationCorrectionReason?

    public init(
        id: OKFVerificationID,
        by: OKFVerifierIdentity,
        verifiedAt: Date,
        basis: OKFVerificationBasis,
        removedAt: Date? = nil,
        correctionActivityID: OKFActivityID? = nil,
        correctedBy: OKFVerifierIdentity? = nil,
        correctionReason: OKFVerificationCorrectionReason? = nil
    ) {
        self.id = id
        self.by = by
        self.verifiedAt = verifiedAt
        self.basis = basis
        self.removedAt = removedAt
        self.correctionActivityID = correctionActivityID
        self.correctedBy = correctedBy
        self.correctionReason = correctionReason
    }
}

public struct OKFConceptMetadata: Equatable, Sendable {
    public let status: OKFConceptStatus?
    public let staleAfter: Date?
    public let freshnessPolicy: OKFFreshnessPolicy?
    public let verifications: [OKFVerificationEvent]
    public let projectionRevision: Int64

    public init(
        status: OKFConceptStatus? = nil,
        staleAfter: Date? = nil,
        freshnessPolicy: OKFFreshnessPolicy? = nil,
        verifications: [OKFVerificationEvent] = [],
        projectionRevision: Int64 = 0
    ) {
        self.status = status
        self.staleAfter = staleAfter
        self.freshnessPolicy = freshnessPolicy
        self.verifications = verifications.sorted {
            ($0.verifiedAt, $0.id.rawValue) < ($1.verifiedAt, $1.id.rawValue)
        }
        self.projectionRevision = projectionRevision
    }

    public var activeVerifications: [OKFVerificationEvent] {
        verifications.filter { $0.removedAt == nil }
    }

    public var trustTier: OKFTrustTier {
        let active = activeVerifications
        if active.contains(where: { $0.by.isHuman }) { return .humanReviewed }
        return active.isEmpty ? .unverified : .machineConfirmed
    }

    public func isStale(at now: Date) -> Bool? {
        staleAfter.map { now >= $0 }
    }
}

public struct PageOKFTrustMetadata: Equatable, Sendable {
    public let pageID: PageID
    public let versionID: PageVersionID
    public let metadata: OKFConceptMetadata
}

public struct SourceMarkdownOKFTrustMetadata: Equatable, Sendable {
    public let sourceID: SourceID
    public let versionID: SourceMarkdownVersionID
    public let metadata: OKFConceptMetadata
}

public struct OKFGenerated: Equatable, Sendable {
    public let by: OKFActor
    public let at: Date

    public init(by: OKFActor, at: Date) {
        self.by = by
        self.at = at
    }
}

public enum OKFResource: Equatable, Sendable {
    case url(URL)
    case bundlePath(String)

    var scalarValue: String {
        switch self {
        case .url(let url):
            return url.absoluteString
        case .bundlePath(let path):
            return path
        }
    }
}

public struct OKFSourceReference: Equatable, Sendable {
    public let resource: OKFResource
    public let title: String?

    public init(resource: OKFResource, title: String? = nil) {
        self.resource = resource
        self.title = title
    }
}

public struct PageOKFMetadata: Equatable, Sendable {
    public let generated: OKFGenerated
    public let sources: [OKFSourceReference]
    public let trust: OKFConceptMetadata

    public init(
        generated: OKFGenerated,
        sources: [OKFSourceReference] = [],
        trust: OKFConceptMetadata = .init()
    ) {
        self.generated = generated
        self.sources = sources
        self.trust = trust
    }
}

public struct SourceOKFMetadata: Equatable, Sendable {
    public let title: String
    public let generated: OKFGenerated
    public let sources: [OKFSourceReference]
    public let trust: OKFConceptMetadata

    public init(
        title: String,
        generated: OKFGenerated,
        sources: [OKFSourceReference],
        trust: OKFConceptMetadata = .init()
    ) {
        self.title = title
        self.generated = generated
        self.sources = sources
        self.trust = trust
    }
}

enum OKFFrontmatter {
    static func concept(
        type: OKFConceptType,
        title: String,
        generated: OKFGenerated,
        sources: [OKFSourceReference],
        trust: OKFConceptMetadata = .init()
    ) -> String {
        var lines = [
            "type: \(yamlString(type.rawValue))",
            "title: \(yamlString(title))",
            "generated:",
            "  by: \(yamlString(generated.by.rawValue))",
            "  at: \(iso8601(generated.at))"
        ]

        let activeVerifications = trust.activeVerifications.sorted {
            ($0.verifiedAt, $0.id.rawValue) < ($1.verifiedAt, $1.id.rawValue)
        }
        if !activeVerifications.isEmpty {
            lines.append("verified:")
            for verification in activeVerifications {
                lines.append("  - by: \(yamlString(verification.by.rawValue))")
                lines.append("    at: \(iso8601(verification.verifiedAt))")
            }
        }
        if let status = trust.status {
            lines.append("status: \(status.rawValue)")
        }
        if let staleAfter = trust.staleAfter {
            lines.append("stale_after: \(iso8601(staleAfter))")
        }

        if !sources.isEmpty {
            lines.append("sources:")
            for source in sources {
                lines.append("  - resource: \(yamlString(source.resource.scalarValue))")
                if let title = source.title {
                    lines.append("    title: \(yamlString(title))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    static func rootIndex(body: String) -> String {
        let stripped = stripLeadingFrontmatter(from: body)
        return """
        ---
        okf_version: "0.2"
        ---

        \(stripped)
        """
    }

    private static func stripLeadingFrontmatter(from body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return body
        }

        var index = 1
        while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces) != "---" {
            index += 1
        }
        if index < lines.count {
            index += 1
        }
        while index < lines.count && lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }
        return lines[index...].joined(separator: "\n")
    }

    private static func yamlString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public enum OKFRootIndexFormat {
    public static func fileContent(body: String) -> String {
        OKFFrontmatter.rootIndex(body: body)
    }
}
