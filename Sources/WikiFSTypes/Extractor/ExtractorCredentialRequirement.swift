import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

// Extractor credential declarations and durable authorization (issue #1159,
// PR 2 — plans/credential-service.md §"Extractor declarations").
//
// Secrets and `CredentialReference` BINDINGS never appear in manifests or the
// machine package catalog: a manifest only DECLARES that a registration needs
// a credential (id/kind/optionality/label/purpose). The binding of one
// package lineage + requirement to one reference lives exclusively in the
// authorization store, created by explicit user consent.

extension ExtractorHostLimits {
    /// Display label bound for a credential requirement (UTF-8 bytes).
    public static let maximumRequirementLabelByteCount = 64
    /// Bounded purpose text for a credential requirement (UTF-8 bytes).
    public static let maximumRequirementPurposeByteCount = 256
    /// Requirements per registration — host policy keeps the Settings
    /// disclosure and the per-operation envelope bounded.
    public static let maximumRequirementsPerRegistration = 8
}

/// Stable identifier of one credential requirement inside one package
/// lineage. Strict identifier grammar: 1–64 ASCII lowercase alphanumerics and
/// `-`, starting with a letter, not ending with `-` (same machine rules as
/// registration IDs). Package lineage + this ID is the authorization
/// identity (manifest-wide uniqueness is enforced at validation).
public struct ExtractorCredentialRequirementID:
    RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard ExtractorIdentifierRules.isRegistrationID(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw ExtractorValidationError.invalidIdentifier(
                kind: "extractor credential requirement ID", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The closed set of requirement kinds. Initially secret only; a future kind
/// (e.g. an OAuth grant) extends this enum and every boundary that switches
/// over it.
public enum ExtractorCredentialRequirementKind: String, Codable, Sendable, CaseIterable {
    case secret
}

/// One registration-scoped credential declaration. Non-secret by
/// construction: label and purpose are bounded display facts the user
/// consents to, never a value or a binding.
public struct ExtractorCredentialRequirement: Codable, Hashable, Sendable, Comparable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, optional, label, purpose
    }

    public let id: ExtractorCredentialRequirementID
    public let kind: ExtractorCredentialRequirementKind
    /// Optional requirements are omitted when absent or unauthorized;
    /// required ones block preparation (AC.10).
    public let isOptional: Bool
    /// Bounded display label ("Docling Serve API token").
    public let label: String
    /// Bounded purpose text shown before authorization.
    public let purpose: String

    /// Validated + NORMALIZED construction: label and purpose are trimmed;
    /// a declaration that only differs by surrounding whitespace is the same
    /// declaration, and raw JSON that is not already normalized is rejected
    /// at decode so canonical bytes stay deterministic.
    public init(
        id: ExtractorCredentialRequirementID,
        kind: ExtractorCredentialRequirementKind,
        isOptional: Bool,
        label: String,
        purpose: String
    ) throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLabel.isEmpty == false,
              trimmedLabel.utf8.count <= ExtractorHostLimits.maximumRequirementLabelByteCount
        else { throw ExtractorValidationError.invalidManifest("credential requirement label") }
        guard trimmedPurpose.isEmpty == false,
              trimmedPurpose.utf8.count <= ExtractorHostLimits.maximumRequirementPurposeByteCount
        else { throw ExtractorValidationError.invalidManifest("credential requirement purpose") }
        self.id = id
        self.kind = kind
        self.isOptional = isOptional
        self.label = trimmedLabel
        self.purpose = trimmedPurpose
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decode(String.self, forKey: .label)
        let purpose = try container.decode(String.self, forKey: .purpose)
        try self.init(
            id: container.decode(ExtractorCredentialRequirementID.self, forKey: .id),
            kind: container.decode(ExtractorCredentialRequirementKind.self, forKey: .kind),
            isOptional: container.decode(Bool.self, forKey: .optional),
            label: label,
            purpose: purpose)
        // Non-normalized declarations are rejected so a re-encoded canonical
        // manifest can never differ from the reviewed bytes.
        guard label == self.label, purpose == self.purpose else {
            throw ExtractorValidationError.invalidManifest(
                "credential requirement text is not normalized")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(isOptional, forKey: .optional)
        try container.encode(label, forKey: .label)
        try container.encode(purpose, forKey: .purpose)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.id < rhs.id }
}

