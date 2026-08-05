import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif

// pattern: Imperative Shell

/// A bounded, durable machine-only renderer event journal. It lives beside the
/// package index under the App Group store and is never opened by wiki or File
/// Provider code.
public actor RendererMachineEventJournal {
    public struct ReadBatch: Sendable {
        public let records: [PersistedWikiStoreChangeRecord]
        public let highWater: UInt64
    }

    private let layout: RendererPackageStoreLayout
    private let coordinator: RendererPackageStoreCoordinator

    public init(layout: RendererPackageStoreLayout, coordinator: RendererPackageStoreCoordinator? = nil) {
        self.layout = layout
        self.coordinator = coordinator ?? RendererPackageStoreCoordinator(layout: layout)
    }

    public func highWater(scope: RendererMachineScopeID) async throws -> UInt64 {
        try await withDatabase { database in try RendererMachineJournalSQLite.highWater(database, scope: scope) }
    }

    public func records(after cursor: UInt64, scope: RendererMachineScopeID, limit: Int = RendererEventPolicy.phase3Default.orderedDrainBatchLimit) async throws -> ReadBatch {
        guard limit > 0, limit <= RendererEventPolicy.phase3Default.orderedDrainBatchLimit else { throw RendererMachineEventJournalError.invalidReadLimit }
        return try await withDatabase { database in
            let highWater = try RendererMachineJournalSQLite.highWater(database, scope: scope)
            let records = try RendererMachineJournalSQLite.records(database, after: cursor, scope: scope, limit: limit)
            return ReadBatch(records: records, highWater: highWater)
        }
    }

    public func append(_ record: PersistedWikiStoreChangeRecord) async throws {
        try await withDatabase { database in
            try RendererMachineJournalSQLite.transaction(database) {
                try RendererMachineJournalSQLite.append(database, record: record)
            }
        }
    }

    private func withDatabase<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        return try await coordinator.withExclusiveAccess {
            try RendererMachineJournalSQLite.withDatabase(at: layout.journalURL, body)
        }
    }
}

public enum RendererMachineEventJournalError: Error, Equatable, Sendable {
    case invalidReadLimit
    case invalidScope
    case nonMonotoneSequence
    case unsupportedSchemaVersion
    case corruptRecord
    case sqliteFailure
    case leaseNotFound
    case liveLeaseCannotBeReclaimed
}

public enum RendererEventProcessLeaseStatus: String, Codable, Sendable { case live, retired, reclaimed }

public struct RendererEventProcessLease: Codable, Sendable, Equatable {
    public let scope: RendererMachineScopeID
    public let subsystemID: RendererEventSubsystemID
    public let leaseID: RendererEventProcessLeaseID
    public let processID: Int32
    public let executableIdentity: String
    public let hostIdentity: String?
    public let startedAt: RFC3339Timestamp
    public let createdAt: RFC3339Timestamp
    public let lastHeartbeatAt: RFC3339Timestamp
    public let retiredAt: RFC3339Timestamp?
    public let status: RendererEventProcessLeaseStatus
}

