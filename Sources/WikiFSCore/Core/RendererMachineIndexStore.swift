import Foundation
import CRendererPackageMove
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif

private let rendererMachineIndexSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// pattern: Imperative Shell

/// Small replacement seam used to prove that a failed derived write leaves the
/// last valid JSON in place. The production writer stages in the destination
/// directory, then replaces/moves only after the staged bytes are durable.
public protocol RendererMachineDerivedIndexWriting: Sendable {
    func replaceAtomically(_ data: Data, at url: URL) throws
}

public struct FileRendererMachineDerivedIndexWriter: RendererMachineDerivedIndexWriting {
    public init() {}

    public func replaceAtomically(_ data: Data, at url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".index-\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try data.write(to: temporary, options: [.atomic])
            let result = temporary.path.withCString { temporaryPath in
                url.path.withCString { destinationPath in
                    rendererMachineIndexRename(temporaryPath, destinationPath)
                }
            }
            guard result == 0 else {
                throw RendererPackageStoreError.posix(operation: "rename", path: url.path, code: errno)
            }
        } catch {
            DebugLog.store("Renderer machine derived-index replacement failed: \(error)")
            if fileManager.fileExists(atPath: temporary.path) {
                do { try fileManager.removeItem(at: temporary) }
                catch { DebugLog.store("Renderer machine derived-index temporary cleanup failed.") }
            }
            throw error
        }
    }
}

/// Cleanup is injected so activation tests can prove that an abandoned staged
/// tree never becomes an installed record when removal fails.
public protocol RendererPackageActivationCleaning: Sendable {
    func removeRecursively(_ url: URL) throws
}

public struct FileRendererPackageActivationCleaner: RendererPackageActivationCleaning {
    public init() {}

