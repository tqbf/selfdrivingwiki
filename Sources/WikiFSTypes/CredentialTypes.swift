import Foundation

// Domain-neutral credential identity and service contracts (issue #1159,
// plans/credential-service.md). These types live in `WikiFSTypes` so every
// layer (app, daemon, engine, CLI) shares ONE vocabulary for "which secret"
// without ever carrying the secret itself.
//
// The split this file encodes:
// - `CredentialReference` — the stable CONFIGURATION identity of a credential
//   (what Settings, catalogs, and authorization records store);
// - `CredentialInfo` — the UI-SAFE description of a credential (configured
//   state, source, writability) — no value surface;
// - `ResolvedCredential` — the PRIVILEGED value container, for trusted host
//   runtime code only (spawn preparation, client construction);
// - `CredentialWriting` — write-only mutation; values travel INTO the service
//   and never back out.
//
// There is deliberately NO reference-enumeration API: hosts supply the
// references they know about (typed factories, host catalogs, Settings
// schemas). See `plans/credential-service.md` §"No enumeration".

// MARK: - Reference

/// Validation failures for credential identity construction. `value` fields
/// carry only the rejected COMPONENT (a label or a raw dotted string) — never
/// a secret value; references are non-secret identifiers by construction.
public enum CredentialReferenceError: Error, Equatable, Sendable {
    case invalidLabel(component: String)
    case invalidStructure(rawValue: String)
}

