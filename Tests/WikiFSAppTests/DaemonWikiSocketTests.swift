#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
@testable import wikid

// Phase 2 of plans/cli-domain-commands.md: the wiki registry family over the
// REAL CLI ⇄ daemon socket — actual AF_UNIX connections between
// `DaemonWikiRegistryClient` and the real `DaemonDomainSocketDispatcher`
// running over a fixture `WikiDaemon`, exactly as the daemon boot wires it.
// The lifecycle test pins the contract that matters for the migration: create
// registers through the daemon (no CLI-side createAndSeed), reads adopt the
// daemon's registry view, rename is visible through the daemon, and delete
// inherits the daemon's FULL eviction — registry row AND database artifacts
// (main + WAL sidecars) — closing the CLI's old degraded-delete race.
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, short
// injected timeouts only.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DaemonWikiSocketTests {

    // MARK: Fixtures (same shape as DaemonDomainSocketTests)

    private func makeContainer() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dwm-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private func startDaemonSocket(
        container: URL
    ) throws -> (server: DaemonSearchSocketServer, daemon: WikiDaemon) {
        let daemon = WikiDaemon(containerDirectory: container)
        let dispatcher = DaemonDomainSocketDispatcher(daemon: daemon)
        let server = try DaemonSearchSocketServer(containerDirectory: container) { request in
            await dispatcher.handle(request)
        }
        try server.start()
        return (server, daemon)
    }

    private func makeClient(container: URL) throws -> DaemonWikiRegistryClient {
        try DaemonWikiRegistryClient(containerDirectory: container, timeout: 10)
    }

    // MARK: Lifecycle

    @Test func wikiLifecycleCreateResolveRenameDeleteEvictsRegistryAndArtifacts() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }
        let client = try makeClient(container: container)
        let fileManager = FileManager.default

        // CREATE — through the daemon; the name is trimmed, the Home page is
        // seeded by the daemon's bootstrap, and the registry is persisted.
        let created = try await client.createWiki(name: "  Lifecycle Wiki  ")
        #expect(created.displayName == "Lifecycle Wiki")
        let databaseURL = container.appendingPathComponent(created.dbFileName, isDirectory: false)
        #expect(fileManager.fileExists(atPath: databaseURL.path))

        // LIST — the daemon's registry view contains exactly the created wiki.
        let listed = try await client.listWikis()
        #expect(listed.map(\.id) == [created.id])

        // RESOLVE — by ULID and by display name (ULID tried first).
        let byID = try await client.resolveWiki(selector: created.id.rawValue)
        #expect(byID.id == created.id)
        let byName = try await client.resolveWiki(selector: "Lifecycle Wiki")
        #expect(byName.id == created.id)

        // RENAME — display name only; identity and database untouched.
        try await client.renameWiki(id: created.id, name: "Renamed Wiki")
        let renamed = try await client.resolveWiki(selector: created.id.rawValue)
        #expect(renamed.displayName == "Renamed Wiki")
        #expect(renamed.id == created.id)
        #expect(fileManager.fileExists(atPath: databaseURL.path))
        await #expect(throws: DaemonDomainError.self) {
            try await client.resolveWiki(selector: "Lifecycle Wiki")
        }

        // DELETE — full eviction: registry row AND database artifacts.
        try await client.deleteWiki(id: created.id)
        let after = try await client.listWikis()
        #expect(after.isEmpty)
        #expect(fileManager.fileExists(atPath: databaseURL.path) == false)
        #expect(fileManager.fileExists(atPath: databaseURL.path + "-wal") == false)
        #expect(fileManager.fileExists(atPath: databaseURL.path + "-shm") == false)
        await #expect(throws: DaemonDomainError.self) {
            try await client.resolveWiki(selector: created.id.rawValue)
        }
    }

    /// An empty-name create lands on the daemon's "Untitled Wiki" default —
    /// the same visible result the CLI's removed direct-create path produced.
    @Test func createWithBlankNameDefaultsToUntitledWiki() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }
        let client = try makeClient(container: container)

        let created = try await client.createWiki(name: "   ")
        #expect(created.displayName == "Untitled Wiki")
        let listed = try await client.listWikis()
        #expect(listed.count == 1)
    }

    // MARK: Typed failures

    /// An unknown id is the daemon's typed notFound with the CLI's byte-stable
    /// failure text — the exact message the removed direct-registry path
    /// printed.
    @Test func deleteUnknownWikiIsTypedNotFound() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }
        let client = try makeClient(container: container)

        let missing = WikiID(rawValue: "0100000000000000000000000A")
        do {
            try await client.deleteWiki(id: missing)
            Issue.record("expected notFound for an unknown wiki id")
        } catch let error as DaemonDomainError {
            #expect(error.code == .notFound)
            #expect(error.message == "no wiki matching \(missing.rawValue)")
        }
    }

    @Test func unknownWikiOperationIsTypedInvalidRequest() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }
        let socketClient = try DaemonDomainSocketClient(
            containerDirectory: container, timeout: 10)

        do {
            _ = try await socketClient.send(family: .wiki, operation: "teleportWiki")
            Issue.record("expected invalidRequest")
        } catch let error as DaemonDomainError {
            #expect(error.code == .invalidRequest)
            #expect(error.message.contains("teleportWiki"))
        }
    }

    /// A malformed create payload is a typed rejection, never a transport
    /// fault.
    @Test func malformedCreatePayloadIsTypedInvalidRequest() async throws {
        let container = makeContainer()
        let (server, _) = try startDaemonSocket(container: container)
        defer { server.stop() }
        let socketClient = try DaemonDomainSocketClient(
            containerDirectory: container, timeout: 10)

        do {
            _ = try await socketClient.send(
                family: .wiki,
                operation: DaemonDomainOperation.Wiki.createWiki,
                payload: Data("not json".utf8))
            Issue.record("expected invalidRequest")
        } catch let error as DaemonDomainError {
            #expect(error.code == .invalidRequest)
        }
    }

    // MARK: App closed

    /// App closed ⇒ socket unlinked ⇒ every wiki command fails fast with the
    /// explicit not-running signal. No local fallback.
    @Test func absentDaemonSurfacesExplicitNotRunningError() async throws {
        let container = makeContainer()
        let client = try makeClient(container: container)
        do {
            _ = try await client.listWikis()
            Issue.record("expected daemonNotRunning")
        } catch let error as SearchSocketError {
            #expect(error.isDaemonNotRunning)
            #expect(
                error.localizedDescription
                    == "the wikid daemon is not running — launch the app")
        }
    }
}
#endif