    public func removeRecursively(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

private func rendererMachineIndexRename(_ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>) -> Int32 {
    #if canImport(Darwin)
    return Darwin.rename(source, destination)
    #elseif canImport(Glibc)
    return Glibc.rename(source, destination)
    #endif
}

/// SQLite-backed authority for machine renderer package reservations. It is
/// intentionally separate from wiki SQLite files and File Provider projections.
public actor RendererMachineIndexStore {
    private let layout: RendererPackageStoreLayout
    private let coordinator: RendererPackageStoreCoordinator
    private let derivedIndexWriter: any RendererMachineDerivedIndexWriting
    private let activationCleaner: any RendererPackageActivationCleaning

    public init(
        layout: RendererPackageStoreLayout,
        coordinator: RendererPackageStoreCoordinator? = nil,
        derivedIndexWriter: any RendererMachineDerivedIndexWriting = FileRendererMachineDerivedIndexWriter(),
        activationCleaner: any RendererPackageActivationCleaning = FileRendererPackageActivationCleaner()
    ) {
        self.layout = layout
        self.coordinator = coordinator ?? RendererPackageStoreCoordinator(layout: layout)
        self.derivedIndexWriter = derivedIndexWriter
        self.activationCleaner = activationCleaner
    }

    public func read() async throws -> RendererMachineIndex {
        try prepareRoot()
        let storage = RendererMachineIndexSQLiteStorage(layout: layout, derivedIndexWriter: derivedIndexWriter)
        return try await coordinator.withExclusiveAccess {
            try storage.readOrInitialize()
        }
    }

    /// Performs one generation-CAS mutation while holding the A2 coordinator.
    /// The closure receives only values; SQLite and filesystem I/O remain here.
    public func mutate(
        expectedGeneration: UInt64,
        _ mutation: @Sendable (inout [RendererPackageInstallRecord], inout Bool) throws -> Void
    ) async throws -> RendererMachineIndex {
        try prepareRoot()
        let storage = RendererMachineIndexSQLiteStorage(layout: layout, derivedIndexWriter: derivedIndexWriter)
        return try await coordinator.withExclusiveAccess {
            try storage.mutate(expectedGeneration: expectedGeneration, mutation: mutation)
        }
    }

    /// Records one qualifying installed-renderer failure under the same
    /// coordinator and generation-CAS discipline as package mutations.
    public func recordInstalledRendererFailure(
        packageID: RendererPackageID,
        version: RendererPackageVersion,
        failure: RendererInstalledRendererFailureCause,
        expectedGeneration: UInt64,
        clock: any RendererEventClock = WallRendererEventClock()
    ) async throws -> (index: RendererMachineIndex, window: RendererInstalledRendererFailureWindow) {
        try prepareRoot()
        let storage = RendererMachineIndexSQLiteStorage(layout: layout, derivedIndexWriter: derivedIndexWriter)
        return try await coordinator.withExclusiveAccess {
            try storage.recordInstalledRendererFailure(
                packageID: packageID,
                version: version,
                failure: failure,
                expectedGeneration: expectedGeneration,
                now: clock.now()
            )
        }
    }

    /// Re-enables installed renderer projection and discards the current
    /// rolling failure history so an old window cannot immediately re-trigger.
    public func resetInstalledRendererSafeMode(expectedGeneration: UInt64) async throws -> RendererMachineIndex {
        try prepareRoot()
        let storage = RendererMachineIndexSQLiteStorage(layout: layout, derivedIndexWriter: derivedIndexWriter)
        return try await coordinator.withExclusiveAccess {
            try storage.resetInstalledRendererSafeMode(expectedGeneration: expectedGeneration)
        }
    }

    /// Returns the current window after applying normal time aging. This read
    /// does not alter generation; the next qualifying write persists pruning.
    public func failureWindow(
        packageID: RendererPackageID,
        version: RendererPackageVersion,
        clock: any RendererEventClock = WallRendererEventClock()
    ) async throws -> RendererInstalledRendererFailureWindow {
        let index = try await read()
        let failures = try rendererInstalledRendererFailuresPruned(index.installedRendererFailures, now: clock.now().date())
        return rendererInstalledRendererFailureWindow(failures, reservation: .init(packageID: packageID, version: version))
    }

    /// Atomically promotes a validator-produced staged package into its reserved
    /// immutable package/version root, then makes its registrations available in
    /// the machine index. The coordinator covers both the revalidation and the
    /// rename so no staged mutation can race activation.
    public func activate(
        _ package: ValidatedRendererPackage,
        expectedGeneration: UInt64,
        clock: any RendererEventClock = WallRendererEventClock()
    ) async throws -> RendererMachineIndex {
        let storage = RendererMachineIndexSQLiteStorage(layout: layout, derivedIndexWriter: derivedIndexWriter)
        let layout = self.layout
        let activationCleaner = self.activationCleaner
        do {
            try prepareRoot()
            return try await coordinator.withExclusiveAccess {
                var cleanupTarget: RendererMachineActivationCleanupTarget? =
                    isRendererPackageStorePathContained(package.stagedRoot, within: layout.stagingRoot)
                    ? .staging(package.stagedRoot)
                    : nil
                do {
                    try Task.checkCancellation()
                    let validator = RendererPackageValidator(packageRoot: layout.root, stagingRoot: layout.stagingRoot)
                    let revalidated = try validator.revalidate(package)
                    guard revalidated.manifest.packageID == package.manifest.packageID,
                          revalidated.manifest.version == package.manifest.version,
                          revalidated.packageHash == package.packageHash,
                          isRendererPackageStorePathContained(revalidated.stagedRoot, within: layout.stagingRoot)
                    else { throw RendererMachineIndexStoreError.activationFailed }
                    cleanupTarget = .staging(revalidated.stagedRoot)

                    let destination = layout.packageURL(packageID: revalidated.manifest.packageID, version: revalidated.manifest.version)
                    try rendererMachineActivationEnsureDirectory(layout.packagesRoot)
                    try rendererMachineActivationEnsureDirectory(destination.deletingLastPathComponent())
                    guard isRendererPackageStorePathContained(destination.deletingLastPathComponent(), within: layout.packagesRoot) else {
                        throw RendererMachineIndexStoreError.invalidPackagePath
                    }
                    let sourceIdentity = try rendererMachineActivationDirectoryIdentity(revalidated.stagedRoot)
                    try rendererMachineActivationMoveNoReplace(revalidated.stagedRoot, destination)
                    cleanupTarget = .installed(destination)
                    guard try rendererMachineActivationDirectoryIdentity(destination) == sourceIdentity else {
                        throw RendererMachineIndexStoreError.activationFailed
                    }

                    try Task.checkCancellation()
                    _ = try storage.readOrInitialize()
                    let timestamp = clock.now()
                    return try storage.mutate(expectedGeneration: expectedGeneration) { records, _ in
                        let existing = records.first {
                            $0.packageID == revalidated.manifest.packageID && $0.version == revalidated.manifest.version
                        }
                        if let existing, existing.expectedPackageHash != revalidated.packageHash {
                            throw RendererMachineIndexStoreError.conflictingExpectedHash
                        }
                        let record = try RendererPackageInstallRecord(
                            packageID: revalidated.manifest.packageID,
                            version: revalidated.manifest.version,
                            expectedPackageHash: revalidated.packageHash,
                            state: .validated,
                            reservedAt: existing?.reservedAt ?? timestamp,
                            updatedAt: timestamp,
                            validatedDescriptors: revalidated.manifest.descriptors
                        )
                        records.removeAll {
                            $0.packageID == record.packageID && $0.version == record.version
                        }
                        records.append(record)
                    }
                } catch {
                    if let cleanupTarget {
                        try rendererMachineActivationCleanup(cleanupTarget, layout: layout, cleaner: activationCleaner)
                    }
                    if error is CancellationError { throw RendererMachineIndexStoreError.activationCancelled }
                    if let error = error as? RendererMachineIndexStoreError { throw error }
                    throw RendererMachineIndexStoreError.activationFailed
                }
            }
        } catch {
            if let error = error as? RendererMachineIndexStoreError { throw error }
            // A coordinator failure occurs before this invocation owns the
            // staged tree. Preserve both the caller-owned validation artifact
            // and the precise contention classification for a safe retry.
            if let error = error as? RendererCoordinatorFailure { throw error }
            if isRendererPackageStorePathContained(package.stagedRoot, within: layout.stagingRoot) {
                try rendererMachineActivationCleanup(.staging(package.stagedRoot), layout: layout, cleaner: activationCleaner)
            }
            if error is CancellationError { throw RendererMachineIndexStoreError.activationCancelled }
            throw RendererMachineIndexStoreError.activationFailed
        }
    }

    /// Changes machine install/safe-mode state and appends its durable renderer
    /// event in the same coordinator-held SQLite transaction. Nothing is
    /// emitted here; callers may publish a payload only after this returns.
    public func mutateAndAppendMachineEvent(
        expectedGeneration: UInt64,
        scope: RendererMachineScopeID,
        payload: RendererSettingsChangeEvent,
        eventIDGenerator: any RendererEventIDGenerating = UUIDRendererEventIDGenerator(),
        sequenceGenerator: any RendererEventSequenceGenerating = DurableRendererEventSequenceGenerator(),
        clock: any RendererEventClock = WallRendererEventClock(),
        _ mutation: @Sendable (inout [RendererPackageInstallRecord], inout Bool) throws -> Void
    ) async throws -> (index: RendererMachineIndex, record: PersistedWikiStoreChangeRecord) {
        try prepareRoot()
        let storage = RendererMachineIndexSQLiteStorage(layout: layout, derivedIndexWriter: derivedIndexWriter)
        return try await coordinator.withExclusiveAccess {
            try storage.mutateAndAppendMachineEvent(expectedGeneration: expectedGeneration, scope: scope, payload: payload, eventIDGenerator: eventIDGenerator, sequenceGenerator: sequenceGenerator, clock: clock, mutation: mutation)
        }
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
    }
}

private func rendererMachineActivationEnsureDirectory(_ url: URL) throws {
    guard url.isFileURL else {
        throw RendererMachineIndexStoreError.invalidPackagePath
    }
    do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    catch { throw RendererMachineIndexStoreError.activationFailed }
    var metadata = stat()
    guard url.path.withCString({ lstat($0, &metadata) }) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR
    else { throw RendererMachineIndexStoreError.invalidPackagePath }
}

private struct RendererMachineActivationDirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private func rendererMachineActivationDirectoryIdentity(_ url: URL) throws -> RendererMachineActivationDirectoryIdentity {
    var pathMetadata = stat()
    guard url.path.withCString({ lstat($0, &pathMetadata) }) == 0,
          (pathMetadata.st_mode & S_IFMT) == S_IFDIR
    else { throw RendererMachineIndexStoreError.activationFailed }
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw RendererMachineIndexStoreError.activationFailed }
    defer { close(descriptor) }
    var descriptorMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0,
          (descriptorMetadata.st_mode & S_IFMT) == S_IFDIR,
          pathMetadata.st_dev == descriptorMetadata.st_dev,
          pathMetadata.st_ino == descriptorMetadata.st_ino
    else { throw RendererMachineIndexStoreError.activationFailed }
    return RendererMachineActivationDirectoryIdentity(device: descriptorMetadata.st_dev, inode: descriptorMetadata.st_ino)
}

private func rendererMachineActivationMoveNoReplace(_ source: URL, _ destination: URL) throws {
    let result = source.path.withCString { sourcePath in
        destination.path.withCString { destinationPath in
            renderer_package_move_no_replace(sourcePath, destinationPath)
        }
    }
    guard result == 0 else {
        if errno == EEXIST { throw RendererMachineIndexStoreError.packageRootAlreadyExists }
        throw RendererMachineIndexStoreError.activationFailed
    }
}

private enum RendererMachineActivationCleanupTarget {
    case staging(URL)
    case installed(URL)
}

private func rendererMachineActivationCleanup(
    _ target: RendererMachineActivationCleanupTarget,
    layout: RendererPackageStoreLayout,
    cleaner: any RendererPackageActivationCleaning
) throws {
    let url: URL
    switch target {
    case .staging(let value):
        guard isRendererPackageStorePathContained(value, within: layout.stagingRoot) else {
            throw RendererMachineIndexStoreError.invalidPackagePath
        }
        url = value
    case .installed(let value):
        guard isRendererPackageStorePathContained(value, within: layout.packagesRoot) else {
            throw RendererMachineIndexStoreError.invalidPackagePath
        }
        url = value
    }
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do { try cleaner.removeRecursively(url) }
    catch {
        DebugLog.store("Renderer package activation cleanup failed: redacted path.")
        throw RendererMachineIndexStoreError.activationCleanupFailed
    }
}

// pattern: Imperative Shell

private struct RendererMachineIndexSQLiteStorage: Sendable {
    let layout: RendererPackageStoreLayout
    let derivedIndexWriter: any RendererMachineDerivedIndexWriting