/// Owns two-level consumer identity and durable cursors. It never treats an
/// event UUID as a deduplication key: successful handling is the only path
/// that advances a cursor.
public actor RendererMachineLeaseRegistry {
    private let journal: RendererMachineEventJournal
    private let leaseIDGenerator: any RendererEventProcessLeaseIDGenerating
    private let policy: RendererEventPolicy

    public init(journal: RendererMachineEventJournal, leaseIDGenerator: any RendererEventProcessLeaseIDGenerating = UUIDRendererEventProcessLeaseIDGenerator(), policy: RendererEventPolicy = .phase3Default) {
        self.journal = journal
        self.leaseIDGenerator = leaseIDGenerator
        self.policy = policy
    }

    public func createLease(scope: RendererMachineScopeID, subsystemID: RendererEventSubsystemID, processID: Int32, executableIdentity: String, hostIdentity: String?, startedAt: RFC3339Timestamp, now: RFC3339Timestamp) async throws -> RendererEventProcessLease {
        let lease = RendererEventProcessLease(scope: scope, subsystemID: subsystemID, leaseID: leaseIDGenerator.nextLeaseID(), processID: processID, executableIdentity: executableIdentity, hostIdentity: hostIdentity, startedAt: startedAt, createdAt: now, lastHeartbeatAt: now, retiredAt: nil, status: .live)
        try await journal.withLeaseDatabase { database in try RendererMachineJournalSQLite.insertLease(database, lease: lease) }
        return lease
    }

    public func heartbeat(_ lease: RendererEventProcessLease, at now: RFC3339Timestamp) async throws {
        try await journal.withLeaseDatabase { database in try RendererMachineJournalSQLite.heartbeat(database, lease: lease, at: now) }
    }

    public func retire(_ lease: RendererEventProcessLease, at now: RFC3339Timestamp) async throws {
        try await journal.withLeaseDatabase { database in try RendererMachineJournalSQLite.retire(database, lease: lease, at: now) }
    }

    public func reclaim(_ lease: RendererEventProcessLease, at now: RFC3339Timestamp, isProcessLive: Bool) async throws {
        guard isProcessLive == false else { throw RendererMachineEventJournalError.liveLeaseCannotBeReclaimed }
        try await journal.withLeaseDatabase { database in try RendererMachineJournalSQLite.reclaim(database, lease: lease, at: now, policy: self.policy) }
    }

    public func cursor(scope: RendererMachineScopeID, subsystemID: RendererEventSubsystemID, leaseID: RendererEventProcessLeaseID) async throws -> UInt64 {
        try await journal.withLeaseDatabase { database in try RendererMachineJournalSQLite.cursor(database, scope: scope, subsystem: subsystemID, leaseID: leaseID) }
    }

    public func markHandled(_ record: PersistedWikiStoreChangeRecord, lease: RendererEventProcessLease) async throws {
        try await journal.withLeaseDatabase { database in
            try RendererMachineJournalSQLite.validate(record)
            try RendererMachineJournalSQLite.transaction(database) {
                try RendererMachineJournalSQLite.advanceCursor(database, record: record, lease: lease)
            }
        }
    }
}

extension RendererMachineEventJournal {
    fileprivate func withLeaseDatabase<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T { try await withDatabase(body) }
}

// pattern: Imperative Shell

