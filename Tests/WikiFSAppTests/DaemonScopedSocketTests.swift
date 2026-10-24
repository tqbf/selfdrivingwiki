#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
@testable import wikid

/// Scoped-run authorization over the REAL socket path (plans/
/// agent-sandbox-scoping.md §6 + §10's required matrix): actual AF_UNIX
/// connections between `DaemonDomainSocketClient` (carrying v2 envelopes
/// with the run capability) and a real `DaemonDomainSocketDispatcher` served
/// by a real `DaemonSearchSocketServer` whose handler stamps the SCOPED
/// connection context — the shape a Phase 2 run-lifetime listener will have,
/// with its run identity captured at bind time, never read from the
/// envelope.
///
/// Every denial below asserts the TYPED domain error (never a transport
/// failure) AND a generic message: no other wiki's display name, and no
/// other wiki's ULID.
///
/// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`; the
/// socket round trips carry short timeouts; no sleeps, no blocking waits.
@Suite("Daemon scoped socket authorization", .serialized, .timeLimit(.minutes(5)))
struct DaemonScopedSocketTests {

    // MARK: Fixture

    /// One disposable container with TWO registered wikis — A (the run's
    /// assigned wiki) and B (foreign) — real databases for both, a central
    /// queue database holding one item per wiki, and the scoped listener
    /// serving the assigned run. `start()` is idempotent per instance.
    final class Fixture {
        let container: URL
        let registry: DaemonRunRegistry
        let wikiA: WikiDescriptor
        let wikiB: WikiDescriptor
        let storeA: GRDBWikiStore
        let queueItemA: QueueItem
        let queueItemB: QueueItem
        /// The assigned run's registration — the ONLY copy of the printable
        /// capability, exactly as the trusted run host would receive it.
        let registration: DaemonRunRegistration
        private let server: DaemonSearchSocketServer

        init() async throws {
            // 8-char suffix: the socket path under this container must fit
            // sockaddr_un's 103-byte bound (the other daemon suites shorten
            // for the same reason).
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "dwscoped-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(
                at: container, withIntermediateDirectories: true)

            // Two registered wikis, each with its own database; B carries a
            // seeded chain the scoped run must never touch or name.
            var mutableA = WikiDescriptor.make(displayName: "Scoped A")
            var mutableB = WikiDescriptor.make(displayName: "Scoped B")
            mutableA.lastUsedAt = Date()
            mutableB.lastUsedAt = Date()
            wikiA = mutableA
            wikiB = mutableB
            var diskRegistry = WikiRegistry.load(from: container)
            diskRegistry.add(wikiA)
            diskRegistry.add(wikiB)
            try diskRegistry.save(to: container)
            storeA = try GRDBWikiStore(
                databaseURL: container.appendingPathComponent(wikiA.dbFileName, isDirectory: false))
            let storeB = try GRDBWikiStore(
                databaseURL: container.appendingPathComponent(wikiB.dbFileName, isDirectory: false))
            _ = try storeA.createPage(title: "Assigned Page", body: "in scope")
            _ = try storeB.createPage(title: "Foreign Page", body: "out of scope")

            // The central queue: one item owned by A, one by B — the
            // item-only authorization path resolves the OWNER before
            // deciding.
            let queueStore = try QueueStore(
                databaseURL: container.appendingPathComponent("queue.sqlite", isDirectory: false))
            queueItemA = try queueStore.enqueue(QueueItemRequest(
                queue: .extraction, wikiID: wikiA.id,
                payload: QueueItemPayload(sourceIDs: [])))
            queueItemB = try queueStore.enqueue(QueueItemRequest(
                queue: .extraction, wikiID: wikiB.id,
                payload: QueueItemPayload(sourceIDs: [])))
            queueStore.close()

            // The daemon + dispatcher with an INJECTED registry, and the
            // trusted owner's registration for wiki A: all three operation
            // classes, activated BEFORE the (future) child would start.
            let daemon = WikiDaemon(containerDirectory: container)
            let runRegistry = DaemonRunRegistry()
            let newRegistration = try await runRegistry.prepareRun(
                scope: DaemonRunScope(wikiID: wikiA.id),
                operationClasses: [.wikiRead, .wikiEdit, .wikiAcquire])
            try await runRegistry.activate(runID: newRegistration.runID)
            registry = runRegistry
            registration = newRegistration