    func readOrInitialize() throws -> RendererMachineIndex {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        return try withDatabase { database in
            if try hasIndexTable(database) {
                try ensureExpectedHashReservationTable(database)
                let loaded = try load(database: database)
                let index = loaded.index
                try rendererMachineIndexValidatingPackagePaths(index, layout: layout)
                try reserveExpectedHashes(database, records: index.records)
                if loaded.requiresMigration {
                    try migrate(database: database, index: index)
                }
                return index
            }
            try execute(database, sql: Self.createTableSQL)
            try ensureExpectedHashReservationTable(database)
            let fresh = try RendererMachineIndex()
            try writeFresh(database: database, index: fresh)
            return fresh
        }
    }

    func mutate(
        expectedGeneration: UInt64,
        mutation: (inout [RendererPackageInstallRecord], inout Bool) throws -> Void
    ) throws -> RendererMachineIndex {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        return try withDatabase { database in
            guard try hasIndexTable(database) else { throw RendererMachineIndexStoreError.corruptIndex }
            try ensureExpectedHashReservationTable(database)
            let current = try load(database: database).index
            try rendererMachineIndexValidatingPackagePaths(current, layout: layout)
            let next = try rendererMachineIndexApplying(current, expectedGeneration: expectedGeneration, mutation: mutation)
            try rendererMachineIndexValidatingPackagePaths(next, layout: layout)
            try execute(database, sql: "SAVEPOINT renderer_machine_index_mutation")
            do {
                try reserveExpectedHashes(database, records: current.records)
                try reserveExpectedHashes(database, records: next.records)
                try update(database: database, index: next)
                try replaceDerivedIndex(next)
                try execute(database, sql: "RELEASE SAVEPOINT renderer_machine_index_mutation")
                return next
            } catch {
                _ = sqlite3_exec(database, "ROLLBACK TO SAVEPOINT renderer_machine_index_mutation", nil, nil, nil)
                _ = sqlite3_exec(database, "RELEASE SAVEPOINT renderer_machine_index_mutation", nil, nil, nil)
                if error is RendererMachineIndexStoreError { throw error }
                throw RendererMachineIndexStoreError.derivedIndexReplacementFailed
            }
        }
    }

