#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikictl_fixture

/// The fixture store profile boot (``CLIStoreProfile`` in the fixture
/// target): the composed profile resolves ONE `GRDBWikiStore` and always
/// disposes it — on success, on operation failure, and when cleanup itself
/// fails (the combined error preserves the operation's error). Ported from
/// the WikiCtlCore-era suite; the profile moved here with the fixture-binary
/// split because the shipping wikictl no longer boots any local store.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct FixtureStoreProfileTests {
    enum ExpectedCommandFailure: Error {
        case expected
    }

    enum ExpectedCleanupFailure: Error {
        case expected
    }

    actor CLIProfileRecorder {
        private var resolvedStoreID: ObjectIdentifier?
        private var operationStoreID: ObjectIdentifier?
        private var disposalCount = 0

        func recordResolved(store: GRDBWikiStore) {
            resolvedStoreID = ObjectIdentifier(store)
        }

        func recordOperation(store: GRDBWikiStore) {
            operationStoreID = ObjectIdentifier(store)
        }

        func recordDisposal() {
            disposalCount += 1
        }

        func snapshot() -> (resolvedStoreID: ObjectIdentifier?, operationStoreID: ObjectIdentifier?, disposalCount: Int) {
            (resolvedStoreID, operationStoreID, disposalCount)
        }
    }

    // MARK: - Helpers

    /// Fresh temp directory per test (UUID) holding the `<ulid>.sqlite`.
    private func makeTempContainer() throws -> (URL, FileManager) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wikictl-fixture-profile-\(UUID().uuidString)")
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, fm)
    }

    private func removeTempContainer(_ container: URL, fileManager: FileManager) {
        do {
            try fileManager.removeItem(at: container)
        } catch {
            Issue.record("could not remove fixture-profile test container: \(error)")
        }
    }

    // MARK: - Profile boot + disposal

    @Test(arguments: [false, true])
    func fixtureStoreProfileUsesResolvedStoreAndDisposes(commandFails: Bool) async throws {
        let (container, fm) = try makeTempContainer()
        defer { removeTempContainer(container, fileManager: fm) }
        let wikiID = WikiID(rawValue: "01TESTCLI01")
        let databaseURL = container.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
        let recorder = CLIProfileRecorder()
        let observerID = PluginID("test.cli-store-observer")
        let observer = PluginDefinition(
            id: observerID,
            dependencies: [ServiceDependency(StoreServiceKeys.store)]) {
            try ComponentDefinition(
                label: observerID.rawValue,
                dependencies: [ServiceDependency(StoreServiceKeys.store)]) { activation in
                let service = try await activation.require(StoreServiceKeys.store)
                guard let store = service as? GRDBWikiStore else {
                    throw CLIStoreProfileError.incompatibleStore
                }
                await recorder.recordResolved(store: store)
                _ = try await activation.effect { _ in
                    await recorder.recordDisposal()
                }
            }
        }
        let profile = CLIStoreProfile { request in
            var entries = try ProductionProfiles.cli(
                databaseURL: request.databaseURL,
                wikiID: request.wikiID,
                homeDirectory: request.containerDirectory)
            entries.append(Entry(id: EntryID("store-observer"), plugin: observerID))
            let definitions = CLIPluginCatalog.definitions() + [observer]
            return try await CordisBoot.boot(.init(
                catalog: try PluginCatalog(definitions),
                layers: [PatchFile(entries: entries)]))
        }

        do {
            let output = try await profile.withStore(request: .init(
                databaseURL: databaseURL,
                wikiID: wikiID,
                containerDirectory: container
            )) { store in
                await recorder.recordOperation(store: store)
                if commandFails {
                    throw ExpectedCommandFailure.expected
                }
                _ = try store.listPages(sortBy: .lastUpdated)
                return "profile-output"
            }
            #expect(commandFails == false)
            #expect(output == "profile-output")
        } catch is ExpectedCommandFailure {
            #expect(commandFails)
        }

        let snapshot = await recorder.snapshot()
        #expect(snapshot.resolvedStoreID == snapshot.operationStoreID)
        #expect(snapshot.disposalCount == 1)
    }

    @Test func fixtureStoreProfilePreservesOperationAndCleanupFailures() async throws {
        let (container, fm) = try makeTempContainer()
        defer { removeTempContainer(container, fileManager: fm) }
        let wikiID = WikiID(rawValue: "01TESTCLI02")
        let databaseURL = container.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)

        let cleanupID = PluginID("test.cli-cleanup-failure")
        let cleanupDefinition = PluginDefinition(id: cleanupID) {
            try ComponentDefinition(label: cleanupID.rawValue) { activation in
                _ = try await activation.effect { _ in
                    throw ExpectedCleanupFailure.expected
                }
            }
        }
        let profile = CLIStoreProfile { request in
            var entries = try ProductionProfiles.cli(
                databaseURL: request.databaseURL,
                wikiID: request.wikiID,
                homeDirectory: request.containerDirectory)
            entries.append(Entry(id: EntryID("cleanup-failure"), plugin: cleanupID))
            return try await CordisBoot.boot(.init(
                catalog: try PluginCatalog(CLIPluginCatalog.definitions() + [cleanupDefinition]),
                layers: [PatchFile(entries: entries)]))
        }

        do {
            _ = try await profile.withStore(request: .init(
                databaseURL: databaseURL,
                wikiID: wikiID,
                containerDirectory: container
            )) { _ in
                throw ExpectedCommandFailure.expected
            }
            Issue.record("expected combined operation and cleanup failure")
        } catch CLIStoreProfileError.operationAndCleanup(let operation, let cleanup) {
            #expect(operation is ExpectedCommandFailure)
            guard case .cleanup(let aggregate) = cleanup as? CordisError else {
                Issue.record("expected Cordis cleanup error, got \(cleanup)")
                return
            }
            #expect(aggregate.failures.count == 1)
            #expect(aggregate.failures.first?.error.message == "expected")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
#endif