/// A credential's stable, validated configuration identity — two or three
/// dot-separated labels such as `acp.agent-api-key`,
/// `acp.provider.claude-acp`, or `provider.claude-acp.anthropic-api-key`.
///
/// # Grammar (normative)
///
/// A reference is 2–3 **labels** joined by `.` (U+002E):
/// - a label is 1–64 characters of ASCII letters, digits, `_`, or `-`;
/// - a label starts and ends with an ASCII letter or digit;
/// - the whole reference is ≤ 132 characters.
///
/// The grammar is deliberately wider than kebab-case so dynamic domains can
/// embed existing identifiers verbatim (e.g. a user-chosen `ProviderID` such
/// as `my_agent`) while staying injective: `A.B` and `A_B` are distinct
/// labels, and no label can contain `.`, so the split is unambiguous.
///
/// # Typed factories over unchecked strings
///
/// Call sites do NOT concatenate raw strings into references. Dynamic domains
/// go through validated factories — `acpProvider(_:)` for provider-scoped ACP
/// keys, and (in `WikiFSCore`) `ProviderSecretEnvironmentVariable`-scoped
/// factories for provider environment secrets. A factory returns `nil` for a
/// component that cannot form a valid label, and the caller decides the
/// fallback (adapters keep their legacy physical path for such ids).
///
/// `Codable` encodes the joined `rawValue` string — that wire shape is a
/// compatibility surface for authorization records (PR 2) and future stores.
/// `Comparable` orders by `rawValue` so snapshots and stores can be
/// deterministic without exposing insertion order.
public struct CredentialReference:
    Hashable, Codable, Comparable, Sendable, CustomStringConvertible {

    /// The validated, dot-joined identity (e.g. `"acp.agent-api-key"`).
    public let rawValue: String

    /// The individual validated labels (e.g. `["acp", "agent-api-key"]`).
    public var labels: [String] { rawValue.split(separator: ".").map(String.init) }

    /// The first label — the reference's namespace (e.g. `"acp"`).
    public var domain: String { labels[0] }

    /// Validates and builds a reference from raw text. The ONLY general
    /// constructor; every other initializer routes through here.
    public init(validating rawValue: String) throws {
        let labels = rawValue.split(
            separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= Self.minimumLabelCount,
              labels.count <= Self.maximumLabelCount,
              labels.allSatisfy(Self.isValidLabel),
              rawValue.count <= Self.maximumRawValueLength
        else { throw CredentialReferenceError.invalidStructure(rawValue: rawValue) }
        self.rawValue = rawValue
    }

    /// Builds a reference from already-validated components. Internal so
    /// factories cannot bypass validation, while staying allocation-cheap.
    init(validatedLabels: [String]) {
        precondition(validatedLabels.count >= Self.minimumLabelCount
                     && validatedLabels.count <= Self.maximumLabelCount,
                     "validatedLabels must carry 2–3 labels")
        precondition(validatedLabels.allSatisfy(Self.isValidLabel),
                     "validatedLabels must already satisfy the label grammar")
        self.rawValue = validatedLabels.joined(separator: ".")
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        try self.init(validating: String(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: Label grammar

    static let minimumLabelCount = 2
    static let maximumLabelCount = 3
    static let maximumRawValueLength = 132
    static let maximumLabelLength = 64

    /// One validated label: 1–64 ASCII alphanumerics, `_`, or `-`; starts and
    /// ends with an ASCII letter or digit; contains at least one of them.
    public static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= maximumLabelLength,
              let first = label.first, first.isASCII,
              let last = label.last, last.isASCII,
              first.isLetter || first.isNumber,
              last.isLetter || last.isNumber,
              label.contains(where: { $0.isLetter || $0.isNumber })
        else { return false }
        return label.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "_" || character == "-"
        }
    }

    /// Returns a reference built by joining validated labels, or `nil` when
    /// any component fails the grammar — the failable shape typed factories
    /// expose for dynamic domains.
    public init?(validatingLabels labels: [String]) {
        guard labels.count >= Self.minimumLabelCount,
              labels.count <= Self.maximumLabelCount,
              labels.allSatisfy(Self.isValidLabel),
              labels.joined(separator: ".").count <= Self.maximumRawValueLength
        else { return nil }
        self.rawValue = labels.joined(separator: ".")
    }
}

// MARK: - Source and description

/// The closed set of physical credential sources. Initially Keychain only;
/// future sources (a synced vault, a hardware token) extend this enum rather
/// than growing per-domain service APIs.
public enum CredentialSource: String, Codable, Sendable, CaseIterable {
    case keychain
}

/// The UI-safe description of one credential: whether it is configured, where
/// it lives, and whether the current process may write it. **No value field
/// exists** — Settings and inspection snapshots render this type directly, so
/// a secret cannot leak through a description API.
public struct CredentialInfo: Hashable, Sendable, CustomStringConvertible {
    public let reference: CredentialReference
    public let isConfigured: Bool
    public let source: CredentialSource
    public let isWritable: Bool

    public init(
        reference: CredentialReference,
        isConfigured: Bool,
        source: CredentialSource,
        isWritable: Bool
    ) {
        self.reference = reference
        self.isConfigured = isConfigured
        self.source = source
        self.isWritable = isWritable
    }

    public var description: String {
        let state = isConfigured ? "configured" : "not configured"
        return "CredentialInfo(\(reference.rawValue): \(state), \(source.rawValue))"
    }
}

// MARK: - Privileged value container

/// A resolved secret value plus its source. PRIVILEGED: only trusted host
/// runtime code (spawn preparation, client construction, the migration)
/// handles this type. Its descriptions are redacted so an accidental
/// interpolation or log line can never carry the value.
public struct ResolvedCredential: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let reference: CredentialReference
    /// The secret value. Never rendered by `description`/`debugDescription`.
    public let value: String
    public let source: CredentialSource

    public init(reference: CredentialReference, value: String, source: CredentialSource) {
        self.reference = reference
        self.value = value
        self.source = source
    }

    public var description: String {
        "ResolvedCredential(\(reference.rawValue): <redacted>)"
    }

    public var debugDescription: String { description }
}

// MARK: - Errors

/// Bounded service failures. Every case is value-free: errors name the
/// operation and the underlying OS status (an integer), never the secret.
public enum CredentialStoreError: Error, Equatable, Sendable,
    CustomStringConvertible {
    /// `resolve` of a reference with no configured value.
    case notConfigured(CredentialReference)
    /// A Keychain read failed. `status` is the raw `OSStatus`.
    case readFailed(operation: String, status: Int32)
    /// A Keychain write or delete failed. `status` is the raw `OSStatus`.
    case writeFailed(operation: String, status: Int32)
    /// The source rejects mutation (e.g. a read-only future source).
    case notWritable(CredentialReference)

    public var description: String {
        switch self {
        case .notConfigured(let reference):
            return "credential not configured: \(reference.rawValue)"
        case .readFailed(let operation, let status):
            return "credential read failed (\(operation), status \(status))"
        case .writeFailed(let operation, let status):
            return "credential write failed (\(operation), status \(status))"
        case .notWritable(let reference):
            return "credential is not writable: \(reference.rawValue)"
        }
    }
}

// MARK: - Value normalization

/// The ONE named boundary deciding whether a write carries a value. `nil`,
/// empty, and whitespace-only input all normalize to `nil` (= absence → the
/// service unsets). A real value is preserved byte-for-byte — the service
/// never trims a secret.
public enum CredentialValue {
    public static func normalized(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}

// MARK: - Service protocols

/// UI-safe credential description. Settings views, snapshots, and host
/// catalogs conform to (or call) THIS protocol — it has no method that can
/// return a secret value.
public protocol CredentialDescribing: Sendable {
    /// Describe one reference. A missing item describes as not-configured;
    /// this never throws.
    func describe(_ reference: CredentialReference) -> CredentialInfo

    /// Describe a bounded batch. The host caps batch sizes; exceeding the
    /// cap truncates the result rather than ballooning Keychain traffic.
    func describe(_ references: [CredentialReference]) -> [CredentialReference: CredentialInfo]

    /// The largest batch `describe([:])` will answer.
    var maximumDescribeBatchSize: Int { get }
}

/// Write-only credential mutation. Values travel INTO the conformer only —
/// there is no read shape on this protocol, so a Settings-facing handle can
/// accept saves without being able to echo a secret back.
public protocol CredentialWriting: Sendable {
    /// Store `value` for `reference`. `nil`, empty, and whitespace-only
    /// values normalize to unset (see `CredentialValue`) through exactly one
    /// boundary — callers cannot store an empty secret.
    func set(_ value: String?, for reference: CredentialReference) throws

    /// Remove the credential. Removing an absent credential succeeds.
    func unset(_ reference: CredentialReference) throws
}

/// Privileged value resolution. Trusted host runtime code only — never
/// exposed to Settings views, package scripts, the File Provider, or XPC.
public protocol CredentialResolving: Sendable {
    /// Resolve the configured value. Throws `.notConfigured` when absent —
    /// `resolve` never returns an empty value.
    func resolve(_ reference: CredentialReference) throws -> ResolvedCredential
}

/// The full host-side service surface. Production conformers are the
/// Keychain-backed service and the in-memory test service.
public typealias CredentialService = CredentialDescribing & CredentialWriting & CredentialResolving