    func recordInstalledRendererFailure(
        packageID: RendererPackageID,
        version: RendererPackageVersion,
        failure: RendererInstalledRendererFailureCause,
        expectedGeneration: UInt64,
        now: RFC3339Timestamp
    ) throws -> (index: RendererMachineIndex, window: RendererInstalledRendererFailureWindow) {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        return try withDatabase { database in
            guard try hasIndexTable(database) else { throw RendererMachineIndexStoreError.corruptIndex }
            try ensureExpectedHashReservationTable(database)
            let current = try load(database: database).index
            try rendererMachineIndexValidatingPackagePaths(current, layout: layout)
            let result = try rendererMachineIndexRecordingInstalledRendererFailure(current, packageID: packageID, version: version, cause: failure, expectedGeneration: expectedGeneration, now: now)
            try execute(database, sql: "SAVEPOINT renderer_machine_index_failure_mutation")
            do {
                try update(database: database, index: result.index)
                try replaceDerivedIndex(result.index)
                try execute(database, sql: "RELEASE SAVEPOINT renderer_machine_index_failure_mutation")
                return result
            } catch {
                _ = sqlite3_exec(database, "ROLLBACK TO SAVEPOINT renderer_machine_index_failure_mutation", nil, nil, nil)
                _ = sqlite3_exec(database, "RELEASE SAVEPOINT renderer_machine_index_failure_mutation", nil, nil, nil)
                if error is RendererMachineIndexStoreError { throw error }
                throw RendererMachineIndexStoreError.derivedIndexReplacementFailed
            }
        }
    }

