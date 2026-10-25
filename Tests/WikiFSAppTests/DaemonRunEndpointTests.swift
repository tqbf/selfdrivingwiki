#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiDaemonContract
@testable import wikid
import WikiFSCore

/// Run-lifetime endpoints through the trusted registration broker (plans/
/// agent-sandbox-scoping.md §4 + §5, Phase 2): real `DaemonRunSocketListener`
/// instances bound by the broker at `r/<opaque>.sock`, serving the REAL
/// `DaemonDomainSocketDispatcher` under the captured `.scopedRun` context.
///
/// Lifecycle contract proven here: launch binds the endpoint and activates
/// the lease; revocation unlinks it (idempotently, tying into the registry's
/// idempotent revoke); a second bind of a live endpoint fails closed; a bind
/// failure never leaves a lease behind. Scoped traffic rides the same
/// authorization gate as every other scoped connection.
///
/// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`; every
/// socket round trip carries a short timeout; no sleeps, no blocking waits.
@Suite("Daemon run endpoints", .serialized, .timeLimit(.minutes(5)))
struct DaemonRunEndpointTests {

    // MARK: Fixture

    /// One disposable container, TWO wikis, a central queue database, and a
    /// daemon hosting the ordinary socket + the broker with ONE shared
    /// registry. Launches run A (all classes, the "assigned" run) and run B
    /// (the foreign run) with live endpoints.
    final class Fixture {
        let container: URL
        let registry: DaemonRunRegistry
        let broker: DaemonRunRegistrationBroker
        let wikiA: WikiDescriptor
        let wikiB: WikiDescriptor
        let storeA: GRDBWikiStore
        let queueStore: QueueStore
        let runA: DaemonScopedRunHandle
        let runB: DaemonScopedRunHandle
        private let server: DaemonSearchSocketServer

        init() async throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "drunep-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(
                at: container, withIntermediateDirectories: true)

            var mutableA = WikiDescriptor.make(displayName: "Endpoint A")
            var mutableB = WikiDescriptor.make(displayName: "Endpoint B")
            mutableA.lastUsedAt = Date()
            mutableB.lastUsedAt = Date()
            wikiA = mutableA
            wikiB = mutableB
            var diskRegistry = WikiRegistry.load(from: container)
            diskRegistry.add(wikiA)
            diskRegistry.add(wikiB)
            try diskRegistry.save(to: container)
            storeA = try GRDBWikiStore(
                databaseURL: container.appendingPathComponent(
                    wikiA.dbFileName, isDirectory: false))
            let storeB = try GRDBWikiStore(
                databaseURL: container.appendingPathComponent(
                    wikiB.dbFileName, isDirectory: false))
            _ = try storeA.createPage(title: "Assigned Page", body: "in scope")
            _ = try storeB.createPage(title: "Foreign Page", body: "out of scope")
            queueStore = try QueueStore(
                databaseURL: container.appendingPathComponent(
                    "queue.sqlite", isDirectory: false))

