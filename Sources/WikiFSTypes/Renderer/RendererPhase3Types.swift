import Foundation

// pattern: Functional Core

/// Machine-scoped renderer store identity. This is separate from wiki identity
/// and renderer package identity.
public struct RendererMachineScopeID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.isEmpty == false,
              rawValue.count <= 128,
              rawValue.allSatisfy({ character in
                  character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-" || character == "_")
              }) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw RendererValidationError.invalidIdentifier(kind: "renderer machine scope ID", value: rawValue)
        }
        self = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

}

/// Lifecycle state recorded for an immutable renderer package version.
/// A3 persists all cases but deliberately exposes none to the renderer registry.
public enum RendererPackageInstallState: String, Codable, CaseIterable, Hashable, Sendable {
    case unvalidated
    case validated
    case quarantined
    case removed
}

/// A closed, redacted install diagnostic. It has no free-form text by design:
/// machine records must never retain package/source bytes, credentials, paths,
/// or untrusted validator output.
public enum RendererPackageInstallDiagnostic: String, Codable, CaseIterable, Hashable, Sendable {
    case packageValidationFailed
    case packageQuarantined
    case packageRemoved
    case indexConsistencyFailure
}

/// One immutable package-version reservation in the machine index.
public struct RendererPackageInstallRecord: Codable, Hashable, Sendable, Comparable {
    public let packageID: RendererPackageID
    public let version: RendererPackageVersion
    public let expectedPackageHash: RendererSHA256Digest
    public let state: RendererPackageInstallState
    public let reservedAt: RFC3339Timestamp
    public let updatedAt: RFC3339Timestamp
    public let diagnostic: RendererPackageInstallDiagnostic?
    public let rollbackCandidate: RendererPackageVersion?

    public init(
        packageID: RendererPackageID,
        version: RendererPackageVersion,
        expectedPackageHash: RendererSHA256Digest,
        state: RendererPackageInstallState,
        reservedAt: RFC3339Timestamp,
        updatedAt: RFC3339Timestamp,
        diagnostic: RendererPackageInstallDiagnostic? = nil,
        rollbackCandidate: RendererPackageVersion? = nil
    ) throws {
        guard reservedAt <= updatedAt, rollbackCandidate != version else {
            throw RendererValidationError.invalidIdentifier(kind: "renderer package install record", value: "inconsistent record")
        }
        self.packageID = packageID
        self.version = version
        self.expectedPackageHash = expectedPackageHash
        self.state = state
        self.reservedAt = reservedAt
        self.updatedAt = updatedAt
        self.diagnostic = diagnostic
        self.rollbackCandidate = rollbackCandidate
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.packageID, lhs.version) < (rhs.packageID, rhs.version)
    }

    private enum CodingKeys: String, CodingKey {
        case packageID, version, expectedPackageHash, state, reservedAt, updatedAt, diagnostic, rollbackCandidate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            packageID: container.decode(RendererPackageID.self, forKey: .packageID),
            version: container.decode(RendererPackageVersion.self, forKey: .version),
            expectedPackageHash: container.decode(RendererSHA256Digest.self, forKey: .expectedPackageHash),
            state: container.decode(RendererPackageInstallState.self, forKey: .state),
            reservedAt: container.decode(RFC3339Timestamp.self, forKey: .reservedAt),
            updatedAt: container.decode(RFC3339Timestamp.self, forKey: .updatedAt),
            diagnostic: try container.decodeIfPresent(RendererPackageInstallDiagnostic.self, forKey: .diagnostic),
            rollbackCandidate: try container.decodeIfPresent(RendererPackageVersion.self, forKey: .rollbackCandidate)
        )
    }
}

public struct RendererEventSubsystemID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard RendererIdentifierRules.isRegistrationID(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw RendererValidationError.invalidIdentifier(kind: "renderer event subsystem ID", value: rawValue)
        }
        self = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct RendererEventProcessLeaseID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

public struct RendererEventPolicy: Equatable, Sendable {
    public let heartbeatInterval: TimeInterval
    public let leaseExpiry: TimeInterval
    public let clockSkewSafetyMargin: TimeInterval
    public let cleanRetirementSafetyInterval: TimeInterval
    public let lockAcquisitionTimeout: TimeInterval
    public let orderedDrainBatchLimit: Int

    public init(
        heartbeatInterval: TimeInterval,
        leaseExpiry: TimeInterval,
        clockSkewSafetyMargin: TimeInterval,
        cleanRetirementSafetyInterval: TimeInterval,
        lockAcquisitionTimeout: TimeInterval,
        orderedDrainBatchLimit: Int
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.leaseExpiry = leaseExpiry
        self.clockSkewSafetyMargin = clockSkewSafetyMargin
        self.cleanRetirementSafetyInterval = cleanRetirementSafetyInterval
        self.lockAcquisitionTimeout = lockAcquisitionTimeout
        self.orderedDrainBatchLimit = orderedDrainBatchLimit
    }

