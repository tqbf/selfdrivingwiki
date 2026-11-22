#if os(macOS)
import Foundation
import WikiFSCore
@testable import WikiFSFileProvider
@testable import wikid

/// The Phase 6 socket fixture (plans/daemon-only-access.md §Phase 6.1): the
/// historical temp-DB construction, now served through a REAL daemon domain
/// socket. Seeds the wiki database at `<container>/<ulid>.sqlite`, registers
/// the wiki in the container's `wikis.json`, binds the production socket
/// server + domain dispatcher over that container, and hands back a
/// `Projection` whose data source is the projection CLIENT over the socket.
/// Every read the suites assert flows: client → framed AF_UNIX round trip →
/// dispatcher (`.projection` family) → daemon projection service → the
/// daemon's prepared store on the same DB file the test seeds.
///
/// Daemon-down shaping: `simulateDown()` stops the server (the socket file
/// goes away) so client reads fail with the transport-level
/// `daemonNotRunning` — the unavailable class Finder renders retryably.
/// `removeDatabase()` deletes the DB file under a LIVE server so the
/// daemon-side open fails — the typed store-open failure.
///
/// Lifecycle: `deinit` stops the server and removes the temp container, so
/// suites need no explicit cleanup. Suites using this fixture MUST be
/// `.serialized` + `.timeLimit` (AGENTS.md #1051): the projection client's
/// synchronous bridge parks the calling test thread (bounded by the client's
/// deadline) while the wire work runs on the cooperative pool.
final class ProjectionSocketFixture: @unchecked Sendable {
    let container: URL
    let descriptor: WikiDescriptor
    /// The test's OWN seeded database — expectations and mutation writes go
    /// through it exactly as the pre-P6 suites did. The daemon opens the same
    /// file (WAL: one writer per process + the daemon's own connection).
    let store: GRDBWikiStore
    /// The projection under test: identical tree logic, remote data source.
    let projection: Projection
    let server: DaemonSearchSocketServer
    private let dispatcher: DaemonDomainSocketDispatcher
    private let daemon: WikiDaemon

    static func make(displayName: String = "Projection Fixture Wiki") throws -> ProjectionSocketFixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "p6-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        let descriptor = WikiDescriptor.make(displayName: displayName)
        let dbURL = container.appendingPathComponent(descriptor.dbFileName)
        let store = try GRDBWikiStore(databaseURL: dbURL)
        // Register the seeded wiki so the daemon admits + serves it (the same
        // registry the app maintains; ISO-8601 codec per WikiRegistry).
        var registry = WikiRegistry.load(from: container)
        registry.add(descriptor)
        try registry.save(to: container)
        let daemon = WikiDaemon(containerDirectory: container)
        let dispatcher = DaemonDomainSocketDispatcher(daemon: daemon)
        let server = try DaemonSearchSocketServer(containerDirectory: container) { request in
            await dispatcher.handle(request)
        }
        try server.start()
        let client = DaemonProjectionClient(
            wikiID: descriptor.id,
            containerDirectory: { container })
        return ProjectionSocketFixture(
            container: container, descriptor: descriptor, store: store,
            projection: Projection(wikiID: descriptor.id, source: client),
            server: server, dispatcher: dispatcher, daemon: daemon)
    }

    private init(
        container: URL, descriptor: WikiDescriptor, store: GRDBWikiStore,
        projection: Projection, server: DaemonSearchSocketServer,
        dispatcher: DaemonDomainSocketDispatcher, daemon: WikiDaemon
    ) {
        self.container = container
        self.descriptor = descriptor
        self.store = store
        self.projection = projection
        self.server = server
        self.dispatcher = dispatcher
        self.daemon = daemon
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: container)
    }

    /// Stop the socket server: the socket file disappears and every client
    /// read fails with `SearchSocketError.daemonNotRunning` — the explicit
    /// daemon-down signal, mapped to an availability failure by the client.
    func simulateDown() {
        server.stop()
    }

    /// Delete the database file under a LIVE server: the daemon's prepared
    /// store open fails, and reads answer the typed store-open failure.
    /// (The historical `.corrupt` breakage analog — a store that cannot be
    /// read is an availability failure, never authoritative emptiness.)
    func removeDatabase() throws {
        try FileManager.default.removeItem(
            at: container.appendingPathComponent(descriptor.dbFileName))
    }
}
#endif