            // The daemon hosts BOTH endpoints through ONE registry: the
            // ordinary socket keeps its pre-scoping `.ordinary` context; the
            // broker binds per-run listeners on the same dispatcher.
            let daemon = WikiDaemon(containerDirectory: container)
            let runRegistry = DaemonRunRegistry()
            let dispatcher = DaemonDomainSocketDispatcher(
                daemon: daemon, runRegistry: runRegistry)
            let ordinary = try DaemonSearchSocketServer(containerDirectory: container) {
                request in
                await dispatcher.handle(request)
            }
            try ordinary.start()
            server = ordinary
            registry = runRegistry
            broker = DaemonRunRegistrationBroker(
                registry: runRegistry,
                dispatcher: dispatcher,
                containerDirectory: container)
            runA = try await broker.launchScopedRun(
                scope: DaemonRunScope(wikiID: wikiA.id),
                operationClasses: [.wikiRead, .wikiEdit, .wikiAcquire])
            runB = try await broker.launchScopedRun(
                scope: DaemonRunScope(wikiID: wikiB.id),
                operationClasses: [.wikiRead])
        }

        deinit {
            server.stop()
            queueStore.close()
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: container)
        }

        /// A v2 client aimed at an explicit endpoint path.
        func client(endpointPath: String) throws -> DaemonDomainSocketClient {
            try DaemonDomainSocketClient(socketPath: endpointPath, timeout: 10)
        }

        /// The authorization object carrying one run's capability.
        func authorization(_ handle: DaemonScopedRunHandle) -> DaemonDomainAuthorization {
            DaemonDomainAuthorization(capability: handle.capability.printable)
        }

        /// The runs directory the broker composes under the container.
        var runsDirectory: URL {
            container.appendingPathComponent(
                DaemonRunRegistrationBroker.runsDirectoryName, isDirectory: true)
        }
    }

    // MARK: Launch: binds + activates

    @Test("launch binds the endpoint and a credentialed scoped request completes")
    func launchBindsEndpointAndScopedRequestCompletes() async throws {
        let fixture = try await Fixture()
        let endpointPath = fixture.runA.endpointPath

        // The endpoint file exists, under the runs directory the broker made.
        #expect(FileManager.default.fileExists(atPath: endpointPath))
        #expect(endpointPath.hasPrefix(fixture.runsDirectory.path + "/"))
        #expect(endpointPath.hasSuffix(DaemonRunRegistrationBroker.endpointFileSuffix))
        // The path is opaque: NOT the run id.
        #expect(!endpointPath.contains(fixture.runA.runID.rawValue))

        // End-to-end: credentialed v2 page list over the REAL listener.
        let reply = try await fixture.client(endpointPath: endpointPath).send(
            family: .page,
            operation: DaemonDomainOperation.Page.list,
            payload: try JSONEncoder().encode(DaemonPageListRequest(
                wikiID: fixture.wikiA.id.rawValue, json: true)),
            authorization: fixture.authorization(fixture.runA))
        #expect(reply.error == nil)
        #expect(reply.payload != nil)

        // The lease is active and carries its endpoint identity.
        let lease = await fixture.registry.lease(for: fixture.runA.runID)
        #expect(lease?.state == .active)
        #expect(lease?.endpointName != nil)
        #expect(
            endpointPath.contains(lease?.endpointName?.rawValue ?? "name-missing"))
    }

    @Test("scoped enqueue through the run endpoint persists the wiki job")
    func scopedEnqueueThroughRunEndpointPersistsWikiJob() async throws {
        let fixture = try await Fixture()
        let reply = try await fixture.client(endpointPath: fixture.runA.endpointPath).send(
            family: .queue,
            operation: DaemonDomainOperation.Queue.enqueueItem,
            payload: try JSONEncoder().encode(QueueItemRequest(
                queue: .extraction,
                wikiID: fixture.wikiA.id,
                payload: QueueItemPayload(sourceIDs: []))),
            authorization: fixture.authorization(fixture.runA))
        #expect(reply.error == nil)
        // Parent-side verification: the job landed for the ASSIGNED wiki.
        let active = try fixture.queueStore.loadActive(for: .extraction)
        #expect(active.contains { $0.wikiID == fixture.wikiA.id })
    }

    // MARK: Bind exclusivity

    @Test("a second bind of a live endpoint fails closed")
    func secondBindOfLiveEndpointFailsClosed() async throws {
        let fixture = try await Fixture()
        // A sibling listener on the SAME path: the pre-existing socket file
        // makes the bind fail (no stale-unlink for run endpoints).
        do {
            let listener = try DaemonRunSocketListener(
                runID: fixture.runA.runID,
                endpointPath: fixture.runA.endpointPath,
                dispatcher: DaemonDomainSocketDispatcher(
                    daemon: WikiDaemon(containerDirectory: fixture.container)))
            try listener.start()
            Issue.record("a second bind of a live endpoint must fail")
        } catch let error as SearchSocketError {
            guard case .endpointInUse(let path) = error else {
                Issue.record("expected endpointInUse, got \(error)")
                return
            }
            #expect(path == fixture.runA.endpointPath)
        }
        // And a plain FILE at the path is just as closed — leftovers are
        // never resurrected (unlike the ordinary socket's stale cleanup).
        let leftover = fixture.runsDirectory
            .appendingPathComponent("leftover.sock")
        try Data().write(to: leftover)
        do {
            let name = DaemonRunEndpointName(rawValue: "leftover")
            let path = DaemonRunRegistrationBroker.endpointPath(
                inContainerDirectory: fixture.container, name: name)
            // Compose the leftover THROUGH the broker's layout so the path
            // is exactly what a rebinding would use.
            #expect(path == leftover.path)
            let listener = try DaemonRunSocketListener(
                runID: fixture.runA.runID,
                endpointPath: path,
                dispatcher: DaemonDomainSocketDispatcher(
                    daemon: WikiDaemon(containerDirectory: fixture.container)))
            try listener.start()
            Issue.record("binding over a leftover file must fail")
        } catch let error as SearchSocketError {
            guard case .endpointInUse = error else {
                Issue.record("expected endpointInUse, got \(error)")
                return
            }
        }
    }

    // MARK: Revocation

    @Test("revocation unlinks the endpoint idempotently and revokes the lease")
    func revocationUnlinksEndpointIdempotently() async throws {
        let fixture = try await Fixture()
        let endpointPath = fixture.runA.endpointPath
        #expect(FileManager.default.fileExists(atPath: endpointPath))
        #expect(await fixture.broker.hasListener(runID: fixture.runA.runID))

        await fixture.broker.revoke(runID: fixture.runA.runID)
        #expect(!FileManager.default.fileExists(atPath: endpointPath))
        let stillHasListener = await fixture.broker.hasListener(runID: fixture.runA.runID)
        #expect(!stillHasListener)
        let lease = await fixture.registry.lease(for: fixture.runA.runID)
        #expect(lease?.state == .revoked)

        // Idempotent: a second revoke (and an unknown run) settle quietly.
        await fixture.broker.revoke(runID: fixture.runA.runID)
        await fixture.broker.revoke(
            runID: DaemonRunID(rawValue: "never-registered"))
        #expect(!FileManager.default.fileExists(atPath: endpointPath))

        // After revocation the endpoint answers ENOENT — the explicit
        // daemon-not-running signal, never a served request.
        do {
            _ = try await fixture.client(endpointPath: endpointPath).send(
                family: .page,
                operation: DaemonDomainOperation.Page.list,
                payload: try JSONEncoder().encode(DaemonPageListRequest(
                    wikiID: fixture.wikiA.id.rawValue, json: true)),
                authorization: fixture.authorization(fixture.runA))
            Issue.record("a revoked endpoint must not serve requests")
        } catch let error as SearchSocketError {
            #expect(error.isDaemonNotRunning)
        }
        // The OTHER run's endpoint is untouched.
        #expect(FileManager.default.fileExists(atPath: fixture.runB.endpointPath))
    }

    // MARK: Cross-run isolation over real listeners

    @Test("a foreign run's capability is invalid on the assigned endpoint")
    func foreignRunCapabilityIsInvalidOnAssignedEndpoint() async throws {
        let fixture = try await Fixture()
        do {
            _ = try await fixture.client(endpointPath: fixture.runA.endpointPath).send(
                family: .page,
                operation: DaemonDomainOperation.Page.list,
                payload: try JSONEncoder().encode(DaemonPageListRequest(
                    wikiID: fixture.wikiA.id.rawValue, json: true)),
                authorization: fixture.authorization(fixture.runB))
            Issue.record("run B's capability must not pass run A's endpoint")
        } catch let error as DaemonDomainError {
            #expect(error.code == .authorizationInvalid)
        }
    }

    // MARK: Length budget (#1468)

    @Test("an endpoint path that cannot fit sockaddr_un fails before registration")
    func overlongEndpointPathFailsBeforeRegistration() async throws {
        let fixture = try await Fixture()
        // A container whose path leaves no budget for `r/<name>.sock`. The
        // path is composed IN MEMORY only — the gate fires before any
        // filesystem work or lease exists (§4: validate BEFORE registration).
        let deep = fixture.container
            .appendingPathComponent(String(repeating: "d/", count: 40))
        let overlong = DaemonRunRegistrationBroker.endpointPath(
            inContainerDirectory: deep,
            name: DaemonRunEndpointName(rawValue: "aa"))
        #expect(overlong.utf8.count > SearchSocketWire.maxPathBytes)

        let countBefore = await fixture.registry.runCount()
        // The dispatcher argument is never reached: the length gate throws
        // first, so a dispatcher over the fixture daemon is fine here.
        let broker = DaemonRunRegistrationBroker(
            registry: fixture.registry,
            dispatcher: DaemonDomainSocketDispatcher(
                daemon: WikiDaemon(containerDirectory: fixture.container)),
            containerDirectory: deep)
        do {
            _ = try await broker.launchScopedRun(
                scope: DaemonRunScope(wikiID: fixture.wikiA.id),
                operationClasses: [.wikiRead])
            Issue.record("an overlong endpoint path must fail the launch")
        } catch let error as SearchSocketError {
            guard case .pathTooLong(let limit, let actual) = error else {
                Issue.record("expected pathTooLong, got \(error)")
                return
            }
            // The broker's path carries a GENERATED 16-char endpoint name
            // (base64url), so `actual` exceeds even the "aa"-named probe
            // path — both are far over the budget, which is the point.
            #expect(limit == SearchSocketWire.maxPathBytes)
            #expect(actual > SearchSocketWire.maxPathBytes)
            #expect(actual >= overlong.utf8.count)
            // Operator-actionable guidance (#1468): names the fix.
            #expect(error.errorDescription?.contains("App Group") == true)
        }
        let countAfter = await fixture.registry.runCount()
        #expect(countAfter == countBefore, "no lease may exist after a failed launch")
    }

    /// The W3 live gate's dedicated eval container
    /// (`group.eval.selfdrivingwiki.lintgate`) is 9 bytes longer than the
    /// operator's App Group id. At the reference home layout its container
    /// prefix is 76 bytes, leaving only 103 - 76 = 27 bytes for the
    /// `r/<name>.sock` leaf — and the old 24-char hex leaf (32 with the
    /// separators) overflowed it, so EVERY scoped-run registration in the
    /// eval container failed `pathTooLong` and the lint agent never
    /// launched. The base64url leaf (16 chars, 22 with separators) fits with
    /// room to spare while keeping the same 96 random bits.
    @Test("a generated endpoint name fits the eval container's path budget")
    func generatedNameFitsTheEvalContainerBudget() throws {
        let name = try DaemonRunEndpointName.generate()
        // Base64url of 12 random bytes: exactly 16 characters, no padding.
        #expect(name.rawValue.count == 16)
        // A container whose prefix matches the eval container's 76-byte
        // reference length leaves 27 bytes for the leaf; the composed path
        // must fit the sockaddr_un budget. (Absolute, so the broker's path
        // standardization cannot prepend a working directory.)
        let evalSizedContainer = URL(
            fileURLWithPath: "/" + String(repeating: "c", count: 75))
        let path = DaemonRunRegistrationBroker.endpointPath(
            inContainerDirectory: evalSizedContainer, name: name)
        // 76-byte container + "/r/" (the runs directory joins with a
        // trailing slash) + the 16-char name + ".sock".
        #expect(path.utf8.count == 76 + 3 + 16 + 5)
        #expect(path.utf8.count <= SearchSocketWire.maxPathBytes)
    }
}
#endif
