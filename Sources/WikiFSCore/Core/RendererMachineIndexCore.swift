import Foundation

// pattern: Functional Core

/// Versioned, machine-only package index. SQLite stores this value authoritatively;
/// `derived/index.json` is a regenerated projection of the same validated value.
public struct RendererMachineIndex: Codable, Equatable, Sendable {
    /// Version 3 adds persisted installed-renderer failure accounting.
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let generation: UInt64
    public let records: [RendererPackageInstallRecord]
    public let safeModeIsEnabled: Bool
    public let installedRendererFailures: [RendererInstalledRendererFailure]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generation: UInt64 = 0,
        records: [RendererPackageInstallRecord] = [],
        safeModeIsEnabled: Bool = false,
        installedRendererFailures: [RendererInstalledRendererFailure] = []
    ) throws {
        self.schemaVersion = schemaVersion
        self.generation = generation
        // Schema v2 persisted one machine-wide safe-mode bit. Preserve that
        // fail-closed state while moving its effect into the per-version
        // suppression field used by the current projection.
        self.records = try records.map { record in
            guard safeModeIsEnabled, record.state == .validated, record.isSafeModeSuppressed == false else {
                return record
            }
            return try RendererPackageInstallRecord(
                packageID: record.packageID,
                version: record.version,
                expectedPackageHash: record.expectedPackageHash,
                state: record.state,
                reservedAt: record.reservedAt,
                updatedAt: record.updatedAt,
                diagnostic: record.diagnostic,
                rollbackCandidate: record.rollbackCandidate,
                isSafeModeSuppressed: true,
                validatedDescriptors: record.validatedDescriptors
            )
        }.sorted()
        self.safeModeIsEnabled = safeModeIsEnabled
        self.installedRendererFailures = installedRendererFailures
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generation, records, safeModeIsEnabled, installedRendererFailures
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 2 || schemaVersion == Self.currentSchemaVersion else {
            throw RendererMachineIndexStoreError.unsupportedSchemaVersion
        }
        try self.init(
            schemaVersion: Self.currentSchemaVersion,
            generation: container.decode(UInt64.self, forKey: .generation),
            records: container.decode([RendererPackageInstallRecord].self, forKey: .records),
            safeModeIsEnabled: container.decode(Bool.self, forKey: .safeModeIsEnabled),
            installedRendererFailures: try container.decodeIfPresent([RendererInstalledRendererFailure].self, forKey: .installedRendererFailures) ?? []
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RendererMachineIndexStoreError.unsupportedSchemaVersion
        }
        var reservations: [RendererPackageReservation: RendererSHA256Digest] = [:]
        for record in records {
            let key = RendererPackageReservation(packageID: record.packageID, version: record.version)
            if let existingHash = reservations[key], existingHash != record.expectedPackageHash {
                throw RendererMachineIndexStoreError.conflictingExpectedHash
            }
            guard reservations[key] == nil else {
                throw RendererMachineIndexStoreError.duplicatePackageVersion
            }
            reservations[key] = record.expectedPackageHash
        }
    }

    /// Only activated, validator-produced records can enter an installed
    /// registry. Safe-mode suppression is scoped to each exact installed
    /// package/version. Built-ins and Source are outside it.
    public var availableDescriptorProjection: [RendererDescriptor] {
        return records
            .filter { $0.state == .validated && $0.isSafeModeSuppressed == false }
            .flatMap(\.validatedDescriptors)
            .sorted { $0.reference < $1.reference }
    }

    func replacing(
        records: [RendererPackageInstallRecord],
        safeModeIsEnabled: Bool,
        installedRendererFailures: [RendererInstalledRendererFailure]? = nil
    ) throws -> Self {
        try Self(generation: generation + 1, records: records, safeModeIsEnabled: safeModeIsEnabled, installedRendererFailures: installedRendererFailures ?? self.installedRendererFailures)
    }
}

public struct RendererPackageReservation: Hashable, Sendable {
    public let packageID: RendererPackageID
    public let version: RendererPackageVersion

    public init(packageID: RendererPackageID, version: RendererPackageVersion) {
        self.packageID = packageID
        self.version = version
    }
}

/// Redacted error vocabulary for machine-index input and persistence failures.
/// No case carries payload data, absolute paths, credentials, or source content.
public enum RendererMachineIndexStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion
    case staleGeneration
    case conflictingExpectedHash
    case duplicatePackageVersion
    case invalidPackagePath
    case corruptIndex
    case sqliteFailure
    case derivedIndexReplacementFailed
    case activationFailed
    case activationCleanupFailed
    case activationCancelled
    case packageRemovalFailed
    case packageRootAlreadyExists
    case installedRendererNotAvailable
}

func rendererMachineIndexValidatingPackagePaths(
    _ index: RendererMachineIndex,
    layout: RendererPackageStoreLayout
) throws {
    try index.validate()
    if FileManager.default.fileExists(atPath: layout.packagesRoot.path),
       isRendererPackageStorePathContained(layout.packagesRoot, within: layout.root) == false {
        throw RendererMachineIndexStoreError.invalidPackagePath
    }
    for record in index.records {
        // A removed tombstone intentionally has no live payload. Its typed
        // package/version identity remains bounded by the value types, while
        // live reservations still require an in-root package location.
        guard record.state != .removed else { continue }
        let packageURL = layout.packageURL(packageID: record.packageID, version: record.version)
        guard isRendererPackageStorePathContained(packageURL, within: layout.packagesRoot) else {
            throw RendererMachineIndexStoreError.invalidPackagePath
        }
    }
}