    public static let phase3Default = RendererEventPolicy(
        heartbeatInterval: 10,
        leaseExpiry: 45,
        clockSkewSafetyMargin: 15,
        cleanRetirementSafetyInterval: 5 * 60,
        lockAcquisitionTimeout: 30,
        orderedDrainBatchLimit: 256
    )
}

/// RFC 3339 timestamp that requires an explicit numeric UTC offset.
public struct RFC3339Timestamp: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isOffsetBearingRFC3339(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw RendererValidationError.invalidIdentifier(kind: "offset-bearing RFC3339 timestamp", value: rawValue)
        }
        self = value
    }

    public init(date: Date, timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        formatter.timeZone = timeZone
        var encoded = formatter.string(from: date)
        if encoded.hasSuffix("Z") {
            encoded.removeLast()
            encoded.append("+00:00")
        }
        self.rawValue = encoded
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Parses a persisted timestamp using the same RFC 3339 variants accepted
    /// at construction. Persistence readers must not substitute a sentinel.
    public func date() throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        if let date = formatter.date(from: rawValue) { return date }
        throw RendererValidationError.invalidIdentifier(kind: "offset-bearing RFC3339 timestamp", value: rawValue)
    }

    private static func isOffsetBearingRFC3339(_ value: String) -> Bool {
        guard value.contains("T"), value.count >= 25 else { return false }
        let suffix = value.suffix(6)
        guard suffix.first == "+" || suffix.first == "-" else { return false }
        let hourStart = suffix.index(after: suffix.startIndex)
        let colon = suffix.index(hourStart, offsetBy: 2)
        guard suffix[colon] == ":" else { return false }
        let hours = suffix[hourStart..<colon]
        let minutes = suffix[suffix.index(after: colon)..<suffix.endIndex]
        guard hours.allSatisfy(\.isNumber), minutes.allSatisfy(\.isNumber) else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.date(from: value) != nil
    }
}

public enum WikiStoreChangeScope: Codable, Hashable, Sendable {
    case wiki(WikiID)
    case machine(RendererMachineScopeID)
}

public struct RendererWikiEnablement: Codable, Hashable, Sendable {
    public let packageID: RendererPackageID
    public let isEnabled: Bool
    public let updatedAt: RFC3339Timestamp

    public init(packageID: RendererPackageID, isEnabled: Bool, updatedAt: RFC3339Timestamp) {
        self.packageID = packageID
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

public struct RendererSourcePreference: Codable, Hashable, Sendable {
    public let sourceID: SourceID
    public let preference: RendererPreferenceReference
    public let updatedAt: RFC3339Timestamp

    public init(sourceID: SourceID, preference: RendererPreferenceReference, updatedAt: RFC3339Timestamp) {
        self.sourceID = sourceID
        self.preference = preference
        self.updatedAt = updatedAt
    }
}

/// The source-reader arrangement selected by a person. This is independent of
/// renderer preference: a source can retain a rendered arrangement while the
/// registry uses its deterministic default renderer choice.
public enum RendererSourcePresentationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case rendered
    case split
}

public struct RendererSourcePresentation: Codable, Hashable, Sendable {
    public let sourceID: SourceID
    public let presentation: RendererSourcePresentationMode
    public let updatedAt: RFC3339Timestamp

    public init(sourceID: SourceID, presentation: RendererSourcePresentationMode, updatedAt: RFC3339Timestamp) {
        self.sourceID = sourceID
        self.presentation = presentation
        self.updatedAt = updatedAt
    }
}

public enum RendererSettingsChangeEvent: Codable, Hashable, Sendable {
    case machineInstallStateChanged(packageID: RendererPackageID, version: RendererPackageVersion)
    case machineSafeModeChanged(isEnabled: Bool)
    case wikiEnablementSet(packageID: RendererPackageID, isEnabled: Bool)
    case sourcePreferenceSet(sourceID: SourceID, preference: RendererPreferenceReference)
    case sourcePreferenceRemoved(sourceID: SourceID)
    case sourcePresentationSet(sourceID: SourceID, presentation: RendererSourcePresentationMode)
    case sourcePresentationRemoved(sourceID: SourceID)
}

/// The versioned body for renderer-settings changes. Version 1 was the
/// unwrapped `RendererSettingsChangeEvent` persisted by Phase 3b; version 2
/// wraps the event so Phase 4 can evolve its payload without changing the
/// shared journal envelope.
public struct PersistedRendererSettingsChangePayload: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let event: RendererSettingsChangeEvent

    fileprivate enum CodingKeys: String, CodingKey {
        case schemaVersion
        case event
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        event: RendererSettingsChangeEvent
    ) throws {
        try Self.validateSchemaVersion(schemaVersion)
        self.schemaVersion = schemaVersion
        self.event = event
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        try Self.validateSchemaVersion(schemaVersion)

        self.schemaVersion = schemaVersion
        self.event = try container.decode(RendererSettingsChangeEvent.self, forKey: .event)
    }