/// Fingerprint of the NORMALIZED requirement contract in its registration
/// context. Authorization is inherited by a later revision of the same
/// package lineage only while this fingerprint is unchanged; any change to
/// the requirement (id/kind/optionality/label/purpose) or its registration
/// scope (registration identity, kinds, MIME types) requires new
/// authorization (AC.16, plan step 15).
public struct ExtractorCredentialRequirementFingerprint:
    Codable, Hashable, Sendable, Comparable {
    public let value: String

    init(value: String) { self.value = value }

    /// Decoded fingerprints must be exactly 32 bytes of lowercase hex
    /// (SHA-256) — malformed state fails at the persistence boundary instead
    /// of surviving until it happens not to match (PR 2 review, MEDIUM).
    public init(from decoder: any Decoder) throws {
        let value = try String(from: decoder)
        guard value.count == 64,
              value.allSatisfy({ $0.isASCII && (($0.isLetter && $0.isLowercase) || $0.isNumber) })
        else {
            throw ExtractorValidationError.invalidDigest(value)
        }
        self.value = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /// Canonical inputs: package lineage, registration identity + scope, and
    /// the normalized requirement. Deterministic across processes (sorted,
    /// stable field order via sorted-key JSON).
    public static func compute(
        packageID: ExtractorPackageID,
        registration: ExtractorRegistration,
        requirement: ExtractorCredentialRequirement
    ) -> ExtractorCredentialRequirementFingerprint {
        compute(
            packageID: packageID.rawValue,
            registrationID: registration.id.rawValue,
            kinds: registration.kinds.map(\.rawValue),
            mimeTypes: registration.mimeTypes.map(\.rawValue),
            requirement: requirement)
    }

    /// Scope-parts form — the canonical derivation used by every caller so
    /// Settings projections and the authorization writer agree byte-for-byte.
    public static func compute(
        packageID: String,
        registrationID: String,
        kinds: [String],
        mimeTypes: [String],
        requirement: ExtractorCredentialRequirement
    ) -> ExtractorCredentialRequirementFingerprint {
        struct Scope: Encodable {
            let packageID: String
            let registrationID: String
            let kinds: [String]
            let mimeTypes: [String]
            let requirement: ExtractorCredentialRequirement
        }
        let scope = Scope(
            packageID: packageID,
            registrationID: registrationID,
            kinds: kinds.sorted(),
            mimeTypes: mimeTypes.sorted(),
            requirement: requirement)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A scope of validated values always encodes; Data() fallback is the
        // documented degraded output for an impossible failure.
        // swiftlint:disable:next silent_try_optional
        let data = (try? encoder.encode(scope)) ?? Data()
        return ExtractorCredentialRequirementFingerprint(value: sha256Hex(data))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    private static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        #elseif canImport(Crypto)
        let digest = SHA256.hash(data: data)
        #endif
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Durable authorization (machine-scoped, secret-free)

/// The authorization identity: one package lineage + one requirement.
public struct ExtractorCredentialAuthorizationID:
    Codable, Hashable, Sendable, Comparable {
    public let packageID: ExtractorPackageID
    public let requirementID: ExtractorCredentialRequirementID

    public init(
        packageID: ExtractorPackageID,
        requirementID: ExtractorCredentialRequirementID
    ) {
        self.packageID = packageID
        self.requirementID = requirementID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.packageID == rhs.packageID
            ? lhs.requirementID < rhs.requirementID
            : lhs.packageID < rhs.packageID
    }
}

/// One granted binding: lineage + requirement -> credential reference, pinned
/// to the exact declaration fingerprint the user approved. No secret value is
/// ever stored here — only the non-secret reference.
public struct ExtractorCredentialAuthorizationRecord: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, authorizationID, registrationID, fingerprint, credentialReference, authorizedAt
    }

    static let currentSchemaVersion = 1

    public let authorizationID: ExtractorCredentialAuthorizationID
    public let registrationID: ExtractorRegistrationID
    public let fingerprint: ExtractorCredentialRequirementFingerprint
    public let credentialReference: CredentialReference
    public let authorizedAt: Date

    public init(
        authorizationID: ExtractorCredentialAuthorizationID,
        registrationID: ExtractorRegistrationID,
        fingerprint: ExtractorCredentialRequirementFingerprint,
        credentialReference: CredentialReference,
        authorizedAt: Date
    ) {
        self.authorizationID = authorizationID
        self.registrationID = registrationID
        self.fingerprint = fingerprint
        self.credentialReference = credentialReference
        self.authorizedAt = authorizedAt
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ExtractorValidationError.invalidManifest(
                "authorization record schema version \(schemaVersion)")
        }
        try self.init(
            authorizationID: container.decode(
                ExtractorCredentialAuthorizationID.self, forKey: .authorizationID),
            registrationID: container.decode(
                ExtractorRegistrationID.self, forKey: .registrationID),
            fingerprint: container.decode(
                ExtractorCredentialRequirementFingerprint.self, forKey: .fingerprint),
            credentialReference: container.decode(
                CredentialReference.self, forKey: .credentialReference),
            authorizedAt: container.decode(Date.self, forKey: .authorizedAt))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(authorizationID, forKey: .authorizationID)
        try container.encode(registrationID, forKey: .registrationID)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(credentialReference, forKey: .credentialReference)
        try container.encode(authorizedAt, forKey: .authorizedAt)
    }
}

