import Foundation
import Testing
@testable import WikiFSCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererMachineIndexStoreTests {
    @Test func fileDerivedIndexWriterCreatesAndReplacesExistingIndex() throws {
        let directory = try temporaryDirectory(named: "portable-replacement")
        let indexURL = directory.appendingPathComponent("derived/index.json")
        let writer = FileRendererMachineDerivedIndexWriter()
        let initial = Data("{\"generation\":0}".utf8)
        let replacement = Data("{\"generation\":1}".utf8)

        try writer.replaceAtomically(initial, at: indexURL)
        #expect(try Data(contentsOf: indexURL) == initial)

        try writer.replaceAtomically(replacement, at: indexURL)

        #expect(try Data(contentsOf: indexURL) == replacement)
        #expect(try FileManager.default.contentsOfDirectory(atPath: indexURL.deletingLastPathComponent().path)
            .contains { $0.hasPrefix(".index-") } == false)
    }

    @Test func freshReadInitializesSQLiteAuthorityAndDerivedJSON() async throws {
        let layout = try makeLayout("fresh")
        let index = try await RendererMachineIndexStore(layout: layout).read()

        #expect(index.generation == 0)
        #expect(index.records.isEmpty)
        #expect(index.safeModeIsEnabled == false)
        #expect(FileManager.default.fileExists(atPath: layout.indexDatabaseURL.path))
        let derived = try JSONDecoder().decode(RendererMachineIndex.self, from: Data(contentsOf: layout.derivedIndexURL))
        #expect(derived == index)
    }

    @Test func mutationIncrementsGenerationAndKeepsRecordUnvalidated() async throws {
        let layout = try makeLayout("mutation")
        let store = RendererMachineIndexStore(layout: layout)
        _ = try await store.read()
        let record = try makeRecord()

        let result = try await store.mutate(expectedGeneration: 0) { records, _ in records.append(record) }

        #expect(result.generation == 1)
        #expect(result.records == [record])
        #expect(result.records.allSatisfy { $0.state == .unvalidated })
        #expect(result.availableDescriptorProjection.isEmpty)
    }

    @Test func staleGenerationIsRejectedWithoutChangingAuthoritativeOrDerivedIndex() async throws {
        let layout = try makeLayout("stale")
        let store = RendererMachineIndexStore(layout: layout)
        _ = try await store.read()
        _ = try await store.mutate(expectedGeneration: 0) { _, safeMode in safeMode = true }
        let before = try Data(contentsOf: layout.derivedIndexURL)

        await #expect(throws: RendererMachineIndexStoreError.staleGeneration) {
            try await store.mutate(expectedGeneration: 0) { _, _ in }
        }

        #expect(try await store.read().generation == 1)
        #expect(try Data(contentsOf: layout.derivedIndexURL) == before)
    }

    @Test func conflictingExpectedHashCannotReplaceImmutableReservation() async throws {
        let layout = try makeLayout("hash")
        let store = RendererMachineIndexStore(layout: layout)
        _ = try await store.read()
        let first = try makeRecord()
        let conflicting = try makeRecord(hashByte: 2)
        _ = try await store.mutate(expectedGeneration: 0) { records, _ in records.append(first) }

        await #expect(throws: RendererMachineIndexStoreError.conflictingExpectedHash) {
            try await store.mutate(expectedGeneration: 1) { records, _ in records.append(conflicting) }
        }
        #expect(try await store.read().records == [first])
    }

    @Test func replacingAbsentReservationWithDifferentExpectedHashFailsClosedAcrossGenerations() async throws {
        let layout = try makeLayout("hash-history")
        let store = RendererMachineIndexStore(layout: layout)
        _ = try await store.read()
        let first = try makeRecord()
        let conflicting = try makeRecord(hashByte: 2)

        _ = try await store.mutate(expectedGeneration: 0) { records, _ in records = [first] }
        _ = try await store.mutate(expectedGeneration: 1) { records, _ in records.removeAll() }

        await #expect(throws: RendererMachineIndexStoreError.conflictingExpectedHash) {
            try await store.mutate(expectedGeneration: 2) { records, _ in records = [conflicting] }
        }
        #expect(try await store.read().generation == 2)
        #expect(try await store.read().records.isEmpty)
    }

    @Test func replacingAbsentReservationWithSameExpectedHashRemainsValid() async throws {
        let layout = try makeLayout("same-hash-history")
        let store = RendererMachineIndexStore(layout: layout)
        _ = try await store.read()
        let record = try makeRecord()

        _ = try await store.mutate(expectedGeneration: 0) { records, _ in records = [record] }
        _ = try await store.mutate(expectedGeneration: 1) { records, _ in records.removeAll() }
        let restored = try await store.mutate(expectedGeneration: 2) { records, _ in records = [record] }

        #expect(restored.generation == 3)
        #expect(restored.records == [record])
    }

    @Test func packageRootSymlinkEscapeIsRejected() async throws {
        let layout = try makeLayout("outside")
        let outside = try temporaryDirectory(named: "outside-target")
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: layout.packagesRoot, withDestinationURL: outside)
        let store = RendererMachineIndexStore(layout: layout)
        _ = try await store.read()

        await #expect(throws: RendererMachineIndexStoreError.invalidPackagePath) {
            try await store.mutate(expectedGeneration: 0) { records, _ in records.append(try makeRecord()) }
        }
    }

    @Test func duplicateRecordsAreRejected() async throws {
        let layout = try makeLayout("duplicate")
        let store = RendererMachineIndexStore(layout: layout)
        _ = try await store.read()
        let record = try makeRecord()

        await #expect(throws: RendererMachineIndexStoreError.duplicatePackageVersion) {
            try await store.mutate(expectedGeneration: 0) { records, _ in
                records.append(record)
                records.append(record)
            }
        }
    }

    @Test func failedDerivedReplacementRollsBackSQLiteAndPreservesLastValidJSON() async throws {
        let layout = try makeLayout("replacement")
        let goodStore = RendererMachineIndexStore(layout: layout)
        let initial = try await goodStore.read()
        let previousJSON = try Data(contentsOf: layout.derivedIndexURL)
        let failingStore = RendererMachineIndexStore(layout: layout, derivedIndexWriter: FailingDerivedWriter())

        await #expect(throws: RendererMachineIndexStoreError.derivedIndexReplacementFailed) {
            try await failingStore.mutate(expectedGeneration: initial.generation) { _, safeMode in safeMode = true }
        }

        #expect(try await goodStore.read() == initial)
        #expect(try Data(contentsOf: layout.derivedIndexURL) == previousJSON)
        #expect(try JSONDecoder().decode(RendererMachineIndex.self, from: previousJSON) == initial)
    }

    @Test func corruptIndexIsRejectedInsteadOfReinitialized() async throws {
        let layout = try makeLayout("corrupt")
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: layout.indexDatabaseURL)

        await #expect(throws: RendererMachineIndexStoreError.corruptIndex) {
            try await RendererMachineIndexStore(layout: layout).read()
        }
    }

    @Test func safeModePersistsAcrossStoreReopen() async throws {
        let layout = try makeLayout("safe-mode")
        let first = RendererMachineIndexStore(layout: layout)
        _ = try await first.read()
        _ = try await first.mutate(expectedGeneration: 0) { _, safeMode in safeMode = true }

        let reopened = try await RendererMachineIndexStore(layout: layout).read()
        #expect(reopened.safeModeIsEnabled)
        #expect(reopened.generation == 1)
    }

    @Test func machineStoreDoesNotTouchWikiOrFileProviderProjection() async throws {
        let container = try temporaryDirectory(named: "isolation")
        let wikiDatabase = container.appendingPathComponent("wiki.sqlite")
        let fileProviderProjection = container.appendingPathComponent("projection/page.md")
        try FileManager.default.createDirectory(at: fileProviderProjection.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("wiki".utf8).write(to: wikiDatabase)
        try Data("projection".utf8).write(to: fileProviderProjection)
        let beforeWiki = try Data(contentsOf: wikiDatabase)
        let beforeProjection = try Data(contentsOf: fileProviderProjection)
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: container.appendingPathComponent("machine", isDirectory: true))

        _ = try await RendererMachineIndexStore(layout: layout).read()

        #expect(try Data(contentsOf: wikiDatabase) == beforeWiki)
        #expect(try Data(contentsOf: fileProviderProjection) == beforeProjection)
    }

    private func makeRecord(hashByte: UInt8 = 1) throws -> RendererPackageInstallRecord {
        try RendererPackageInstallRecord(
            packageID: RendererPackageID(validating: "org.example.canvas"),
            version: RendererPackageVersion(validating: "1.0.0"),
            expectedPackageHash: RendererSHA256Digest(bytes: Array(repeating: hashByte, count: RendererSHA256Digest.byteCount)),
            state: .unvalidated,
            reservedAt: RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00"),
            updatedAt: RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")
        )
    }

    private func makeLayout(_ name: String) throws -> RendererPackageStoreLayout {
        try RendererPackageStoreLayout(appGroupContainerRoot: temporaryDirectory(named: name))
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-machine-index-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct FailingDerivedWriter: RendererMachineDerivedIndexWriting {
    func replaceAtomically(_: Data, at _: URL) throws { throw Failure() }
    private struct Failure: Error {}
}