    private static func validateSchemaVersion(_ schemaVersion: Int) throws {
        guard schemaVersion == currentSchemaVersion else {
            throw RendererValidationError.unsupportedManifestRevision(schemaVersion)
        }
    }
}

public enum WikiStoreChangeEvent: Hashable, Sendable {
    case resource(ResourceChangeEvent)
    case rendererSettings(RendererSettingsChangeEvent)
}

extension WikiStoreChangeEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case resource
        case rendererSettings
    }

    private enum AssociatedValueCodingKeys: String, CodingKey {
        case value = "_0"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.resource) {
            let resource = try container.decode(
                AssociatedValue<ResourceChangeEvent>.self,
                forKey: .resource
            )
            self = .resource(resource.value)
            return
        }

        guard container.contains(.rendererSettings) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath, debugDescription: "Unknown wiki store change event.")
            )
        }

        let settingsContainer = try container.nestedContainer(
            keyedBy: AssociatedValueCodingKeys.self,
            forKey: .rendererSettings
        )
        let payloadContainer = try settingsContainer.nestedContainer(
            keyedBy: PersistedRendererSettingsChangePayload.CodingKeys.self,
            forKey: .value
        )

        if payloadContainer.contains(.schemaVersion) {
            let payload = try settingsContainer.decode(
                PersistedRendererSettingsChangePayload.self,
                forKey: .value
            )
            self = .rendererSettings(payload.event)
        } else {
            let legacyEvent = try settingsContainer.decode(
                RendererSettingsChangeEvent.self,
                forKey: .value
            )
            self = .rendererSettings(legacyEvent)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .resource(let resource):
            try container.encode(AssociatedValue(value: resource), forKey: .resource)
        case .rendererSettings(let event):
            let payload = try PersistedRendererSettingsChangePayload(event: event)
            try container.encode(AssociatedValue(value: payload), forKey: .rendererSettings)
        }
    }

    private struct AssociatedValue<Value: Codable>: Codable {
        let value: Value

        private enum CodingKeys: String, CodingKey {
            case value = "_0"
        }
    }
}

public struct PersistedWikiStoreChangeRecord: Codable, Hashable, Sendable {
    /// Version of the shared persisted journal envelope.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let eventID: UUID
    public let sequence: UInt64
    public let scope: WikiStoreChangeScope
    public let payload: WikiStoreChangeEvent
    public let committedAt: RFC3339Timestamp

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case eventID
        case sequence
        case scope
        case payload
        case committedAt
    }

    public init(
        schemaVersion: Int = PersistedWikiStoreChangeRecord.currentSchemaVersion,
        eventID: UUID,
        sequence: UInt64,
        scope: WikiStoreChangeScope,
        payload: WikiStoreChangeEvent,
        committedAt: RFC3339Timestamp
    ) throws {
        try Self.validateSchemaVersion(schemaVersion)
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.sequence = sequence
        self.scope = scope
        self.payload = payload
        self.committedAt = committedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        try Self.validateSchemaVersion(schemaVersion)

        self.schemaVersion = schemaVersion
        self.eventID = try container.decode(UUID.self, forKey: .eventID)
        self.sequence = try container.decode(UInt64.self, forKey: .sequence)
        self.scope = try container.decode(WikiStoreChangeScope.self, forKey: .scope)
        self.payload = try container.decode(WikiStoreChangeEvent.self, forKey: .payload)
        self.committedAt = try container.decode(RFC3339Timestamp.self, forKey: .committedAt)
    }

    private static func validateSchemaVersion(_ schemaVersion: Int) throws {
        guard schemaVersion == currentSchemaVersion else {
            throw RendererValidationError.unsupportedManifestRevision(schemaVersion)
        }
    }
}

public protocol RendererEventIDGenerating: Sendable {
    func nextEventID() -> UUID
}

public struct UUIDRendererEventIDGenerator: RendererEventIDGenerating {
    public init() {}
    public func nextEventID() -> UUID { UUID() }
}

/// Supplies a candidate sequence for a machine journal append. The journal
/// validates it against its durable scoped high-water mark before committing.
public protocol RendererEventSequenceGenerating: Sendable {
    func nextSequence(after: UInt64) -> UInt64
}

public struct DurableRendererEventSequenceGenerator: RendererEventSequenceGenerating {
    public init() {}
    public func nextSequence(after sequence: UInt64) -> UInt64 { sequence + 1 }
}

public protocol RendererEventProcessLeaseIDGenerating: Sendable {
    func nextLeaseID() -> RendererEventProcessLeaseID
}

public struct UUIDRendererEventProcessLeaseIDGenerator: RendererEventProcessLeaseIDGenerating {
    public init() {}
    public func nextLeaseID() -> RendererEventProcessLeaseID { RendererEventProcessLeaseID() }
}

public protocol RendererEventClock: Sendable {
    func now() -> RFC3339Timestamp
}

public struct WallRendererEventClock: RendererEventClock {
    public init() {}
    public func now() -> RFC3339Timestamp { RFC3339Timestamp(date: Date()) }
}