    func resetInstalledRendererSafeMode(expectedGeneration: UInt64) throws -> RendererMachineIndex {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        return try withDatabase { database in
            guard try hasIndexTable(database) else { throw RendererMachineIndexStoreError.corruptIndex }
            try ensureExpectedHashReservationTable(database)
            let current = try load(database: database).index
            try rendererMachineIndexValidatingPackagePaths(current, layout: layout)
            let next = try rendererMachineIndexResettingInstalledRendererSafeMode(current, expectedGeneration: expectedGeneration)
            try rendererMachineIndexValidatingPackagePaths(next, layout: layout)
            try execute(database, sql: "SAVEPOINT renderer_machine_index_safe_mode_reset")
            do {
                try update(database: database, index: next)
                try replaceDerivedIndex(next)
                try execute(database, sql: "RELEASE SAVEPOINT renderer_machine_index_safe_mode_reset")
                return next
            } catch {
                _ = sqlite3_exec(database, "ROLLBACK TO SAVEPOINT renderer_machine_index_safe_mode_reset", nil, nil, nil)
                _ = sqlite3_exec(database, "RELEASE SAVEPOINT renderer_machine_index_safe_mode_reset", nil, nil, nil)
                if error is RendererMachineIndexStoreError { throw error }
                throw RendererMachineIndexStoreError.derivedIndexReplacementFailed
            }
        }
    }

    func mutateAndAppendMachineEvent(
        expectedGeneration: UInt64,
        scope: RendererMachineScopeID,
        payload: RendererSettingsChangeEvent,
        eventIDGenerator: any RendererEventIDGenerating,
        sequenceGenerator: any RendererEventSequenceGenerating,
        clock: any RendererEventClock,
        mutation: (inout [RendererPackageInstallRecord], inout Bool) throws -> Void
    ) throws -> (index: RendererMachineIndex, record: PersistedWikiStoreChangeRecord) {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        return try withDatabase { database in
            guard try hasIndexTable(database) else { throw RendererMachineIndexStoreError.corruptIndex }
            try ensureExpectedHashReservationTable(database)
            let current = try load(database: database).index
            let next = try rendererMachineIndexApplying(current, expectedGeneration: expectedGeneration, mutation: mutation)
            try rendererMachineIndexValidatingPackagePaths(next, layout: layout)
            try attachJournal(database)
            try RendererMachineJournalSQLite.initializeAttached(database)
            try execute(database, sql: "SAVEPOINT renderer_machine_index_event_mutation")
            do {
                try reserveExpectedHashes(database, records: current.records)
                try reserveExpectedHashes(database, records: next.records)
                let highWater = try RendererMachineJournalSQLite.attachedHighWater(database, scope: scope)
                let record = try PersistedWikiStoreChangeRecord(eventID: eventIDGenerator.nextEventID(), sequence: sequenceGenerator.nextSequence(after: highWater), scope: .machine(scope), payload: .rendererSettings(payload), committedAt: clock.now())
                try update(database: database, index: next)
                try RendererMachineJournalSQLite.appendAttached(database, record: record)
                try replaceDerivedIndex(next)
                try execute(database, sql: "RELEASE SAVEPOINT renderer_machine_index_event_mutation")
                return (next, record)
            } catch {
                _ = sqlite3_exec(database, "ROLLBACK TO SAVEPOINT renderer_machine_index_event_mutation", nil, nil, nil)
                _ = sqlite3_exec(database, "RELEASE SAVEPOINT renderer_machine_index_event_mutation", nil, nil, nil)
                throw error
            }
        }
    }