            let dispatcher = DaemonDomainSocketDispatcher(
                daemon: daemon, runRegistry: runRegistry)
            let listenerRunID = newRegistration.runID
            let scopedServer = try DaemonSearchSocketServer(containerDirectory: container) {
                request in
                // The listener CAPTURED the run identity at bind time; the
                // envelope cannot change it.
                await dispatcher.handle(request, context: .scopedRun(listenerRunID))
            }
            try scopedServer.start()
            server = scopedServer
        }

        deinit {
            server.stop()
            // The container lives under the temp root; remove it (stop()
            // already unlinked the socket).
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: container)
        }

        /// A v2 client bound to the scoped listener's socket.
        func client() throws -> DaemonDomainSocketClient {
            try DaemonDomainSocketClient(containerDirectory: container, timeout: 10)
        }

        /// The authorization object carrying the assigned run's capability.
        var authorization: DaemonDomainAuthorization {
            DaemonDomainAuthorization(capability: registration.capability.printable)
        }
    }

    // MARK: Allowed traffic

    @Test("valid capability: allowed read and edit on the assigned wiki")
    func allowedReadAndEditOnAssignedWiki() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()

        // READ: page list for wiki A.
        let listReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.list,
            payload: try JSONEncoder().encode(DaemonPageListRequest(
                wikiID: fixture.wikiA.id.rawValue, json: true)),
            authorization: fixture.authorization)
        #expect(listReply.error == nil)
        #expect(listReply.payload != nil)

        // EDIT: page add for wiki A, committed through the same daemon.
        let addReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.add,
            payload: try JSONEncoder().encode(DaemonPageAddRequest(
                wikiID: fixture.wikiA.id.rawValue, id: nil, title: "Scoped Write",
                body: "authorized", expectHead: nil, createOnly: false,
                workspace: nil, author: "agent:scoped", provenance: [])),
            authorization: fixture.authorization)
        #expect(addReply.error == nil)
        let titles = try fixture.storeA.listPages(sortBy: .lastUpdated).map(\.title)
        #expect(titles.contains("Scoped Write"))

        // The assigned wiki may be named by ITS OWN display name too.
        let byName = try await client.send(
            family: .wiki,
            operation: DaemonDomainOperation.Wiki.resolveWiki,
            payload: try JSONEncoder().encode(DaemonWikiResolveRequest(
                selector: fixture.wikiA.displayName)),
            authorization: fixture.authorization)
        #expect(byName.error == nil)
    }

    // MARK: Scope violations

    @Test("wrong wiki target is a generic scope denial with no leak")
    func wrongWikiTargetIsScopeDenied() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()
        do {
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.list,
                payload: try JSONEncoder().encode(DaemonPageListRequest(
                    wikiID: fixture.wikiB.id.rawValue, json: true)),
                authorization: fixture.authorization)
            Issue.record("a wiki B target must be scope-denied")
        } catch let error as DaemonDomainError {
            #expect(error.code == .scopeDenied)
            Self.assertNoLeak(error, wikis: [fixture.wikiA, fixture.wikiB])
        }
        // B's data is untouched.
        let storeB = try GRDBWikiStore(
            databaseURL: fixture.container.appendingPathComponent(
                fixture.wikiB.dbFileName, isDirectory: false))
        #expect(try storeB.listPages(sortBy: .lastUpdated).map(\.title) == ["Foreign Page"])
    }

    @Test("foreign wiki resolution is denied without naming the wiki")
    func foreignWikiResolutionIsGenericScopeDenied() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()
        do {
            _ = try await client.send(
                family: .wiki,
                operation: DaemonDomainOperation.Wiki.resolveWiki,
                payload: try JSONEncoder().encode(DaemonWikiResolveRequest(
                    selector: fixture.wikiB.displayName)),
                authorization: fixture.authorization)
            Issue.record("resolving wiki B must be scope-denied")
        } catch let error as DaemonDomainError {
            #expect(error.code == .scopeDenied)
            Self.assertNoLeak(error, wikis: [fixture.wikiA, fixture.wikiB])
        }
        // A global enumeration is denied outright.
        do {
            _ = try await client.send(
                family: .wiki,
                operation: DaemonDomainOperation.Wiki.listWikis,
                authorization: fixture.authorization)
            Issue.record("listWikis must be scope-denied")
        } catch let error as DaemonDomainError {
            #expect(error.code == .scopeDenied)
        }
    }

    @Test("queue item owned by another wiki is scope-denied; the own item reads")
    func queueItemOwnershipIsResolvedBeforeAuthorization() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()

        // The run's OWN item reads (wikiRead).
        let own = try await client.send(
            family: .queue,
            operation: DaemonDomainOperation.Queue.queueItemState,
            payload: try JSONEncoder().encode(DaemonQueueItemStateRequest(
                itemID: fixture.queueItemA.id.rawValue)),
            authorization: fixture.authorization)
        #expect(own.error == nil)

        // B's item: the owning wiki resolves to B → generic scope denial.
        do {
            _ = try await client.send(
                family: .queue,
                operation: DaemonDomainOperation.Queue.queueItemState,
                payload: try JSONEncoder().encode(DaemonQueueItemStateRequest(
                    itemID: fixture.queueItemB.id.rawValue)),
                authorization: fixture.authorization)
            Issue.record("a queue item owned by wiki B must be scope-denied")
        } catch let error as DaemonDomainError {
            #expect(error.code == .scopeDenied)
            Self.assertNoLeak(error, wikis: [fixture.wikiA, fixture.wikiB])
        }
    }

    @Test("scoped source export is denied even for the assigned wiki (§13.3)")
    func scopedSourceExportIsDenied() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()
        do {
            _ = try await client.send(
                family: .source,
                operation: DaemonDomainOperation.Source.export,
                payload: try JSONEncoder().encode(DaemonSourceExportRequest(
                    wikiID: fixture.wikiA.id.rawValue,
                    selector: DaemonCommandSelector(id: nil, title: nil),
                    out: "/tmp/definitely-outside-the-scratch",
                    markdown: false,
                    cwd: "/tmp")),
                authorization: fixture.authorization)
            Issue.record("scoped source export must be denied")
        } catch let error as DaemonDomainError {
            #expect(error.code == .scopeDenied)
        }
    }

    @Test("global queue controls and admin maintenance are denied (§13.4)")
    func globalControlsAndAdminAreDenied() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()
        let attempts: [(DaemonDomainFamily, String, Data?)] = [
            (.queue, DaemonDomainOperation.Queue.pauseQueue,
             try JSONEncoder().encode(DaemonQueueControlRequest(queue: "extraction"))),
            (.admin, DaemonDomainOperation.Admin.vacuumAll,
             try JSONEncoder().encode(DaemonAdminRequest(
                 wikiID: fixture.wikiA.id.rawValue, dryRun: true, json: false))),
        ]
        for (family, operation, payload) in attempts {
            do {
                _ = try await client.send(
                    family: family, operation: operation, payload: payload,
                    authorization: fixture.authorization)
                Issue.record("\(family.rawValue)/\(operation) must be scope-denied")
            } catch let error as DaemonDomainError {
                #expect(error.code == .scopeDenied)
            }
        }
    }

    // MARK: Capability failures — the exact typed errors

    @Test("missing capability is authorizationRequired, never unrestricted")
    func missingCapabilityIsAuthorizationRequired() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()
        do {
            // A v2 envelope WITHOUT the authorization object.
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.list,
                payload: try JSONEncoder().encode(DaemonPageListRequest(
                    wikiID: fixture.wikiA.id.rawValue, json: true)))
            Issue.record("an uncredentialed scoped data request must not pass")
        } catch let error as DaemonDomainError {
            #expect(error.code == .authorizationRequired)
            Self.assertNoLeak(error, wikis: [fixture.wikiA, fixture.wikiB])
        }
    }

    @Test("malformed and unknown capabilities are authorizationInvalid")
    func malformedAndUnknownCapabilitiesAreInvalid() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()
        let malformed: [DaemonDomainAuthorization] = [
            DaemonDomainAuthorization(capability: "not base64!!"),
            DaemonDomainAuthorization(
                capability: Data([0x01, 0x02]).base64EncodedString()),
            // Well-formed bytes this daemon never registered.
            DaemonDomainAuthorization(
                capability: Data(repeating: 0x5A, count: 32).base64EncodedString()),
        ]
        for authorization in malformed {
            do {
                _ = try await client.send(
                    family: .page,
                    operation: DaemonDomainOperation.Page.list,
                    payload: try JSONEncoder().encode(DaemonPageListRequest(
                        wikiID: fixture.wikiA.id.rawValue, json: true)),
                    authorization: authorization)
                Issue.record("a malformed or unknown capability must not pass")
            } catch let error as DaemonDomainError {
                #expect(error.code == .authorizationInvalid)
                Self.assertNoLeak(error, wikis: [fixture.wikiA, fixture.wikiB])
            }
        }
    }

    @Test("expired and revoked capabilities are authorizationExpired")
    func expiredAndRevokedCapabilitiesAreExpired() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()

        // A second run on the same daemon: born expired (zero lifetime).
        let expired = try await fixture.registry.prepareRun(
            scope: DaemonRunScope(wikiID: fixture.wikiA.id),
            operationClasses: [.wikiRead],
            lifetime: .seconds(0))
        try await fixture.registry.activate(runID: expired.runID)
        // And a third run: active, then revoked by the owner.
        let revoked = try await fixture.registry.prepareRun(
            scope: DaemonRunScope(wikiID: fixture.wikiA.id),
            operationClasses: [.wikiRead])
        try await fixture.registry.activate(runID: revoked.runID)
        await fixture.registry.revoke(runID: revoked.runID)

        for capability in [expired.capability, revoked.capability] {
            do {
                _ = try await client.send(
                    family: .page,
                    operation: DaemonDomainOperation.Page.list,
                    payload: try JSONEncoder().encode(DaemonPageListRequest(
                        wikiID: fixture.wikiA.id.rawValue, json: true)),
                    authorization: DaemonDomainAuthorization(
                        capability: capability.printable))
                Issue.record("an expired or revoked capability must not pass")
            } catch let error as DaemonDomainError {
                #expect(error.code == .authorizationExpired)
                Self.assertNoLeak(error, wikis: [fixture.wikiA, fixture.wikiB])
            }
        }
    }

    @Test("a capability for a DIFFERENT run is invalid on this endpoint")
    func crossRunCapabilityIsInvalid() async throws {
        let fixture = try await Fixture()
        // A second scoped ENDPOINT (its own container and listener) holding
        // its own run: presenting the FIRST run's capability there is
        // invalid — the endpoint's captured identity is authoritative.
        let other = try await Fixture()
        let client = try other.client()
        do {
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.list,
                payload: try JSONEncoder().encode(DaemonPageListRequest(
                    wikiID: other.wikiA.id.rawValue, json: true)),
                authorization: fixture.authorization)
            Issue.record("a foreign run's capability must not pass this endpoint")
        } catch let error as DaemonDomainError {
            #expect(error.code == .authorizationInvalid)
        }
    }

    // MARK: Version + hello on the scoped listener

    @Test("a v1 data operation on the scoped listener is unsupportedVersion")
    func v1DataOperationOnScopedListenerIsUnsupportedVersion() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()
        do {
            // v1 envelopes cannot carry authorization; the scoped listener
            // must refuse the VERSION, not fall back to unscoped handling.
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.list,
                payload: try JSONEncoder().encode(DaemonPageListRequest(
                    wikiID: fixture.wikiA.id.rawValue, json: true)),
                version: 1)
            Issue.record("v1 must not ride a scoped listener")
        } catch let error as DaemonDomainError {
            #expect(error.code == .unsupportedVersion)
        }
    }

    @Test("an uncredentialed scoped hello reports the protocol version only")
    func uncredentialedScopedHelloIsVersionOnly() async throws {
        let fixture = try await Fixture()
        let client = try fixture.client()
        let reply = try await client.send(
            family: .hello,
            operation: DaemonDomainOperation.Hello.capabilities)
        #expect(reply.error == nil)
        let payload = try #require(reply.payload)
        let hello = try DaemonDomainWire.decodeHelloPayload(payload)
        #expect(hello.protocolVersion == DaemonDomainVersion.current)
        // NOTHING else: no served families, no build identity, no wiki data.
        #expect(hello.families.isEmpty)
        #expect(hello.appVersion == nil)
        #expect(hello.buildVersion == nil)
    }

    // MARK: Leak hygiene

    /// Every denial message must be generic: no wiki display name and no
    /// wiki ULID may appear.
    private static func assertNoLeak(
        _ error: DaemonDomainError,
        wikis: [WikiDescriptor]
    ) {
        for wiki in wikis {
            #expect(
                !error.message.contains(wiki.displayName),
                "the denial leaked a wiki name: \(error.message)")
            #expect(
                !error.message.contains(wiki.id.rawValue),
                "the denial leaked a wiki id: \(error.message)")
        }
    }
    // MARK: - Raw-frame receipt gate (plan §5.8)

    /// A repair-policy lint run's `page patch` through a RAW frame: without
    /// the daemon's current receipt it denies generically — a fabricated
    /// token, an absent token, and a patch of a non-selected page all deny
    /// identically, and the store gains no version. The mint path (a fresh
    /// selected-page `page get --json` through the same endpoint) then
    /// makes the real patch succeed, proving the denials were the policy.
    @Test("raw frames cannot patch without the run's receipt")
    func rawFramePatchRequiresReceipt() async throws {
        // One wiki, one selected page, one lint-repair run, one scoped
        // server — the same production wiring as the fixture above.
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dwreceipt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        var descriptor = WikiDescriptor.make(displayName: "Receipt Wiki")
        descriptor.lastUsedAt = Date()
        var diskRegistry = WikiRegistry.load(from: container)
        diskRegistry.add(descriptor)
        try diskRegistry.save(to: container)
        let store = try GRDBWikiStore(
            databaseURL: container.appendingPathComponent(descriptor.dbFileName, isDirectory: false))
        let page = try store.createPage(title: "Receipt Target", body: "# Target\n\nold text\n")
        let head = try #require(
            try store.readPageCoherent(id: page.id).headVersionID)

        let daemon = WikiDaemon(containerDirectory: container)
        let runRegistry = DaemonRunRegistry()
        let lintRunState = DaemonLintRunState()
        daemon.queueHostLintRunState = lintRunState
        let registration = try await runRegistry.prepareRun(
            scope: DaemonRunScope(wikiID: descriptor.id),
            operationClasses: [.wikiRead],
            operationPolicy: .lintSelectedPageRepair(pageID: page.id))
        try await runRegistry.activate(runID: registration.runID)
        let dispatcher = DaemonDomainSocketDispatcher(
            daemon: daemon, runRegistry: runRegistry, lintRunState: lintRunState)
        let listenerRunID = registration.runID
        let server = try DaemonSearchSocketServer(containerDirectory: container) { request in
            await dispatcher.handle(request, context: .scopedRun(listenerRunID))
        }
        try server.start()
        defer { server.stop() }
        let client = try DaemonDomainSocketClient(
            containerDirectory: container, timeout: 10)
        let authorization = DaemonDomainAuthorization(
            capability: registration.capability.printable)

        // The mint: the selected `page get --json` returns the receipt.
        let getReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.get,
            payload: try JSONEncoder().encode(DaemonPageGetRequest(
                wikiID: descriptor.id.rawValue,
                selector: DaemonCommandSelector(id: page.id.rawValue),
                json: true,
                workspace: nil)),
            authorization: authorization)
        let outcome = try DaemonCommandOutcome.decode(getReply.payload)
        let pageJSON = try #require(
            JSONSerialization.jsonObject(with: Data((outcome.text ?? "").utf8))
                as? [String: Any])
        let receipt = try #require(pageJSON["lint_receipt"] as? String)

        func patchReply(receiptToken: String?, pageID: String) async throws -> DaemonDomainReply {
            try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.patch,
                payload: try JSONEncoder().encode(DaemonPagePatchRequest(
                    wikiID: descriptor.id.rawValue,
                    id: pageID,
                    expectHead: head.rawValue,
                    hunks: [DaemonPagePatchRequest.WireHunk(
                        defect: "D25", startByte: 10, endByte: 18,
                        oldText: "old text", newText: "new text",
                        reason: "repair the defect")],
                    author: "agent:lint",
                    lintReceipt: receiptToken)),
                authorization: authorization)
        }

        func expectPatchDenied(
            receiptToken: String?, pageID: String, label: String
        ) async {
            do {
                _ = try await patchReply(receiptToken: receiptToken, pageID: pageID)
                Issue.record("\(label): expected a denial, but the patch was accepted")
            } catch let error as DaemonDomainError {
                #expect(error.code == DaemonDomainErrorCode.scopeDenied,
                        "\(label) must deny generically, got \(error.code.rawValue): \(error.message)")
            } catch {
                Issue.record("\(label): unexpected transport error: \(error)")
            }
        }

        // Bypasses deny with the generic scope message, and no version lands.
        await expectPatchDenied(receiptToken: nil, pageID: page.id.rawValue, label: "missing receipt")
        await expectPatchDenied(receiptToken: "forged-token", pageID: page.id.rawValue, label: "forged receipt")
        await expectPatchDenied(receiptToken: receipt, pageID: "01HZOTHER00000000000000000X", label: "non-selected page")

        // The REAL patch with the CURRENT receipt commits.
        let ok = try await patchReply(receiptToken: receipt, pageID: page.id.rawValue)
        #expect(ok.error == nil, "the receipted patch must commit: \(ok.error?.message ?? "")")
        let body = try store.readPageCoherent(id: page.id).body
        #expect(body.contains("new text"), "the hunk must be applied exactly")
        // The written-version verification record was published.
        let record = await lintRunState.latestVerificationRecord(pageID: page.id)
        #expect(record?.writtenHead != nil, "the daemon must publish the written-version verification record")
        // The replayed receipt is dead.
        await expectPatchDenied(receiptToken: receipt, pageID: page.id.rawValue, label: "replayed committed receipt")
    }
}
#endif
