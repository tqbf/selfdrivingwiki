import Foundation
import WikiFSCore

public enum OKFFreshnessInput: Equatable, Sendable {
    case clear
    case fixed(Date)
    case ttl(Duration, anchor: OKFFreshnessAnchor)

    var policy: OKFFreshnessPolicy? {
        get throws {
            switch self {
            case .clear: return nil
            case .fixed(let date): return .fixed(date)
            case .ttl(let duration, let anchor): return try .ttl(duration, anchor: anchor)
            }
        }
    }
}

public struct OKFVerificationInput: Equatable, Sendable {
    public let verifier: OKFVerifierIdentity
    public let verifiedAt: Date
    public let basis: OKFVerificationBasis
    public let freshness: OKFFreshnessInput?

    public init(
        verifier: OKFVerifierIdentity, verifiedAt: Date,
        basis: OKFVerificationBasis, freshness: OKFFreshnessInput? = nil
    ) {
        self.verifier = verifier
        self.verifiedAt = verifiedAt
        self.basis = basis
        self.freshness = freshness
    }
}

public struct OKFCorrectionInput: Equatable, Sendable {
    public let verificationID: OKFVerificationID
    public let verifier: OKFVerifierIdentity
    public let correctedAt: Date
    public let reason: OKFVerificationCorrectionReason?
}

enum OKFCommandSupport {
    static func parseTimestamp(_ rawValue: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: rawValue) else {
            throw ArgumentParser.Failure.usage("invalid ISO-8601 timestamp: \(rawValue)")
        }
        return date
    }

    /// CLI durations use an explicit unit suffix: `30s`, `15m`, `24h`, `7d`.
    static func parseDuration(_ rawValue: String) throws -> Duration {
        guard rawValue.count >= 2, let unit = rawValue.last,
              let amount = Int64(rawValue.dropLast()), amount > 0 else {
            throw ArgumentParser.Failure.usage("duration must be a positive value such as 30s, 15m, 24h, or 7d")
        }
        let multiplier: Int64
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        default:
            throw ArgumentParser.Failure.usage("duration unit must be s, m, h, or d")
        }
        let (seconds, overflow) = amount.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw ArgumentParser.Failure.usage("duration is too large") }
        return .seconds(seconds)
    }

    static func parseEvidence(_ rawValue: String) throws -> OKFEvidenceReference {
        if rawValue.hasPrefix("source:") {
            let id = String(rawValue.dropFirst("source:".count))
            guard !id.isEmpty else { throw ArgumentParser.Failure.usage("source evidence requires a SourceID") }
            return .source(SourceID(rawValue: id))
        }
        if rawValue.hasPrefix("url:") {
            let value = String(rawValue.dropFirst("url:".count))
            guard let url = URL(string: value), let scheme = url.scheme,
                  scheme == "http" || scheme == "https", url.host != nil else {
                throw ArgumentParser.Failure.usage("URL evidence must be an absolute HTTP or HTTPS URL")
            }
            return .external(url)
        }
        throw ArgumentParser.Failure.usage("evidence must use source:<SourceID> or url:<absolute-URL>")
    }

    static func format(
        ownerID: String, versionID: String, metadata: OKFConceptMetadata, json: Bool,
        now: Date = Date()
    ) throws -> String {
        let object: [String: Any] = [
            "owner_id": ownerID,
            "version_id": versionID,
            "status": metadata.status?.rawValue as Any,
            "stale_after": metadata.staleAfter.map(iso8601) as Any,
            "freshness_policy": policyObject(metadata.freshnessPolicy) as Any,
            "trust_tier": metadata.trustTier.rawValue,
            "is_stale": metadata.isStale(at: now) as Any,
            "projection_revision": metadata.projectionRevision,
            "verifications": metadata.verifications.map(verificationObject)
        ]
        if json {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        var lines = [
            "owner_id\t\(ownerID)",
            "version_id\t\(versionID)",
            "status\t\(metadata.status?.rawValue ?? "unset")",
            "trust_tier\t\(metadata.trustTier.rawValue)",
            "stale_after\t\(metadata.staleAfter.map(iso8601) ?? "unset")",
            "is_stale\t\(metadata.isStale(at: now).map(String.init) ?? "unset")",
            "projection_revision\t\(metadata.projectionRevision)"
        ]
        for verification in metadata.verifications {
            lines.append("verification\t\(verification.id.rawValue)\t\(verification.by.rawValue)\t\(iso8601(verification.verifiedAt))\t\(verification.basis.kind.rawValue)\t\(verification.removedAt == nil ? "active" : "corrected")")
        }
        return lines.joined(separator: "\n")
    }

    private static func verificationObject(_ event: OKFVerificationEvent) -> [String: Any] {
        [
            "id": event.id.rawValue,
            "by": event.by.rawValue,
            "at": iso8601(event.verifiedAt),
            "basis": [
                "version": event.basis.version,
                "kind": event.basis.kind.rawValue,
                "evidence": event.basis.evidence.map(evidenceObject),
                "note": event.basis.note as Any
            ],
            "removed_at": event.removedAt.map(iso8601) as Any,
            "correction_reason": event.correctionReason?.reason as Any
        ]
    }

    private static func evidenceObject(_ evidence: OKFEvidenceReference) -> [String: String] {
        switch evidence {
        case .source(let id): return ["type": "source", "value": id.rawValue]
        case .external(let url): return ["type": "external", "value": url.absoluteString]
        }
    }

    private static func policyObject(_ policy: OKFFreshnessPolicy?) -> Any? {
        guard let policy else { return nil }
        switch policy {
        case .fixed(let date):
            return ["kind": "fixed", "stale_after": iso8601(date)]
        case .ttl(let seconds, let anchor):
            var value: [String: Any] = ["kind": "ttl", "seconds": seconds]
            switch anchor {
            case .generated: value["anchor"] = "generated"
            case .verification(let id):
                value["anchor"] = "verification"
                value["verification_id"] = id.rawValue
            case .recordedVerification: value["anchor"] = "recorded-verification"
            }
            return value
        }
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