func rendererMachineIndexApplying(
    _ index: RendererMachineIndex,
    expectedGeneration: UInt64,
    mutation: (inout [RendererPackageInstallRecord], inout Bool) throws -> Void
) throws -> RendererMachineIndex {
    guard index.generation == expectedGeneration else {
        throw RendererMachineIndexStoreError.staleGeneration
    }
    var records = index.records
    var safeModeIsEnabled = index.safeModeIsEnabled
    try mutation(&records, &safeModeIsEnabled)
    return try index.replacing(records: records, safeModeIsEnabled: safeModeIsEnabled)
}

func rendererMachineIndexRecordingInstalledRendererFailure(
    _ index: RendererMachineIndex,
    packageID: RendererPackageID,
    version: RendererPackageVersion,
    cause: RendererInstalledRendererFailureCause,
    expectedGeneration: UInt64,
    now: RFC3339Timestamp
) throws -> (index: RendererMachineIndex, window: RendererInstalledRendererFailureWindow) {
    guard index.generation == expectedGeneration else {
        throw RendererMachineIndexStoreError.staleGeneration
    }
    let reservation = RendererPackageReservation(packageID: packageID, version: version)
    guard index.records.contains(where: {
        $0.state == .validated && RendererPackageReservation(packageID: $0.packageID, version: $0.version) == reservation
    }) else {
        throw RendererMachineIndexStoreError.installedRendererNotAvailable
    }
    let failures = try rendererInstalledRendererFailuresPruned(index.installedRendererFailures, now: now.date())
        + [.init(packageID: packageID, version: version, cause: cause, occurredAt: now)]
    let window = rendererInstalledRendererFailureWindow(failures, reservation: reservation)
    let nextRecords: [RendererPackageInstallRecord]
    if window.hasReachedThreshold {
        nextRecords = try index.records.map { record in
            guard record.packageID == packageID, record.version == version, record.isSafeModeSuppressed == false else {
                return record
            }
            return try RendererPackageInstallRecord(
                packageID: record.packageID,
                version: record.version,
                expectedPackageHash: record.expectedPackageHash,
                state: record.state,
                reservedAt: record.reservedAt,
                updatedAt: record.updatedAt,
                diagnostic: record.diagnostic,
                rollbackCandidate: record.rollbackCandidate,
                isSafeModeSuppressed: true,
                validatedDescriptors: record.validatedDescriptors
            )
        }
    } else {
        nextRecords = index.records
    }
    let next = try index.replacing(records: nextRecords, safeModeIsEnabled: false, installedRendererFailures: failures)
    return (next, window)
}

func rendererMachineIndexResettingInstalledRendererSafeMode(
    _ index: RendererMachineIndex,
    packageID: RendererPackageID,
    version: RendererPackageVersion,
    expectedGeneration: UInt64
) throws -> RendererMachineIndex {
    guard index.generation == expectedGeneration else {
        throw RendererMachineIndexStoreError.staleGeneration
    }
    let reservation = RendererPackageReservation(packageID: packageID, version: version)
    guard index.records.contains(where: { RendererPackageReservation(packageID: $0.packageID, version: $0.version) == reservation }) else {
        throw RendererMachineIndexStoreError.installedRendererNotAvailable
    }
    let records = try index.records.map { record -> RendererPackageInstallRecord in
        guard RendererPackageReservation(packageID: record.packageID, version: record.version) == reservation,
              record.isSafeModeSuppressed else { return record }
        return try RendererPackageInstallRecord(
            packageID: record.packageID,
            version: record.version,
            expectedPackageHash: record.expectedPackageHash,
            state: record.state,
            reservedAt: record.reservedAt,
            updatedAt: record.updatedAt,
            diagnostic: record.diagnostic,
            rollbackCandidate: record.rollbackCandidate,
            isSafeModeSuppressed: false,
            validatedDescriptors: record.validatedDescriptors
        )
    }
    let failures = index.installedRendererFailures.filter { $0.reservation != reservation }
    return try index.replacing(records: records, safeModeIsEnabled: false, installedRendererFailures: failures)
}

func rendererMachineIndexResettingInstalledRendererSafeMode(
    _ index: RendererMachineIndex,
    expectedGeneration: UInt64
) throws -> RendererMachineIndex {
    guard index.generation == expectedGeneration else {
        throw RendererMachineIndexStoreError.staleGeneration
    }
    let records = try index.records.map { record -> RendererPackageInstallRecord in
        guard record.isSafeModeSuppressed else { return record }
        return try RendererPackageInstallRecord(
            packageID: record.packageID,
            version: record.version,
            expectedPackageHash: record.expectedPackageHash,
            state: record.state,
            reservedAt: record.reservedAt,
            updatedAt: record.updatedAt,
            diagnostic: record.diagnostic,
            rollbackCandidate: record.rollbackCandidate,
            isSafeModeSuppressed: false,
            validatedDescriptors: record.validatedDescriptors
        )
    }
    return try index.replacing(records: records, safeModeIsEnabled: false, installedRendererFailures: [])
}
