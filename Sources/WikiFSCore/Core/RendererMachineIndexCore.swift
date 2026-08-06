import Foundation

// pattern: Functional Core

/// Versioned, machine-only package index. SQLite stores this value authoritatively;
/// `derived/index.json` is a regenerated projection of the same validated value.
public struct RendererMachineIndex: Codable, Equatable, Sendable {
    /// Version 2 adds validator-produced descriptors to validated records.
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let generation: UInt64
    public let records: [RendererPackageInstallRecord]
    public let safeModeIsEnabled: Bool

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generation: UInt64 = 0,
        records: [RendererPackageInstallRecord] = [],
        safeModeIsEnabled: Bool = false
    ) throws {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.records = records.sorted()
        self.safeModeIsEnabled = safeModeIsEnabled
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generation, records, safeModeIsEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            generation: container.decode(UInt64.self, forKey: .generation),
            records: container.decode([RendererPackageInstallRecord].self, forKey: .records),
            safeModeIsEnabled: container.decode(Bool.self, forKey: .safeModeIsEnabled)
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
    /// registry. Safe mode is a machine-wide kill switch for installed code;
    /// built-ins and the Source fallback are deliberately outside this value.
    public var availableDescriptorProjection: [RendererDescriptor] {
        guard safeModeIsEnabled == false else { return [] }
        return records
            .filter { $0.state == .validated }
            .flatMap(\.validatedDescriptors)
            .sorted { $0.reference < $1.reference }
    }

    func replacing(records: [RendererPackageInstallRecord], safeModeIsEnabled: Bool) throws -> Self {
        try Self(generation: generation + 1, records: records, safeModeIsEnabled: safeModeIsEnabled)
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
    case packageRootAlreadyExists
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