enum RendererMachineJournalSQLite {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else { throw RendererMachineEventJournalError.sqliteFailure }
        defer { sqlite3_close(database) }
        try initialize(database)
        return try body(database)
    }

    static func initialize(_ database: OpaquePointer) throws {
        try exec(database, "CREATE TABLE IF NOT EXISTS renderer_machine_events (scope TEXT NOT NULL, sequence INTEGER NOT NULL, record BLOB NOT NULL, PRIMARY KEY(scope, sequence)); CREATE TABLE IF NOT EXISTS renderer_machine_leases (scope TEXT NOT NULL, subsystem TEXT NOT NULL, lease TEXT NOT NULL, record BLOB NOT NULL, PRIMARY KEY(scope, subsystem, lease)); CREATE TABLE IF NOT EXISTS renderer_machine_cursors (scope TEXT NOT NULL, subsystem TEXT NOT NULL, lease TEXT NOT NULL, sequence INTEGER NOT NULL, PRIMARY KEY(scope, subsystem, lease)); CREATE TABLE IF NOT EXISTS renderer_machine_checkpoints (scope TEXT NOT NULL, subsystem TEXT NOT NULL, sequence INTEGER NOT NULL, PRIMARY KEY(scope, subsystem));")
    }

    static func initializeAttached(_ database: OpaquePointer) throws {
        try exec(database, "CREATE TABLE IF NOT EXISTS renderer_machine_journal.renderer_machine_events (scope TEXT NOT NULL, sequence INTEGER NOT NULL, record BLOB NOT NULL, PRIMARY KEY(scope, sequence)); CREATE TABLE IF NOT EXISTS renderer_machine_journal.renderer_machine_leases (scope TEXT NOT NULL, subsystem TEXT NOT NULL, lease TEXT NOT NULL, record BLOB NOT NULL, PRIMARY KEY(scope, subsystem, lease)); CREATE TABLE IF NOT EXISTS renderer_machine_journal.renderer_machine_cursors (scope TEXT NOT NULL, subsystem TEXT NOT NULL, lease TEXT NOT NULL, sequence INTEGER NOT NULL, PRIMARY KEY(scope, subsystem, lease)); CREATE TABLE IF NOT EXISTS renderer_machine_journal.renderer_machine_checkpoints (scope TEXT NOT NULL, subsystem TEXT NOT NULL, sequence INTEGER NOT NULL, PRIMARY KEY(scope, subsystem));")
    }

    static func transaction<T>(_ database: OpaquePointer, _ body: () throws -> T) throws -> T {
        try exec(database, "SAVEPOINT renderer_machine_journal")
        do { let value = try body(); try exec(database, "RELEASE SAVEPOINT renderer_machine_journal"); return value }
        catch { _ = sqlite3_exec(database, "ROLLBACK TO SAVEPOINT renderer_machine_journal", nil, nil, nil); _ = sqlite3_exec(database, "RELEASE SAVEPOINT renderer_machine_journal", nil, nil, nil); throw error }
    }

    static func append(_ database: OpaquePointer, record: PersistedWikiStoreChangeRecord) throws {
        try validate(record)
        guard case let .machine(scope) = record.scope else { throw RendererMachineEventJournalError.invalidScope }
        let highWater = try highWater(database, scope: scope)
        guard record.sequence == highWater + 1 else { throw RendererMachineEventJournalError.nonMonotoneSequence }
        let data = try JSONEncoder().encode(record)
        try bind(database, sql: "INSERT INTO renderer_machine_events(scope, sequence, record) VALUES(?1, ?2, ?3)", strings: [scope.rawValue], integer: record.sequence, data: data)
    }

    static func attachedHighWater(_ database: OpaquePointer, scope: RendererMachineScopeID) throws -> UInt64 {
        try scalar(database, sql: "SELECT COALESCE(MAX(sequence), 0) FROM renderer_machine_journal.renderer_machine_events WHERE scope = ?1", strings: [scope.rawValue])
    }

    static func appendAttached(_ database: OpaquePointer, record: PersistedWikiStoreChangeRecord) throws {
        try validate(record)
        guard case let .machine(scope) = record.scope else { throw RendererMachineEventJournalError.invalidScope }
        let highWater = try attachedHighWater(database, scope: scope)
        guard record.sequence == highWater + 1 else { throw RendererMachineEventJournalError.nonMonotoneSequence }
        let data = try JSONEncoder().encode(record)
        try bind(database, sql: "INSERT INTO renderer_machine_journal.renderer_machine_events(scope, sequence, record) VALUES(?1, ?2, ?3)", strings: [scope.rawValue], integer: record.sequence, data: data)
    }

    static func records(_ database: OpaquePointer, after: UInt64, scope: RendererMachineScopeID, limit: Int) throws -> [PersistedWikiStoreChangeRecord] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT record FROM renderer_machine_events WHERE scope = ?1 AND sequence > ?2 ORDER BY sequence ASC LIMIT ?3", -1, &statement, nil) == SQLITE_OK, let statement else { throw RendererMachineEventJournalError.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, scope.rawValue, -1, transient) == SQLITE_OK, sqlite3_bind_int64(statement, 2, sqlite3_int64(after)) == SQLITE_OK, sqlite3_bind_int(statement, 3, Int32(limit)) == SQLITE_OK else { throw RendererMachineEventJournalError.sqliteFailure }
        var result: [PersistedWikiStoreChangeRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0)); guard let bytes = sqlite3_column_blob(statement, 0) else { throw RendererMachineEventJournalError.corruptRecord }
            let record: PersistedWikiStoreChangeRecord
            do { record = try JSONDecoder().decode(PersistedWikiStoreChangeRecord.self, from: Data(bytes: bytes, count: count)) } catch { throw RendererMachineEventJournalError.corruptRecord }
            try validate(record); result.append(record)
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else { throw RendererMachineEventJournalError.sqliteFailure }
        return result
    }

    static func highWater(_ database: OpaquePointer, scope: RendererMachineScopeID) throws -> UInt64 {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, "SELECT COALESCE(MAX(sequence), 0) FROM renderer_machine_events WHERE scope = ?1", -1, &statement, nil) == SQLITE_OK, let statement else { throw RendererMachineEventJournalError.sqliteFailure }; defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, scope.rawValue, -1, transient) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw RendererMachineEventJournalError.sqliteFailure }
        return UInt64(sqlite3_column_int64(statement, 0))
    }

    static func validate(_ record: PersistedWikiStoreChangeRecord) throws {
        guard record.schemaVersion == 1 else { throw RendererMachineEventJournalError.unsupportedSchemaVersion }
        guard case .machine = record.scope, case .rendererSettings = record.payload else { throw RendererMachineEventJournalError.invalidScope }
    }

    static func insertLease(_ database: OpaquePointer, lease: RendererEventProcessLease) throws { try storeLease(database, lease: lease) }
    static func heartbeat(_ database: OpaquePointer, lease: RendererEventProcessLease, at now: RFC3339Timestamp) throws { var next = lease; next = RendererEventProcessLease(scope: lease.scope, subsystemID: lease.subsystemID, leaseID: lease.leaseID, processID: lease.processID, executableIdentity: lease.executableIdentity, hostIdentity: lease.hostIdentity, startedAt: lease.startedAt, createdAt: lease.createdAt, lastHeartbeatAt: now, retiredAt: nil, status: .live); try storeLease(database, lease: next) }
    static func retire(_ database: OpaquePointer, lease: RendererEventProcessLease, at now: RFC3339Timestamp) throws { let next = RendererEventProcessLease(scope: lease.scope, subsystemID: lease.subsystemID, leaseID: lease.leaseID, processID: lease.processID, executableIdentity: lease.executableIdentity, hostIdentity: lease.hostIdentity, startedAt: lease.startedAt, createdAt: lease.createdAt, lastHeartbeatAt: lease.lastHeartbeatAt, retiredAt: now, status: .retired); try storeLease(database, lease: next) }
    static func reclaim(_ database: OpaquePointer, lease: RendererEventProcessLease, at now: RFC3339Timestamp, policy: RendererEventPolicy) throws {
        let current = try loadLease(database, lease: lease)
        let baseline = current.retiredAt ?? current.lastHeartbeatAt
        let required = current.status == .retired ? policy.cleanRetirementSafetyInterval : policy.leaseExpiry + policy.clockSkewSafetyMargin
        guard date(now).timeIntervalSince(date(baseline)) >= required else { throw RendererMachineEventJournalError.liveLeaseCannotBeReclaimed }
        let next = RendererEventProcessLease(scope: current.scope, subsystemID: current.subsystemID, leaseID: current.leaseID, processID: current.processID, executableIdentity: current.executableIdentity, hostIdentity: current.hostIdentity, startedAt: current.startedAt, createdAt: current.createdAt, lastHeartbeatAt: current.lastHeartbeatAt, retiredAt: current.retiredAt, status: .reclaimed); try storeLease(database, lease: next)
    }
    static func cursor(_ database: OpaquePointer, scope: RendererMachineScopeID, subsystem: RendererEventSubsystemID, leaseID: RendererEventProcessLeaseID) throws -> UInt64 { try scalar(database, sql: "SELECT COALESCE(sequence, 0) FROM renderer_machine_cursors WHERE scope = ?1 AND subsystem = ?2 AND lease = ?3", strings: [scope.rawValue, subsystem.rawValue, leaseID.rawValue.uuidString]) }
    static func advanceCursor(_ database: OpaquePointer, record: PersistedWikiStoreChangeRecord, lease: RendererEventProcessLease) throws {
        guard case let .machine(scope) = record.scope, scope == lease.scope else { throw RendererMachineEventJournalError.invalidScope }
        let previous = try cursor(database, scope: scope, subsystem: lease.subsystemID, leaseID: lease.leaseID)
        guard record.sequence > previous else { return }
        try bind(database, sql: "INSERT INTO renderer_machine_cursors(scope, subsystem, lease, sequence) VALUES(?1, ?2, ?3, ?4) ON CONFLICT(scope, subsystem, lease) DO UPDATE SET sequence = excluded.sequence", strings: [scope.rawValue, lease.subsystemID.rawValue, lease.leaseID.rawValue.uuidString], integer: record.sequence)
        try bind(database, sql: "INSERT INTO renderer_machine_checkpoints(scope, subsystem, sequence) VALUES(?1, ?2, ?3) ON CONFLICT(scope, subsystem) DO UPDATE SET sequence = MAX(sequence, excluded.sequence)", strings: [scope.rawValue, lease.subsystemID.rawValue], integer: record.sequence)
    }
    static func storeLease(_ database: OpaquePointer, lease: RendererEventProcessLease) throws { let data = try JSONEncoder().encode(lease); try bind(database, sql: "INSERT INTO renderer_machine_leases(scope, subsystem, lease, record) VALUES(?1, ?2, ?3, ?4) ON CONFLICT(scope, subsystem, lease) DO UPDATE SET record = excluded.record", strings: [lease.scope.rawValue, lease.subsystemID.rawValue, lease.leaseID.rawValue.uuidString], data: data) }
    static func loadLease(_ database: OpaquePointer, lease: RendererEventProcessLease) throws -> RendererEventProcessLease {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT record FROM renderer_machine_leases WHERE scope = ?1 AND subsystem = ?2 AND lease = ?3", -1, &statement, nil) == SQLITE_OK, let statement else { throw RendererMachineEventJournalError.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, lease.scope.rawValue, -1, transient) == SQLITE_OK, sqlite3_bind_text(statement, 2, lease.subsystemID.rawValue, -1, transient) == SQLITE_OK, sqlite3_bind_text(statement, 3, lease.leaseID.rawValue.uuidString, -1, transient) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw RendererMachineEventJournalError.leaseNotFound }
        do { return try JSONDecoder().decode(RendererEventProcessLease.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) }
        catch { throw RendererMachineEventJournalError.corruptRecord }
    }
    static func scalar(_ database: OpaquePointer, sql: String, strings: [String]) throws -> UInt64 { var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw RendererMachineEventJournalError.sqliteFailure }; defer { sqlite3_finalize(statement) }; for (offset, string) in strings.enumerated() { guard sqlite3_bind_text(statement, Int32(offset + 1), string, -1, transient) == SQLITE_OK else { throw RendererMachineEventJournalError.sqliteFailure } }; guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }; return UInt64(sqlite3_column_int64(statement, 0)) }
    static func bind(_ database: OpaquePointer, sql: String, strings: [String], integer: UInt64? = nil, data: Data? = nil) throws { var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw RendererMachineEventJournalError.sqliteFailure }; defer { sqlite3_finalize(statement) }; var parameter = 1; for string in strings { guard sqlite3_bind_text(statement, Int32(parameter), string, -1, transient) == SQLITE_OK else { throw RendererMachineEventJournalError.sqliteFailure }; parameter += 1 }; if let integer { guard sqlite3_bind_int64(statement, Int32(parameter), sqlite3_int64(integer)) == SQLITE_OK else { throw RendererMachineEventJournalError.sqliteFailure }; parameter += 1 }; if let data { guard data.withUnsafeBytes({ sqlite3_bind_blob(statement, Int32(parameter), $0.baseAddress, Int32(data.count), transient) }) == SQLITE_OK else { throw RendererMachineEventJournalError.sqliteFailure } }; guard sqlite3_step(statement) == SQLITE_DONE else { throw RendererMachineEventJournalError.sqliteFailure } }
    static func exec(_ database: OpaquePointer, _ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw RendererMachineEventJournalError.sqliteFailure } }
    static func date(_ timestamp: RFC3339Timestamp) -> Date { ISO8601DateFormatter().date(from: timestamp.rawValue.replacingOccurrences(of: "+00:00", with: "Z")) ?? .distantPast }
}
