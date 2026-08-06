import Foundation
import Testing
@testable import WikiFSCore
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif

struct RendererMachineStoreFailureFixture {
    let root: URL
    let layout: RendererPackageStoreLayout
    let packageID: RendererPackageID
    let version: RendererPackageVersion
    let installedDescriptor: RendererDescriptor

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("renderer-failure-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        packageID = try RendererPackageID(validating: "org.example.failure-window")
        version = try RendererPackageVersion(validating: "1.0.0")
        installedDescriptor = try Self.descriptor(packageID: packageID, version: version, registrationID: "failure-web", implementation: .webPackage(.init(path: try RendererRelativePath(validating: "index.html"))))
    }

    func installedStore() async throws -> RendererMachineIndexStore {
        let store = RendererMachineIndexStore(layout: layout)
        let initial = try await store.read()
        let timestamp = try Self.timestamp(minutes: 0)
        let record = try RendererPackageInstallRecord(packageID: packageID, version: version, expectedPackageHash: RendererSHA256Digest(bytes: Array(repeating: 1, count: RendererSHA256Digest.byteCount)), state: .validated, reservedAt: timestamp, updatedAt: timestamp, validatedDescriptors: [installedDescriptor])
        _ = try await store.mutate(expectedGeneration: initial.generation) { records, _ in records = [record] }
        return store
    }

    func builtInDescriptor() throws -> RendererDescriptor {
        try Self.descriptor(packageID: RendererPackageID(validating: "org.example.builtin"), version: RendererPackageVersion(validating: "1.0.0"), registrationID: "builtin-pdf", implementation: .builtIn(.pdf))
    }

    func writeV2IndexForMigration(_ index: RendererMachineIndex) throws {
        let encoded = try JSONEncoder().encode(index)
        let object = try JSONSerialization.jsonObject(with: encoded)
        guard var legacy = object as? [String: Any] else { throw RendererMachineIndexStoreError.corruptIndex }
        legacy["schemaVersion"] = 2
        legacy.removeValue(forKey: "installedRendererFailures")
        let data = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])

        var database: OpaquePointer?
        guard sqlite3_open(layout.indexDatabaseURL.path, &database) == SQLITE_OK, let database else {
            throw RendererMachineIndexStoreError.sqliteFailure
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE renderer_machine_index SET schema_version = 2, index_json = ?1 WHERE singleton = 1", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RendererMachineIndexStoreError.sqliteFailure
        }
        defer { sqlite3_finalize(statement) }
        guard data.withUnsafeBytes({ sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE
        else { throw RendererMachineIndexStoreError.sqliteFailure }
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Fixture cleanup failed: \(error)") }
    }

    static func timestamp(minutes: Int) throws -> RFC3339Timestamp {
        let date = Date(timeIntervalSince1970: TimeInterval(minutes * 60))
        return RFC3339Timestamp(date: date)
    }

    private static func descriptor(packageID: RendererPackageID, version: RendererPackageVersion, registrationID: String, implementation: RendererImplementation) throws -> RendererDescriptor {
        try RendererDescriptor(reference: .init(packageID: packageID, version: version, registrationID: try RendererRegistrationID(validating: registrationID)), displayName: registrationID, implementation: implementation, matchers: [.artifactKind(.source)], presentations: implementation.isWebPackage ? [.web] : [.native], approvedAssets: implementation.isWebPackage ? [.init(path: try RendererRelativePath(validating: "index.html"), digest: RendererSHA256Digest(bytes: Array(repeating: 2, count: RendererSHA256Digest.byteCount)))] : [], capabilities: [.inputRead], sizeLimits: try .init(maximumInputByteCount: 1, maximumDecodedByteCount: 1), linkPolicy: .none, accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true), compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1), priority: 0)
    }

    struct Clock: RendererEventClock {
        let timestamp: RFC3339Timestamp
        func now() -> RFC3339Timestamp { timestamp }
    }
}

private extension RendererImplementation {
    var isWebPackage: Bool {
        if case .webPackage = self { return true }
        return false
    }
}
