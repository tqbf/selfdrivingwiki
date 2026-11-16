#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes
@testable import wikid

// Phase 2d slice 1 (plans/daemon-only-access.md): the RemoteWikiStore CLIENT
// — the `WikiStore` conformer that speaks the daemon's structured store
// family. These tests drive the REAL paths:
//
// - the REAL domain socket (`DaemonDomainSocketDispatcher` +
//   `DaemonSearchSocketServer` + `DaemonDomainSocketClient`) for the op
//   round trips — handshake barrier, reads, stamped mutators, cursor
//   continuation, staged uploads, handle downloads, typed error
//   reconstruction, and the daemon-restart epoch-mismatch leg;
// - the in-process executor with the sink registration id threaded (the
//   same correlation the XPC exporter performs) for the event feed — the
//   domain socket has no reverse-push channel yet, so live store events
//   arrive through the registered `WikiDaemonEventSink` (the store itself).
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, and
// waiting is a non-blocking poll — no test blocks a cooperative pool thread.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct RemoteWikiStoreTests {

    // MARK: - Fixtures

    private func makeContainer() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rws-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        return container
    }

    private func makeDaemon(_ container: URL) -> WikiDaemon {
        WikiDaemon(containerDirectory: container)
    }

    private func fixtureWiki(
        _ daemon: WikiDaemon, name: String = "Remote Store Fixture"
    ) throws -> WikiID {
        let data = try #require(daemon.testFixtureCreateWiki(name: name))
        return try JSONDecoder().decode(WikiDescriptor.self, from: data).id
    }

    /// The real domain-socket path: dispatcher + framed socket server +
    /// `DomainSocketStoreTransport` around `DaemonDomainSocketClient`.
    private func makeSocketServer(
        _ container: URL, _ daemon: WikiDaemon
    ) throws -> DaemonSearchSocketServer {
        let dispatcher = DaemonDomainSocketDispatcher(daemon: daemon)
        let server = try DaemonSearchSocketServer(containerDirectory: container) {
            data in
            await dispatcher.handle(data)
        }
        try server.start()
        return server
    }

    private func socketTransport(
        _ container: URL, timeout: TimeInterval = 30
    ) throws -> DomainSocketStoreTransport {
        DomainSocketStoreTransport(client: try DaemonDomainSocketClient(
            containerDirectory: container, timeout: timeout))
    }

    /// The in-process executor path with sink correlation — the same
    /// `sinkRegistrationID` threading the XPC exporter performs for a
    /// registered connection (`WikiDaemon.storeOperation`).
    private struct ExecutorTransport: RemoteWikiStoreTransport {
        let daemon: WikiDaemon
        let boundSinkRegistrationID: UUID?

        var connectionIdentifier: String? { nil }

        func send(
            _ request: DaemonDomainRequest,
            sinkRegistrationID: UUID?
        ) async throws -> DaemonDomainReply {
            await daemon.storeCommandExecutor().handleStoreOperation(
                request,
                sinkRegistrationID: sinkRegistrationID ?? boundSinkRegistrationID)
        }
    }

    /// Seed one page through the daemon's admitted store seam.
    @discardableResult
    private func commitPage(
        _ daemon: WikiDaemon, wikiID: WikiID, title: String, body: String = "seed body"
    ) async throws -> WikiPage {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        return try await store.createPage(
            title: title, body: body, createdBy: nil, provenance: [])
    }

    /// Non-blocking completion poll (AGENTS.md #1051).
    private func waitFor(
        _ condition: @Sendable () -> Bool,
        what: String,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Lock-guarded bus recorder (handlers run on the main actor).
    private final class BusRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []

        func record(_ event: ResourceChangeEvent) {
            lock.withLock { events.append(event) }
        }

        func snapshot() -> [ResourceChangeEvent] {
            lock.withLock { events }
        }
    }

    // MARK: - Handshake barrier + read round trip (real socket)

    @Test func firstOperationWaitsForTheHandshakeBarrierAndCachesTheEpoch()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let store = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        // No session yet: the epoch is uncached.
        #expect(store.sessionEpoch() == nil)

        // The read BLOCKS until the acknowledged handshake completes, then
        // answers through the executor. The fixture wiki seeds a Home page.
        let resolved = try await store.resolveTitleToID("Home")
        #expect(resolved != nil)
        #expect(store.sessionEpoch() == daemon.daemonEpoch)

        // A second read rides the cached session (still correct).
        let resolvedAgain = try await store.resolveTitleToID("No Such Title")
        #expect(resolvedAgain == nil)
    }

    @Test func getPageDownloadsTheBodyThroughThePayloadHandle()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let body = "Remote body αβγ\n\nsecond paragraph"
        let seeded = try await commitPage(daemon, wikiID: wikiID, title: "Handle Page", body: body)

        let store = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let page = try await store.getPage(id: seeded.id)
        #expect(page.id == seeded.id)
        #expect(page.title == "Handle Page")
        #expect(page.bodyMarkdown == body)
        #expect(page.version >= 1)
    }

    // MARK: - Stamped mutator (small family echo)

    @Test func setMetadataStampsTheMutationAndEchoesThroughReads()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let store = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        try await store.setMetadata("remote-flag", value: "on")
        #expect(try await store.getMetadata("remote-flag") == "on")
        // Overwrite (the store-side upsert semantics).
        try await store.setMetadata("remote-flag", value: "off")
        #expect(try await store.getMetadata("remote-flag") == "off")
    }

    // MARK: - Cursor continuation (list family)

    @Test func listPagesContinuesThroughTheCursorWhenTheBudgetForcesPages()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        // ~200 pages whose summaries each encode ≈9 KB (long titles), so
        // the daemon's 1 MiB page budget forces ≥2 pages and the cursor
        // continuation is REQUIRED to see every page. Ordinal continuation:
        // the store's own ordering.
        let seeded = 200
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        for index in 0..<seeded {
            _ = try await store.createPage(
                title: "Cursor Fill \(String(format: "%04d", index)) "
                    + String(repeating: "x", count: 8_900),
                body: "cursor body", createdBy: nil, provenance: [])
        }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let pages = try await remote.listPages(sortBy: .titleAZ)
        // 200 seeded + the fixture's Home page. A broken pageToken round
        // trip would stop after the first ~115-item page.
        #expect(pages.count == seeded + 1)
        #expect(pages.contains { $0.title == "Home" })
    }

    @Test func listChatsWalksItsCursorAndCarriesCreatedChats()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let chat = try await remote.createChat(kind: .edit, title: "Remote Chat")
        #expect(chat.title == "Remote Chat")
        #expect(chat.messageCount == 0)

        let chats = try await remote.listChats()
        #expect(chats.map(\.id).contains(chat.id))
    }

    // MARK: - Blob family: staged upload + consume, handle download

    @Test func upsertPageStagesAMultiChunkBodyAndCommitsAtomically()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        // 1.2 MiB raw body → two ordered, hash-checked chunks through
        // payloadBegin/payloadChunk/payloadCommit, then one atomic
        // `upsertPage` consuming the committed handle.
        let body = String(repeating: "remote-body-", count: 114_000)
        #expect(body.utf8.count > DaemonStoreLimits.maxChunkBytes)

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let outcome = try await remote.upsertPage(
            id: nil, title: "Staged Page", rawBody: body,
            expectation: .expectedAbsence, author: "remote-store-tests",
            provenance: [])
        #expect(outcome.didCreate)

        let page = try await remote.getPage(id: outcome.id)
        #expect(page.bodyMarkdown == body)
        #expect(page.createdBy == "remote-store-tests")
    }

    @Test func upsertPageExpectedHeadConflictReconstructsTheCASValues()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let outcome = try await remote.upsertPage(
            id: nil, title: "CAS Page", rawBody: "v1",
            expectation: .expectedAbsence, author: nil, provenance: [])
        let head = try await remote.pageHeadVersionID(pageID: outcome.id)
        #expect(head != nil)

        // CAS with a stale head: the executor's typed rejection crosses the
        // wire and reconstructs with BOTH version ids intact.
        let stale = PageVersionID(rawValue: "01STALE0000000000000000ZZ")
        do {
            _ = try await remote.upsertPage(
                id: outcome.id, title: "CAS Page", rawBody: "v2",
                expectation: .expectedHead(stale), author: nil, provenance: [])
            Issue.record("expected the stale-head write to throw")
        } catch let error as PageConflictError {
            #expect(error.pageID == outcome.id)
            #expect(error.expectedVersionID == stale)
            #expect(error.actualVersionID == head)
        }
    }

    // MARK: - addSource (composed atomic) + duplicateContent

    @Test func addSourceRoundTripsAndDuplicateContentCarriesTheExistingRow()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let bytes = Data("the very same bytes\n".utf8)
        let summary = try await remote.addSource(
            filename: "dup.txt", data: bytes)
        #expect(summary.filename == "dup.txt")
        #expect(summary.byteSize == bytes.count)
        #expect(summary.ext == "txt")

        do {
            _ = try await remote.addSource(filename: "dup.txt", data: bytes)
            Issue.record("expected the byte-identical addSource to throw")
        } catch let error as WikiStoreError {
            guard case .duplicateContent(let existing) = error else {
                Issue.record("expected .duplicateContent, got \(error)")
                return
            }
            #expect(existing.id == summary.id)
        }
    }

    // MARK: - deleteResources (composed atomic) + notFound

    @Test func deleteResourcesSucceedsAndAMissingPageReadsNotFound()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let outcome = try await remote.upsertPage(
            id: nil, title: "Doomed Page", rawBody: "bye",
            expectation: .expectedAbsence, author: nil, provenance: [])

        let result = try await remote.deleteResources(
            ResourceDeletionRequest(
                targets: [.page(outcome.id)], linkPolicy: .preserve))
        #expect(result.deletedTargets == [.page(outcome.id)])

        // The typed not-found reconstruction: the page id crosses intact.
        do {
            _ = try await remote.getPage(id: outcome.id)
            Issue.record("expected the deleted page read to throw")
        } catch WikiStoreError.notFound(let id) {
            #expect(id == outcome.id)
        }
    }

    // MARK: - Pending surface + ledger

    @Test func pendingAndRemovedRequirementsRejectTyped() async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)

        // A pending rpc op: typed rejection carrying the operation name —
        // no session, no round trip.
        do {
            _ = try await remote.listSources()
            Issue.record("expected listSources to reject typed")
        } catch let error as RemoteStoreClientError {
            #expect(error == .unsupportedRemote(operation: "listSources"))
        }
        // A deliberately removed requirement: the same typed witness.
        do {
            _ = try await remote.deletePage(id: PageID(rawValue: "01J0000000000000000000000DE"))
            Issue.record("expected deletePage to reject typed")
        } catch let error as RemoteStoreClientError {
            #expect(error == .unsupportedRemote(operation: "deletePage"))
        }

        // The SLICE-2 LEDGER partitions, pinned exactly.
        #expect(RemoteWikiStore.wiredOperations.count == 13)
        #expect(RemoteWikiStore.removedOperations.count == 15)
        #expect(RemoteWikiStore.wiredOperations.isDisjoint(
            with: RemoteWikiStore.removedOperations))
        #expect(RemoteWikiStore.wiredOperations == [
            "resolveTitleToID", "hasProcessedMarkdown", "getMetadata",
            "pageHeadVersionID", "setMetadata",
            "listPages", "listChats", "deletionImpact",
            "getPage", "upsertPage", "addSource",
            "createChat", "deleteResources",
        ])
    }

    // MARK: - Error reconstruction (the exhaustive inverse of wireError)

    @Test func reconstructionCoversEveryWireErrorCaseWithValuesIntact()
        throws {
        let sourceID = SourceID(rawValue: "01SRCE0000000000000000AA")
        let pageID = PageID(rawValue: "01PAGE0000000000000000AA")
        let versionID = PageVersionID(rawValue: "01PAGEVER000000000000000B")

        func reconstruct(_ wire: DaemonStoreError) -> Error {
            RemoteWikiStore(
                transport: ExecutorTransport(
                    daemon: makeDaemon(try! makeContainer()),
                    boundSinkRegistrationID: nil),
                wikiID: WikiID(rawValue: "01WIKI0000000000000000AA")
            ).reconstructStoreError(wire)
        }

        // Store error mirrors → same-typed core cases.
        func expectStoreError(
            _ wire: DaemonStoreError,
            matches matcher: (WikiStoreError) -> Bool,
            _ label: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            guard let storeError = reconstruct(wire) as? WikiStoreError else {
                Issue.record(
                    "\(label): expected a WikiStoreError reconstruction",
                    sourceLocation: sourceLocation)
                return
            }
            if !matcher(storeError) {
                Issue.record(
                    "\(label): reconstructed \(storeError) with wrong values",
                    sourceLocation: sourceLocation)
            }
        }

        expectStoreError(.open("no file"), matches: { if case .open("no file") = $0 { return true }; return false }, "open")
        expectStoreError(.sqlite(code: 14, message: "unable to open"), matches: { if case .sqlite(14, "unable to open") = $0 { return true }; return false }, "sqlite")
        expectStoreError(.notFound(pageID.rawValue), matches: { if case .notFound(pageID) = $0 { return true }; return false }, "notFound")
        expectStoreError(.chatNotFound("01CHAT000000000000000000A"), matches: { if case .chatNotFound(ChatID(rawValue: "01CHAT000000000000000000A")) = $0 { return true }; return false }, "chatNotFound")
        expectStoreError(.sourceNotFound(sourceID.rawValue), matches: { if case .sourceNotFound(sourceID) = $0 { return true }; return false }, "sourceNotFound")
        expectStoreError(.sourceVersionNotFound("01SRCVER000000000000000AA"), matches: { if case .sourceVersionNotFound(SourceVersionID(rawValue: "01SRCVER000000000000000AA")) = $0 { return true }; return false }, "sourceVersionNotFound")
        expectStoreError(.sourceMarkdownVersionNotFound("01SRCMDV00000000000000AA"), matches: { if case .sourceMarkdownVersionNotFound(SourceMarkdownVersionID(rawValue: "01SRCMDV00000000000000AA")) = $0 { return true }; return false }, "sourceMarkdownVersionNotFound")
        expectStoreError(.noProcessedMarkdown(sourceID.rawValue), matches: { if case .noProcessedMarkdown(sourceID) = $0 { return true }; return false }, "noProcessedMarkdown")
        expectStoreError(.invalidBookmarkRow(id: "b1", reason: "bad"), matches: { if case .invalidBookmarkRow(id: "b1", reason: "bad") = $0 { return true }; return false }, "invalidBookmarkRow")
        expectStoreError(.invalidRendererEventID("raw"), matches: { if case .invalidRendererEventID("raw") = $0 { return true }; return false }, "invalidRendererEventID")
        expectStoreError(.unexpected("boom"), matches: { if case .unexpected("boom") = $0 { return true }; return false }, "unexpected")

        // duplicateContent: the existing source row crosses INTACT.
        let summary = DaemonSourceSummary(
            id: sourceID.rawValue, filename: "a.txt", ext: "txt",
            mimeType: "text/plain", byteSize: 5, createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), version: 1, role: "primary")
        guard case .duplicateContent(let existing) =
            reconstruct(.duplicateContent(summary)) as? WikiStoreError else {
            Issue.record("expected .duplicateContent reconstruction")
            return
        }
        #expect(existing.id == sourceID)
        #expect(existing.filename == "a.txt")
        #expect(existing.byteSize == 5)
        #expect(existing.mimeType == "text/plain")

        // duplicateURL: same mirror shape, distinct case identity.
        guard case .duplicateURL = reconstruct(.duplicateURL(summary))
            as? WikiStoreError else {
            Issue.record("expected .duplicateURL reconstruction")
            return
        }

        // deletionRestricted: blockers in deterministic order, ids rebuilt
        // into their typed namespaces.
        let blockers = DaemonDeletionBlockers(ordered: [
            DaemonProvenanceDeletionBlocker(
                sourceID: sourceID.rawValue,
                pageVersionID: versionID.rawValue, pageID: pageID.rawValue),
        ])
        guard case .deletionRestricted(.provenance(let restriction)) =
            reconstruct(.deletionRestricted(blockers)) as? WikiStoreError else {
            Issue.record("expected .deletionRestricted reconstruction")
            return
        }
        #expect(restriction.values.count == 1)
        #expect(restriction.values.first?.sourceID == sourceID)
        #expect(restriction.values.first?.pageID == pageID)
        #expect(restriction.values.first?.pageVersionID == versionID)

        // CAS family → the dedicated error structs, values intact.
        let conflict = reconstruct(.pageConflict(DaemonPageConflictDetail(
            pageID: pageID.rawValue, expectedVersionID: "01E",
            actualVersionID: "01A"))) as? PageConflictError
        #expect(conflict?.pageID == pageID)
        #expect(conflict?.expectedVersionID == PageVersionID(rawValue: "01E"))
        #expect(conflict?.actualVersionID == PageVersionID(rawValue: "01A"))

        let createConflict = reconstruct(.pageCreateConflict(
            DaemonPageCreateConflictDetail(
                pageID: pageID.rawValue, title: "T", actualVersionID: nil)))
            as? PageCreateConflictError
        #expect(createConflict?.pageID == pageID)
        #expect(createConflict?.title == "T")
        #expect(createConflict?.actualVersionID == nil)

        let targetMissing = reconstruct(.pageExpectedTargetMissing(
            DaemonPageExpectedTargetMissingDetail(
                pageID: nil, expectedHeadVersionID: "01H", title: "Gone")))
            as? PageExpectedTargetMissingError
        #expect(targetMissing?.pageID == nil)
        #expect(targetMissing?.expectedHead == PageVersionID(rawValue: "01H"))
        #expect(targetMissing?.title == "Gone")

        let strategyConflict = reconstruct(.strategyRevisionConflict(
            DaemonStrategyConflictDetail(
                expectedRevision: 3, currentRevision: 4, currentStrategy: nil)))
            as? WikiStrategyConflictError
        #expect(strategyConflict?.expectedRevision == WikiStrategyRevision(rawValue: 3))
        #expect(strategyConflict?.currentRevision == WikiStrategyRevision(rawValue: 4))

        let markdownConflict = reconstruct(.sourceMarkdownConflict(
            DaemonSourceMarkdownConflictDetail(
                sourceID: sourceID.rawValue, expectedHead: "01MH",
                currentHead: nil))) as? SourceMarkdownConflictError
        #expect(markdownConflict?.sourceID == sourceID)
        #expect(markdownConflict?.expectedHead
            == SourceMarkdownVersionID(rawValue: "01MH"))
        #expect(markdownConflict?.currentHead == nil)

        // The epoch-mismatch text the executor spells inside `.unexpected`
        // parses into the typed restart detection with BOTH epochs intact.
        guard case .epochMismatch(let expected, let actual, _) =
            reconstruct(.unexpected(
                "daemon epoch mismatch: the submission expects 7 but this "
                    + "daemon is at 9; a restarted daemon never replays a "
                    + "stamped mutation — re-read state and resubmit with a "
                    + "new requestID")) as? RemoteStoreClientError else {
            Issue.record("expected the epoch mismatch to reconstruct typed")
            return
        }
        #expect(expected == 7)
        #expect(actual == 9)

        // A plain `.unexpected` stays an `.unexpected` (no false-positive
        // epoch detection).
        expectStoreError(.unexpected("boom"), matches: { if case .unexpected("boom") = $0 { return true }; return false }, "unexpected stays unexpected")

        // Transport-level pair.
        #expect(reconstruct(.daemonUnavailable("down"))
            as? RemoteStoreClientError == .daemonUnavailable("down"))
        #expect(reconstruct(.outcomeUnknown("evicted"))
            as? RemoteStoreClientError == .outcomeUnknown("evicted"))
    }

    // MARK: - Event feed (in-process sink correlation)

    @Test func oneCommitFeedsExactlyOneBusEventAfterTheHandshakeBarrier()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)

        let recorder = BusRecorder()
        let remote = RemoteWikiStore(
            transport: ExecutorTransport(daemon: daemon, boundSinkRegistrationID: nil),
            wikiID: wikiID)
        let bus = WikiEventBus(wikiID: wikiID)
        remote.eventBus = bus
        _ = bus.subscribe(nil) { [recorder] event in
            recorder.record(event)
        }

        // The store IS the connection's sink (the app wiring's shape); the
        // registration id the daemon assigned is what the handshake must
        // correlate — the exporter threads the connection's own id, never
        // one the client invents.
        let registrationID = daemon.registerEventSink(remote)
        remote.registerSink(registrationID: registrationID)
        try await remote.warmSession()

        // One commit → exactly one bus event (the fixture's seeded Home
        // event replays first: sequences 1, then 2 for our commit).
        try await commitPage(daemon, wikiID: wikiID, title: "Bus Commit")
        try await waitFor(
            { recorder.snapshot().count >= 2 },
            what: "the Home replay + the commit to reach the bus")
        // Settle: no further deliveries may arrive (dedupe keeps it at 2).
        try await Task.sleep(for: .milliseconds(300))
        let events = recorder.snapshot()
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == .page && $0.change == .created })
        #expect(events.allSatisfy { $0.wikiID == wikiID })
    }

    @Test func deliverEventDeduplicatesByWatermarkAndNeverAcrossEpochs()
        async throws {
        let container = try makeContainer()
        let daemon = makeDaemon(container)
        let wikiID = try fixtureWiki(daemon)

        let recorder = BusRecorder()
        let remote = RemoteWikiStore(
            transport: ExecutorTransport(daemon: daemon, boundSinkRegistrationID: nil),
            wikiID: wikiID)
        let bus = WikiEventBus(wikiID: wikiID)
        remote.eventBus = bus
        _ = bus.subscribe(nil) { [recorder] event in
            recorder.record(event)
        }
        // Live phase (barrier via the executor; no sink correlation here —
        // the handshake answers watermarks without flipping any sink).
        try await remote.warmSession()

        func envelope(epoch: UInt64, sequence: UInt64) throws -> Data {
            try JSONEncoder().encode(DaemonStoreEventEnvelope(event: DaemonStoreEvent(
                epoch: epoch,
                wikiID: wikiID.rawValue,
                sequence: sequence,
                changeToken: "tok-\(epoch)-\(sequence)",
                batch: [DaemonResourceChangeEvent(
                    kind: "page", id: "01PAGE0000000000000000ZZ",
                    change: "created", seq: sequence)])))
        }

        remote.deliverEvent(try envelope(epoch: daemon.daemonEpoch, sequence: 10))
        // EXACT DUPLICATE: `sequence <=` watermark → dropped.
        remote.deliverEvent(try envelope(epoch: daemon.daemonEpoch, sequence: 10))
        try await waitFor(
            { recorder.snapshot().count == 1 },
            what: "the first delivery to reach the bus")
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.snapshot().count == 1)

        // EPOCH CHANGE: the new epoch's sequence 1 is NEVER read as a
        // duplicate of the old epoch's higher sequence.
        remote.deliverEvent(try envelope(epoch: daemon.daemonEpoch + 1, sequence: 1))
        try await waitFor(
            { recorder.snapshot().count == 2 },
            what: "the new-epoch event to reach the bus")
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.snapshot().count == 2)
    }

    // MARK: - Daemon restart: typed epoch mismatch + recovery

    /// A lock-guarded swappable dispatcher so one socket path can outlive a
    /// daemon "restart" (fresh daemon instance = fresh epoch).
    private final class DispatcherBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: DaemonDomainSocketDispatcher

        init(_ dispatcher: DaemonDomainSocketDispatcher) {
            current = dispatcher
        }

        func swap(_ dispatcher: DaemonDomainSocketDispatcher) {
            lock.withLock { current = dispatcher }
        }

        func handle(_ data: Data) async -> Data {
            let dispatcher = lock.withLock { current }
            return await dispatcher.handle(data)
        }
    }

    @Test func daemonRestartSurfacesTypedEpochMismatchThenRecovers()
        async throws {
        let container = try makeContainer()
        let daemonA = makeDaemon(container)
        let wikiID = try fixtureWiki(daemonA, name: "Restart Fixture")

        let box = DispatcherBox(DaemonDomainSocketDispatcher(daemon: daemonA))
        let server = try DaemonSearchSocketServer(containerDirectory: container) {
            data in
            await box.handle(data)
        }
        try server.start()

        let remote = RemoteWikiStore(
            transport: try socketTransport(container, timeout: 20),
            wikiID: wikiID)
        // Session epoch A is cached.
        try await remote.setMetadata("restart-key", value: "before")
        let epochA = try #require(remote.sessionEpoch())
        #expect(epochA == daemonA.daemonEpoch)

        // RESTART: daemon A stops serving; a fresh daemon instance claims
        // the socket and the next global epoch.
        server.stop()
        let daemonB = makeDaemon(container)
        #expect(daemonB.daemonEpoch != epochA)
        // The fresh daemon hosts the SAME wiki (shared registry + DB).
        _ = try await daemonB.domainCommandStore(wikiID: wikiID)
        box.swap(DaemonDomainSocketDispatcher(daemon: daemonB))
        let serverB = try DaemonSearchSocketServer(containerDirectory: container) {
            data in
            await box.handle(data)
        }
        try serverB.start()
        defer { serverB.stop() }

        // The stale stamp is rejected at the epoch gate; the rejection
        // reconstructs TYPED with both epochs — restart detection is a
        // `catch`, not a substring hunt.
        do {
            try await remote.setMetadata("restart-key", value: "after")
            Issue.record("expected the stale-epoch mutation to throw")
        } catch let error as RemoteStoreClientError {
            guard case .epochMismatch(let expected, let actual, _) = error else {
                Issue.record("expected .epochMismatch, got \(error)")
                return
            }
            #expect(expected == epochA)
            #expect(actual == daemonB.daemonEpoch)
        }

        // The store clears its session: the NEXT mutation re-handshakes
        // against daemon B and commits.
        try await remote.setMetadata("restart-key", value: "after")
        #expect(remote.sessionEpoch() == daemonB.daemonEpoch)
        #expect(try await remote.getMetadata("restart-key") == "after")
    }
}
#endif
