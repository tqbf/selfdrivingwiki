#if os(macOS)
import Cordis
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
import WikiFSSearch

@Suite("Cordis search runtime", .serialized, .timeLimit(.minutes(1)))
struct SearchRuntimeAssemblyTests {
    @Test("service labels are stable")
    func serviceLabelsAreStable() {
        #expect(SearchRuntimeAssembly.ServiceLabels.identity == "search.identity")
        #expect(SearchRuntimeAssembly.ServiceLabels.contentSource == "search.content-source")
        #expect(SearchRuntimeAssembly.ServiceLabels.changeStreamFactory == "search.change-stream-factory")
        #expect(SearchRuntimeAssembly.ServiceLabels.indexer == "search.indexer")
        #expect(SearchRuntimeAssembly.ServiceLabels.runtime == "search.runtime")
        #expect(SearchRuntimeAssembly.ServiceLabels.services == "search.services")
    }

    @Test("shuffled registration builds, rebuilds, and queries")
    func shuffledRegistrationSettles() async throws {
        let fixture = try Fixture()
        await fixture.source.set([
            fixture.snapshot(id: "page-1", title: "Cordis Search", body: "private child runtime"),
        ])
        let root = CordisContext()
        let child = try await root.child()
        let handle = try await fixture.assembly.assemble(
            in: child,
            registrationOrder: SearchRuntimeAssembly.Component.allCases.shuffled())

        let results = try await handle.services.search(query: "private child", kinds: [.page], limit: 5)
        #expect(results.map(\.ulid) == ["page-1"])

        try await handle.dispose()
        try await root.dispose()
    }

