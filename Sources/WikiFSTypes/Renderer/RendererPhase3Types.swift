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

public enum WikiStoreChangeEvent: Codable, Hashable, Sendable {
    case resource(ResourceChangeEvent)
    case rendererSettings(RendererSettingsChangeEvent)
}

public struct PersistedWikiStoreChangeRecord: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID
    public let sequence: UInt64
    public let scope: WikiStoreChangeScope
    public let payload: WikiStoreChangeEvent
    public let committedAt: RFC3339Timestamp

    public init(
        schemaVersion: Int = 1,
        eventID: UUID,
        sequence: UInt64,
        scope: WikiStoreChangeScope,
        payload: WikiStoreChangeEvent,
        committedAt: RFC3339Timestamp
    ) throws {
        guard schemaVersion == 1 else {
            throw RendererValidationError.unsupportedManifestRevision(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.sequence = sequence
        self.scope = scope
        self.payload = payload
        self.committedAt = committedAt
    }
}

public protocol RendererEventIDGenerating: Sendable {
    func nextEventID() -> UUID
}

public struct UUIDRendererEventIDGenerator: RendererEventIDGenerating {
    public init() {}
    public func nextEventID() -> UUID { UUID() }
}

public protocol RendererEventClock: Sendable {
    func now() -> RFC3339Timestamp
}

public struct WallRendererEventClock: RendererEventClock {
    public init() {}
    public func now() -> RFC3339Timestamp { RFC3339Timestamp(date: Date()) }
}
