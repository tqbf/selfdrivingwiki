import Foundation

/// One bounded, redacted package-admission diagnostic.
public struct ExtractorPackageAdmissionDiagnostic: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey { case message }
    public static let maximumMessageByteCount = 512

    public let message: String

    public init(message: String) throws {
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false,
              value.utf8.count <= Self.maximumMessageByteCount,
              value.contains("/") == false,
              value.contains("\\") == false else {
            throw ExtractorPackageCatalogError.invalidDiagnostic
        }
        self.message = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(message: container.decode(String.self, forKey: .message))
    }
}

/// Durable metadata for one exact immutable package revision.
public struct ExtractorPackageCatalogRecord: Codable, Hashable, Sendable, Comparable {
    private enum CodingKeys: String, CodingKey {
        case revision, displayName, protocolRevision, launch, registrations
        case capabilities, installedAt, admissionDiagnostics
    }

    public static let maximumDiagnosticCount = 16

    public let revision: ExtractorPackageRevisionID
    public let displayName: String
    public let protocolRevision: ExtractorProtocolRevision
    public let launch: ExtractorLaunch
    public let registrations: [ExtractorRegistration]
    public let capabilities: Set<ExtractorCapability>
    public let installedAt: RFC3339Timestamp
    public let admissionDiagnostics: [ExtractorPackageAdmissionDiagnostic]

    public init(
        revision: ExtractorPackageRevisionID,
        displayName: String,
        protocolRevision: ExtractorProtocolRevision,
        launch: ExtractorLaunch,
        registrations: [ExtractorRegistration],
        capabilities: Set<ExtractorCapability>,
        installedAt: RFC3339Timestamp,
        admissionDiagnostics: [ExtractorPackageAdmissionDiagnostic] = []
    ) throws {
        guard displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              displayName.utf8.count <= 128 else {
            throw ExtractorPackageCatalogError.invalidRecord
        }
        guard registrations.isEmpty == false,
              Set(registrations.map(\.id)).count == registrations.count,
              admissionDiagnostics.count <= Self.maximumDiagnosticCount else {
            throw ExtractorPackageCatalogError.invalidRecord
        }
        self.revision = revision
        self.displayName = displayName
        self.protocolRevision = protocolRevision
        self.launch = launch
        self.registrations = registrations.sorted()
        self.capabilities = capabilities
        self.installedAt = installedAt
        self.admissionDiagnostics = admissionDiagnostics
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capabilities = try container.decode([ExtractorCapability].self, forKey: .capabilities)
        guard Set(capabilities).count == capabilities.count else {
            throw ExtractorPackageCatalogError.invalidRecord
        }
        // Registrations decode under the record's own protocol revision: a
        // v2 registration carries credential declarations that the plain v1
        // decoder rejects, which made the whole catalog unreadable.
        let protocolRevision = try container.decode(
            ExtractorProtocolRevision.self, forKey: .protocolRevision)
        guard let manifestRevision = ExtractorManifestRevision(rawValue: protocolRevision.rawValue) else {
            throw ExtractorValidationError.invalidRevision(protocolRevision.rawValue)
        }
        var registrationContainer = try container.nestedUnkeyedContainer(forKey: .registrations)
        let registrations = try ExtractorRegistration.decodeArray(
            from: &registrationContainer, manifestRevision: manifestRevision)
        try self.init(
            revision: container.decode(ExtractorPackageRevisionID.self, forKey: .revision),
            displayName: container.decode(String.self, forKey: .displayName),
            protocolRevision: protocolRevision,
            launch: container.decode(ExtractorLaunch.self, forKey: .launch),
            registrations: registrations,
            capabilities: Set(capabilities),
            installedAt: container.decode(RFC3339Timestamp.self, forKey: .installedAt),
            admissionDiagnostics: container.decodeIfPresent(
                [ExtractorPackageAdmissionDiagnostic].self,
                forKey: .admissionDiagnostics) ?? [])
    }