    @Test("disposed runtime rejects later queries")
    func disposedRuntimeRejectsQueries() async throws {
        let fixture = try Fixture()
        await fixture.source.set([fixture.snapshot(id: "page-1", title: "Ready", body: "query")])
        let root = CordisContext()
        let child = try await root.child()
        let handle = try await fixture.assembly.assemble(in: child)
        let services = handle.services
        try await handle.dispose()

        await #expect(throws: SearchServicesError.disposedRuntime) {
            try await services.search(query: "query", kinds: [.page], limit: 5)
        }
        try await root.dispose()
    }

    @Test("invalidated mutable installation cannot publish")
    func invalidatedMutableInstallationCannotPublish() async {
        let facade = MutableSearchServices()
        let installation = MutableSearchServices.Installation()
        await facade.invalidate(installation)
        await facade.install(RecordingSearchServices(), for: installation)

        await #expect(throws: SearchServicesError.unavailable) {
            try await facade.search(query: "x", kinds: [.page], limit: 1)
        }
    }

    @Test("registry shutdown rejects new children")
    func registryShutdownRejectsNewChildren() async throws {
        let fixture = try Fixture()
        let registry = SearchRuntimeRegistry()
        await registry.shutdown()

        await #expect(throws: SearchRuntimeRegistryError.shuttingDown) {
            try await registry.assemble(fixture.assembly)
        }
    }

    @Test("owner waits for same-wiki predecessor before install")
    @MainActor
    func ownerWaitsForPredecessor() async throws {
        let fixture = try Fixture()
        await fixture.source.set([fixture.snapshot(id: "page-1", title: "Ready", body: "query")])
        let gate = AsyncGate()
        let prerequisite = Task { await gate.wait() }
        let owner = SearchCompositionOwner(
            registry: SearchRuntimeRegistry(),
            identity: fixture.assembly.identity,
            contentSource: fixture.source,
            changeStreamFactory: FinishedSearchChangeStreamFactory(),
            startupPrerequisite: prerequisite)
        owner.start()

        await #expect(throws: SearchServicesError.unavailable) {
            try await owner.services.search(query: "query", kinds: [.page], limit: 5)
        }
        await gate.open()
        await owner.awaitSettled()
        let results = try await owner.services.search(query: "query", kinds: [.page], limit: 5)
        #expect(results.map(\.ulid) == ["page-1"])
        await owner.shutdown()
    }

    @Test("repeated handle disposal is safe")
    func repeatedHandleDisposalIsSafe() async throws {
        let fixture = try Fixture()
        await fixture.source.set([fixture.snapshot(id: "page-1", title: "Ready", body: "query")])
        let root = CordisContext()
        let child = try await root.child()
        let handle = try await fixture.assembly.assemble(in: child)
        try await handle.dispose()
        try await handle.dispose()
        try await root.dispose()
    }

    @Test("invalid identity fails inside assembly")
    func invalidIdentityFailsInsideAssembly() async throws {
        let fixture = try Fixture()
        let invalid = SearchRuntimeAssembly(
            identity: SearchRuntimeIdentity(wikiID: WikiID(rawValue: ""), containerDirectory: fixture.directory),
            contentSource: fixture.source,
            changeStreamFactory: FinishedSearchChangeStreamFactory())
        let root = CordisContext()
        let child = try await root.child()

        await #expect(throws: SearchRuntimeAssemblyError.self) {
            try await invalid.assemble(in: child)
        }
        try await root.dispose()
    }

    @Test("buffered events apply before readiness and sequence recovery rebuilds")
    func bufferedEventsAndSequenceRecovery() async throws {
        let fixture = try Fixture()
        let initial = fixture.snapshot(id: "page-1", title: "Old title", body: "stale")
        let updated = fixture.snapshot(id: "page-1", title: "New title", body: "buffered update")
        await fixture.source.setAllSnapshots([initial])
        await fixture.source.setIndividualSnapshots([updated])
        let factory = ControlledSearchChangeStreamFactory(bufferedEvents: [
            ResourceChangeEvent(
                wikiID: fixture.wikiID,
                kind: .page,
                id: "page-1",
                change: .updated,
                seq: 10),
        ])
        let assembly = SearchRuntimeAssembly(
            identity: fixture.assembly.identity,
            contentSource: fixture.source,
            changeStreamFactory: factory)
        let root = CordisContext()
        let child = try await root.child()
        let handle = try await assembly.assemble(in: child)

        let buffered = try await handle.services.search(
            query: "buffered update", kinds: [.page], limit: 5)
        #expect(buffered.map(\.title) == ["New title"])

        await fixture.source.setAllSnapshots([updated])
        factory.yield(ResourceChangeEvent(
            wikiID: fixture.wikiID,
            kind: .page,
            id: "page-1",
            change: .updated,
            seq: 12))
        await fixture.source.waitForAllSnapshotsCount(2)

        factory.yield(ResourceChangeEvent(
            wikiID: fixture.wikiID,
            kind: nil,
            id: "external",
            change: .updated,
            seq: 13))
        await fixture.source.waitForAllSnapshotsCount(3)
        #expect(await fixture.source.allSnapshotsCount() == 3)

        try await handle.dispose()
        try await root.dispose()
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor MemorySearchSource: TantivyContentSource {
    private var fullSnapshots: [TantivyContentSnapshot] = []
    private var individualSnapshots: [TantivyContentSnapshot] = []
    private var fullReadCount = 0
    private var fullReadWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func set(_ snapshots: [TantivyContentSnapshot]) {
        fullSnapshots = snapshots
        individualSnapshots = snapshots
    }

    func setAllSnapshots(_ snapshots: [TantivyContentSnapshot]) { fullSnapshots = snapshots }
    func setIndividualSnapshots(_ snapshots: [TantivyContentSnapshot]) { individualSnapshots = snapshots }

    func snapshot(ulid: String, kind: TantivyDocumentKind) async throws -> TantivyContentSnapshot? {
        individualSnapshots.first { $0.ulid == ulid && $0.kind == kind }
    }

    func allSnapshots() async throws -> [TantivyContentSnapshot] {
        fullReadCount += 1
        let ready = fullReadWaiters.filter { fullReadCount >= $0.0 }
        fullReadWaiters.removeAll { fullReadCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        return fullSnapshots
    }

    func allSnapshotsCount() -> Int { fullReadCount }

    func waitForAllSnapshotsCount(_ count: Int) async {
        guard fullReadCount < count else { return }
        await withCheckedContinuation { fullReadWaiters.append((count, $0)) }
    }
}

private final class ControlledSearchChangeStreamFactory: SearchChangeStreamFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let bufferedEvents: [ResourceChangeEvent]
    private let pair = AsyncStream<ResourceChangeEvent>.makeStream(bufferingPolicy: .unbounded)
    private var consumed = false

    init(bufferedEvents: [ResourceChangeEvent]) { self.bufferedEvents = bufferedEvents }

    func take() throws -> SearchChangeStreamSubscription {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { throw SearchChangeStreamFactoryError.alreadyConsumed }
        consumed = true
        return SearchChangeStreamSubscription(bufferedEvents: bufferedEvents, stream: pair.stream)
    }

    func yield(_ event: ResourceChangeEvent) { pair.continuation.yield(event) }
    func finish() { pair.continuation.finish() }
}

private struct RecordingSearchServices: SearchServices {
    func search(query: String, kinds: [TantivyDocumentKind], limit: Int) async throws -> [TantivyShadowSearchResult] { [] }
    func autocomplete(partial: String, kinds: Set<TantivyDocumentKind>, distance: UInt8, limit: Int) async throws -> [TantivyShadowSearchResult] { [] }
}

private struct Fixture {
    let directory: URL
    let wikiID = WikiID(rawValue: "search-runtime-test")
    let source = MemorySearchSource()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var assembly: SearchRuntimeAssembly {
        SearchRuntimeAssembly(
            identity: SearchRuntimeIdentity(wikiID: wikiID, containerDirectory: directory),
            contentSource: source,
            changeStreamFactory: FinishedSearchChangeStreamFactory())
    }

    func snapshot(id: String, title: String, body: String) -> TantivyContentSnapshot {
        TantivyContentSnapshot(
            ulid: id,
            kind: .page,
            title: title,
            body: body,
            updatedAt: Date(timeIntervalSince1970: 1),
            versionSum: 1)
    }
}
#endif