/// The full machine-scoped authorization state. Secret-free; the reference is
/// an identity, not a value. Records are kept sorted for deterministic
/// encoding; `generation` orders concurrent writers.
public struct ExtractorCredentialAuthorizationSnapshot: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, generation, records
    }

    static let currentSchemaVersion = 1

    public let generation: UInt64
    public let records: [ExtractorCredentialAuthorizationRecord]

    public init(generation: UInt64, records: [ExtractorCredentialAuthorizationRecord]) {
        // Duplicate authorization IDs would make `record(for:)` depend on
        // input ordering; a well-formed snapshot can never carry them (PR 2
        // review, MEDIUM).
        let ids = records.map(\.authorizationID)
        precondition(Set(ids).count == ids.count,
                     "duplicate authorization IDs in snapshot")
        self.generation = generation
        self.records = records.sorted { lhs, rhs in
            lhs.authorizationID < rhs.authorizationID
        }
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ExtractorValidationError.invalidManifest(
                "authorization snapshot schema version \(schemaVersion)")
        }
        try self.init(
            generation: container.decode(UInt64.self, forKey: .generation),
            records: container.decode(
                [ExtractorCredentialAuthorizationRecord].self, forKey: .records))
        // Decoding must reject ambiguous duplicate grants rather than letting
        // `record(for:)` pick whichever came first (PR 2 review, MEDIUM).
        let ids = records.map(\.authorizationID)
        guard Set(ids).count == ids.count else {
            throw ExtractorValidationError.invalidManifest(
                "authorization snapshot contains duplicate authorization IDs")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(generation, forKey: .generation)
        try container.encode(records, forKey: .records)
    }

    public func record(
        for authorizationID: ExtractorCredentialAuthorizationID
    ) -> ExtractorCredentialAuthorizationRecord? {
        records.first { $0.authorizationID == authorizationID }
    }

    public static let empty = ExtractorCredentialAuthorizationSnapshot(generation: 0, records: [])
}