    private func attachJournal(_ database: OpaquePointer) throws {
        let escapedPath = layout.journalURL.path.replacingOccurrences(of: "'", with: "''")
        try execute(database, sql: "ATTACH DATABASE '\(escapedPath)' AS renderer_machine_journal")
    }

    private func writeFresh(database: OpaquePointer, index: RendererMachineIndex) throws {
        try execute(database, sql: "SAVEPOINT renderer_machine_index_fresh")
        do {
            try insert(database: database, index: index)
            try replaceDerivedIndex(index)
            try execute(database, sql: "RELEASE SAVEPOINT renderer_machine_index_fresh")
        } catch {
            _ = sqlite3_exec(database, "ROLLBACK TO SAVEPOINT renderer_machine_index_fresh", nil, nil, nil)
            _ = sqlite3_exec(database, "RELEASE SAVEPOINT renderer_machine_index_fresh", nil, nil, nil)
            if error is RendererMachineIndexStoreError { throw error }
            throw RendererMachineIndexStoreError.derivedIndexReplacementFailed
        }
    }

    private struct LoadedIndex {
        let index: RendererMachineIndex
        let requiresMigration: Bool
    }

    private func load(database: OpaquePointer) throws -> LoadedIndex {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT schema_version, generation, index_json FROM renderer_machine_index WHERE singleton = 1", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw RendererMachineIndexStoreError.corruptIndex }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 2) == SQLITE_BLOB
        else { throw RendererMachineIndexStoreError.corruptIndex }
        let schemaVersion = Int(sqlite3_column_int64(statement, 0))
        guard schemaVersion == 2 || schemaVersion == RendererMachineIndex.currentSchemaVersion else {
            throw RendererMachineIndexStoreError.unsupportedSchemaVersion
        }
        let rawGeneration = sqlite3_column_int64(statement, 1)
        guard rawGeneration >= 0 else { throw RendererMachineIndexStoreError.corruptIndex }
        let generation = UInt64(rawGeneration)
        let length = Int(sqlite3_column_bytes(statement, 2))
        guard length >= 0, let bytes = sqlite3_column_blob(statement, 2) else {
            throw RendererMachineIndexStoreError.corruptIndex
        }
        let index: RendererMachineIndex
        do { index = try JSONDecoder().decode(RendererMachineIndex.self, from: Data(bytes: bytes, count: length)) }
        catch { throw RendererMachineIndexStoreError.corruptIndex }
        guard index.generation == generation else {
            throw RendererMachineIndexStoreError.corruptIndex
        }
        return .init(index: index, requiresMigration: schemaVersion != RendererMachineIndex.currentSchemaVersion)
    }

    /// Rewrites a proven v2 JSON shape as v3 without changing generation,
    /// descriptors, or safe mode. The savepoint leaves the v2 authority intact
    /// if the derived projection cannot be replaced.
    private func migrate(database: OpaquePointer, index: RendererMachineIndex) throws {
        try execute(database, sql: "SAVEPOINT renderer_machine_index_schema_migration")
        do {
            try update(database: database, index: index)
            try replaceDerivedIndex(index)
            try execute(database, sql: "RELEASE SAVEPOINT renderer_machine_index_schema_migration")
        } catch {
            _ = sqlite3_exec(database, "ROLLBACK TO SAVEPOINT renderer_machine_index_schema_migration", nil, nil, nil)
            _ = sqlite3_exec(database, "RELEASE SAVEPOINT renderer_machine_index_schema_migration", nil, nil, nil)
            if error is RendererMachineIndexStoreError { throw error }
            throw RendererMachineIndexStoreError.derivedIndexReplacementFailed
        }
    }

    private func insert(database: OpaquePointer, index: RendererMachineIndex) throws {
        try persist(database: database, sql: "INSERT INTO renderer_machine_index (singleton, schema_version, generation, index_json) VALUES (1, ?1, ?2, ?3)", index: index)
    }

    private func update(database: OpaquePointer, index: RendererMachineIndex) throws {
        try persist(database: database, sql: "UPDATE renderer_machine_index SET schema_version = ?1, generation = ?2, index_json = ?3 WHERE singleton = 1", index: index)
    }