    public init(validatedManifest: ExtractorManifest, revision: ExtractorPackageRevisionID, installedAt: RFC3339Timestamp) throws {
        guard validatedManifest.packageID == revision.packageID,
              validatedManifest.version == revision.version,
              try validatedManifest.packageDigest() == revision.digest else {
            throw ExtractorPackageCatalogError.invalidRecord
        }
        try self.init(
            revision: revision,
            displayName: validatedManifest.displayName,
            protocolRevision: validatedManifest.protocolRevision,
            launch: validatedManifest.launch,
            registrations: validatedManifest.registrations,
            capabilities: validatedManifest.capabilities,
            installedAt: installedAt)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.revision < rhs.revision }
}

/// Versioned machine-scoped catalog. Readers observe one complete generation.
public struct ExtractorPackageCatalog: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, generation, records, reservations }

    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generation: UInt64
    public let records: [ExtractorPackageCatalogRecord]
    public let reservations: [ExtractorPackageReservationRecord]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generation: UInt64 = 0,
        records: [ExtractorPackageCatalogRecord] = [],
        reservations: [ExtractorPackageReservationRecord] = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ExtractorPackageCatalogError.unsupportedSchemaVersion
        }
        let records = records.sorted()
        var revisions: Set<ExtractorPackageRevisionID> = []
        var reservationDigests: [ExtractorPackageReservation: ExtractorPackageDigest] = [:]
        for reservationRecord in reservations {
            if let digest = reservationDigests[reservationRecord.reservation] {
                guard digest == reservationRecord.digest else {
                    throw ExtractorPackageCatalogError.conflictingRevision
                }
                throw ExtractorPackageCatalogError.duplicateReservation
            }
            reservationDigests[reservationRecord.reservation] = reservationRecord.digest
        }
        for record in records {
            guard revisions.insert(record.revision).inserted else {
                throw ExtractorPackageCatalogError.duplicateRevision
            }
            let reservation = ExtractorPackageReservation(
                packageID: record.revision.packageID,
                version: record.revision.version)
            if let digest = reservationDigests[reservation], digest != record.revision.digest {
                throw ExtractorPackageCatalogError.conflictingRevision
            }
            reservationDigests[reservation] = record.revision.digest
        }
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.records = records
        self.reservations = reservationDigests.map {
            ExtractorPackageReservationRecord(reservation: $0.key, digest: $0.value)
        }.sorted()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            generation: container.decode(UInt64.self, forKey: .generation),
            records: container.decode([ExtractorPackageCatalogRecord].self, forKey: .records),
            reservations: container.decodeIfPresent(
                [ExtractorPackageReservationRecord].self,
                forKey: .reservations) ?? [])
    }

    public func replacing(records: [ExtractorPackageCatalogRecord]) throws -> Self {
        guard generation < UInt64.max else {
            throw ExtractorPackageCatalogError.generationOverflow
        }
        return try Self(
            generation: generation + 1,
            records: records,
            reservations: reservations)
    }
}

/// Durable digest reservation for one package and version identity.
public struct ExtractorPackageReservationRecord: Codable, Hashable, Sendable, Comparable {
    public let reservation: ExtractorPackageReservation
    public let digest: ExtractorPackageDigest

    public init(reservation: ExtractorPackageReservation, digest: ExtractorPackageDigest) {
        self.reservation = reservation
        self.digest = digest
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.reservation != rhs.reservation { return lhs.reservation < rhs.reservation }
        return lhs.digest < rhs.digest
    }
}

/// Package and version reservation. The exact revision also contains a digest.
public struct ExtractorPackageReservation: Codable, Hashable, Sendable, Comparable {
    public let packageID: ExtractorPackageID
    public let version: ExtractorPackageVersion

    public init(packageID: ExtractorPackageID, version: ExtractorPackageVersion) {
        self.packageID = packageID
        self.version = version
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.packageID != rhs.packageID { return lhs.packageID < rhs.packageID }
        return lhs.version < rhs.version
    }
}

public enum ExtractorPackageCatalogError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion
    case duplicateRevision
    case duplicateReservation
    case conflictingRevision
    case invalidRecord
    case invalidDiagnostic
    case generationOverflow
}