    private func persist(database: OpaquePointer, sql: String, index: RendererMachineIndex) throws {
        let data: Data
        do { data = try JSONEncoder().encode(index) }
        catch { throw RendererMachineIndexStoreError.corruptIndex }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RendererMachineIndexStoreError.sqliteFailure
        }
        defer { sqlite3_finalize(statement) }
        guard index.generation <= UInt64(Int64.max),
              sqlite3_bind_int64(statement, 1, sqlite3_int64(index.schemaVersion)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, sqlite3_int64(index.generation)) == SQLITE_OK,
              data.withUnsafeBytes({ sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), rendererMachineIndexSQLiteTransient) }) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE
        else { throw RendererMachineIndexStoreError.sqliteFailure }
    }

    private func replaceDerivedIndex(_ index: RendererMachineIndex) throws {
        let data: Data
        do { data = try JSONEncoder().encode(index) }
        catch { throw RendererMachineIndexStoreError.corruptIndex }
        do { try derivedIndexWriter.replaceAtomically(data, at: layout.derivedIndexURL) }
        catch { throw RendererMachineIndexStoreError.derivedIndexReplacementFailed }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(layout.indexDatabaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RendererMachineIndexStoreError.sqliteFailure
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    /// SQLite owns the authoritative existence decision. This avoids a
    /// link-following Foundation pathname inspection before opening the DB.
    private func hasIndexTable(_ database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'renderer_machine_index'", -1, &statement, nil) == SQLITE_OK, let statement else { throw RendererMachineIndexStoreError.corruptIndex }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw RendererMachineIndexStoreError.corruptIndex }
        return result == SQLITE_ROW
    }

    private func ensureExpectedHashReservationTable(_ database: OpaquePointer) throws {
        try execute(database, sql: Self.createExpectedHashReservationTableSQL)
    }

    /// Hash reservations are append-only authority: removing an index row must
    /// not permit a different payload to claim the same package/version later.
    private func reserveExpectedHashes(_ database: OpaquePointer, records: [RendererPackageInstallRecord]) throws {
        for record in records {
            let existingHash = try expectedHashReservation(database, for: record)
            if let existingHash {
                guard existingHash == record.expectedPackageHash.hex else {
                    throw RendererMachineIndexStoreError.conflictingExpectedHash
                }
                continue
            }
            try insertExpectedHashReservation(database, record: record)
        }
    }

    private func expectedHashReservation(_ database: OpaquePointer, for record: RendererPackageInstallRecord) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT expected_hash FROM renderer_machine_expected_hash_reservations WHERE package_id = ?1 AND version = ?2", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RendererMachineIndexStoreError.sqliteFailure
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, record.packageID.rawValue, -1, rendererMachineIndexSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, record.version.rawValue, -1, rendererMachineIndexSQLiteTransient) == SQLITE_OK
        else { throw RendererMachineIndexStoreError.sqliteFailure }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw RendererMachineIndexStoreError.sqliteFailure }
        guard result == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, 0)
        else { throw RendererMachineIndexStoreError.corruptIndex }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, 0))), as: UTF8.self)
    }

    private func insertExpectedHashReservation(_ database: OpaquePointer, record: RendererPackageInstallRecord) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO renderer_machine_expected_hash_reservations(package_id, version, expected_hash) VALUES(?1, ?2, ?3)", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RendererMachineIndexStoreError.sqliteFailure
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, record.packageID.rawValue, -1, rendererMachineIndexSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, record.version.rawValue, -1, rendererMachineIndexSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, record.expectedPackageHash.hex, -1, rendererMachineIndexSQLiteTransient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE
        else { throw RendererMachineIndexStoreError.sqliteFailure }
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RendererMachineIndexStoreError.sqliteFailure
        }
    }

    private static let createTableSQL = """
    CREATE TABLE renderer_machine_index (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        schema_version INTEGER NOT NULL,
        generation INTEGER NOT NULL CHECK (generation >= 0),
        index_json BLOB NOT NULL
    )
    """

    private static let createExpectedHashReservationTableSQL = """
    CREATE TABLE IF NOT EXISTS renderer_machine_expected_hash_reservations (
        package_id TEXT NOT NULL,
        version TEXT NOT NULL,
        expected_hash TEXT NOT NULL,
        PRIMARY KEY(package_id, version)
    )
    """
}
