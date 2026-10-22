#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
@testable import wikid

// Phase 3 of plans/cli-domain-commands.md: the read-only command families
// (`page`, `source`, `chat`, `bookmark`, `workspace`) and the queue family's
// `queueWikiItems` read (behind `wikictl job list/get`) over the REAL CLI ⇄
// daemon socket — actual AF_UNIX connections against the real
// `DaemonDomainSocketDispatcher` running over a fixture `WikiDaemon`, exactly
// as the daemon boot wires it. The daemon EXECUTES the CLI's command layer
// against its prepared store, so every assertion pins the byte-stable stdout
// the in-process path produced. The trailing `WikiCtlRunner` tests prove the
// routing seam: a registry-selected command — read OR write — never reaches
// the store executor, and a command with no daemon route fails instead of
// opening one (Phase 5: no local fallback).
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, and
// every scenario runs under a short injected timeout — never the production
// default.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct DaemonCommandSocketTests {

    // MARK: Fixtures (same shape as DaemonWikiSocketTests)

    private func makeContainer() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dcm-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    private func makeRegistryClient(container: URL) throws -> DaemonWikiRegistryClient {
        try DaemonWikiRegistryClient(containerDirectory: container, timeout: 10)
    }

    private func makeSocketClient(container: URL) throws -> DaemonDomainSocketClient {
        try DaemonDomainSocketClient(containerDirectory: container, timeout: 10)
    }

    /// A fixture wiki, the still-running socket server (the caller owns
    /// `server.stop()`), and a daemon handle for seeding. Seeds go through the
    /// daemon's own admission seam (`domainCommandStore`) — the same store the
    /// command families read — never a second open path.
    private func makeSeededWiki(
        container: URL
    ) async throws -> (
        server: DaemonSearchSocketServer,
        descriptor: WikiDescriptor,
        daemon: WikiDaemon
    ) {
        let (server, daemon) = try startDaemonSocket(container: container)
        let registry = try makeRegistryClient(container: container)
        let descriptor = try await registry.createWiki(name: "Command Fixture Wiki")
        return (server, descriptor, daemon)
    }

    private func seed(
        _ daemon: WikiDaemon, wikiID: WikiID,
        _ mutate: (WikiStore) throws -> Void
    ) async throws {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        try mutate(store)
    }

    /// Seed through the daemon store seam and return a value.
    private func seedValue<Value>(
        _ daemon: WikiDaemon, wikiID: WikiID,
        _ mutate: (WikiStore) throws -> Value
    ) async throws -> Value {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        return try mutate(store)
    }

    /// Look up the single source's id through the store read seam.
    private func sourceIDFor(
        daemon: WikiDaemon, wikiID: WikiID
    ) async throws -> SourceID {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let summaries = try store.listSources()
        guard let first = summaries.first else {
            Issue.record("expected the seeded source")
            return SourceID(rawValue: "missing")
        }
        return first.id
    }

    // MARK: - page family

    @Test func pageListAndGetRoundTripOverRealSocket() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        try await seed(daemon, wikiID: fixture.id) { store in
            _ = try store.createPage(title: "Meeting Notes", body: "decisions go here", createdBy: nil, provenance: [])
        }

        let client = try makeSocketClient(container: container)
        let listReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.list,
            payload: try JSONEncoder().encode(DaemonPageListRequest(wikiID: fixture.id.rawValue, json: false)))
        let listed = try DaemonCommandOutcome.decode(listReply.payload)
        #expect(listed.text?.contains("Meeting Notes") == true)
        #expect(listed.didCommit == false)

        let getReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.get,
            payload: try JSONEncoder().encode(DaemonPageGetRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(title: "Meeting Notes"),
                json: false)))
        let got = try DaemonCommandOutcome.decode(getReply.payload)
        #expect(got.text == "decisions go here")

        // JSON mode: body_markdown + head_version_id in one object.
        let jsonReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.get,
            payload: try JSONEncoder().encode(DaemonPageGetRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(title: "Meeting Notes"),
                json: true)))
        let jsonOutcome = try DaemonCommandOutcome.decode(jsonReply.payload)
        #expect(jsonOutcome.text?.contains("\"head_version_id\"") == true)
        #expect(jsonOutcome.text?.contains("decisions go here") == true)
    }

    @Test func pageHistoryAndInfoRoundTripOverRealSocket() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        try await seed(daemon, wikiID: fixture.id) { store in
            _ = try store.createPage(title: "Versioned Page", body: "v1 body", createdBy: nil, provenance: [])
        }

        let client = try makeSocketClient(container: container)
        let history = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.history,
            payload: try JSONEncoder().encode(DaemonPageSelectorRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(title: "Versioned Page"))))
        let historyOutcome = try DaemonCommandOutcome.decode(history.payload)
        // `seq versionID saved_at title blob_hash parent` — at least one row.
        #expect(historyOutcome.text?.contains("Versioned Page") == true)

        let info = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.info,
            payload: try JSONEncoder().encode(DaemonPageSelectorRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(title: "Versioned Page"))))
        let infoOutcome = try DaemonCommandOutcome.decode(info.payload)
        #expect(infoOutcome.text?.contains("title\tVersioned Page") == true)
        #expect(infoOutcome.text?.contains("version_count\t") == true)
    }

    @Test func pageOKFVerbsRoundTripOverRealSocket() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        try await seed(daemon, wikiID: fixture.id) { store in
            _ = try store.createPage(title: "OKF Page", body: "checked content", createdBy: nil, provenance: [])
        }

        // The head version id comes from `page get --json` — the same read an
        // agent performs before threading okf verbs.
        let client = try makeSocketClient(container: container)
        let headReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.get,
            payload: try JSONEncoder().encode(DaemonPageGetRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(title: "OKF Page"),
                json: true)))
        let headOutcome = try DaemonCommandOutcome.decode(headReply.payload)
        let headJSON = try JSONSerialization.jsonObject(
            with: Data((headOutcome.text ?? "").utf8)) as? [String: Any]
        let headVersionID = headJSON?["head_version_id"] as? String
        #expect(headVersionID?.isEmpty == false)
        guard let versionID = headVersionID else {
            Issue.record("page get --json carried no head_version_id")
            return
        }

        // INSPECT (JSON) — the projection with no status set.
        let inspectReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.okfInspect,
            payload: try JSONEncoder().encode(DaemonPageOKFInspectRequest(
                wikiID: fixture.id.rawValue, versionID: versionID, json: true)))
        let inspected = try DaemonCommandOutcome.decode(inspectReply.payload)
        #expect(inspected.text?.contains("\"status\":") == true)

        // STATUS (a sanctioned Phase 3 write through the daemon) → didCommit.
        let statusReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.okfStatus,
            payload: try JSONEncoder().encode(DaemonPageOKFStatusRequest(
                wikiID: fixture.id.rawValue, versionID: versionID, status: "draft")))
        let statusOutcome = try DaemonCommandOutcome.decode(statusReply.payload)
        #expect(statusOutcome.text == "status\tdraft")
        #expect(statusOutcome.didCommit == true)

        // FRESHNESS (--clear form: nil policy).
        let freshnessReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.okfFreshness,
            payload: try JSONEncoder().encode(DaemonPageOKFFreshnessRequest(
                wikiID: fixture.id.rawValue, versionID: versionID, policyJSON: nil)))
        let freshnessOutcome = try DaemonCommandOutcome.decode(freshnessReply.payload)
        #expect(freshnessOutcome.text == "freshness\tupdated")
        #expect(freshnessOutcome.didCommit == true)

        // VERIFY — the recorded verification id comes back.
        let verifier = try OKFVerifierIdentity("human:tester")
        let verifyReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.okfVerify,
            payload: try JSONEncoder().encode(DaemonPageOKFVerifyRequest(
                wikiID: fixture.id.rawValue,
                versionID: versionID,
                verifierJSON: try JSONEncoder().encode(verifier),
                verifiedAt: Date(),
                basisJSON: try JSONEncoder().encode(OKFVerificationBasis(
                    kind: .humanReview,
                    evidence: [.external(URL(string: "https://example.test/evidence")!)],
                    note: "socket test")),
                ttlSeconds: nil)))
        let verifyOutcome = try DaemonCommandOutcome.decode(verifyReply.payload)
        #expect(verifyOutcome.text?.hasPrefix("verification_id\t") == true)

        // The writes are visible through a second inspect.
        let reInspect = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.okfInspect,
            payload: try JSONEncoder().encode(DaemonPageOKFInspectRequest(
                wikiID: fixture.id.rawValue, versionID: versionID, json: false)))
        let reInspected = try DaemonCommandOutcome.decode(reInspect.payload)
        #expect(reInspected.text?.contains("status\tdraft") == true)
    }

    // MARK: - source family

    @Test func sourceListCatExportInfoRoundTripOverRealSocket() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let payload = Data("hello source bytes".utf8)
        try await seed(daemon, wikiID: fixture.id) { store in
            _ = try store.addSource(filename: "notes.md", data: payload)
        }

        let client = try makeSocketClient(container: container)
        let listReply = try await client.send(
            family: .source,
            operation: DaemonDomainOperation.Source.list,
            payload: try JSONEncoder().encode(DaemonSourceListRequest(
                wikiID: fixture.id.rawValue, json: false)))
        let listed = try DaemonCommandOutcome.decode(listReply.payload)
        #expect(listed.text?.contains("notes.md") == true)

        let sourceID = try await sourceIDFor(daemon: daemon, wikiID: fixture.id)

        // CAT — raw bytes round trip through the base64 channel.
        let catReply = try await client.send(
            family: .source,
            operation: DaemonDomainOperation.Source.cat,
            payload: try JSONEncoder().encode(DaemonSourceReadRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(id: sourceID.rawValue),
                markdown: false)))
        let cat = try DaemonCommandOutcome.decode(catReply.payload)
        let rawBase64 = try #require(cat.bytesBase64)
        guard let raw = Data(base64Encoded: rawBase64) else {
            Issue.record("cat reply carried an undecodable bytes payload")
            return
        }
        #expect(raw == payload)

        // EXPORT — the daemon writes the file into the CALLER-provided cwd.
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dcm-export-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let exportReply = try await client.send(
            family: .source,
            operation: DaemonDomainOperation.Source.export,
            payload: try JSONEncoder().encode(DaemonSourceExportRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(id: sourceID.rawValue),
                out: nil,
                markdown: false,
                cwd: exportDirectory.path)))
        let exported = try DaemonCommandOutcome.decode(exportReply.payload)
        let exportPath = try #require(exported.text)
        #expect(exportPath.hasPrefix(exportDirectory.path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: exportPath)) == payload)

        // INFO — identity lines.
        let infoReply = try await client.send(
            family: .source,
            operation: DaemonDomainOperation.Source.info,
            payload: try JSONEncoder().encode(DaemonSourceInfoRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(source: .name("notes.md")))))
        let info = try DaemonCommandOutcome.decode(infoReply.payload)
        #expect(info.text?.contains("filename\tnotes.md") == true)
    }

    // MARK: - chat family

    /// A fresh wiki has no chats: `chat list` round-trips EMPTY (byte-stable
    /// empty JSON-lines stream), and `chat get` on a missing title is the
    /// command's typed failure text. (Chat seeding needs the app's chat
    /// session machinery; the empty + failure shapes are the socket contract.)
    @Test func chatListEmptyAndGetMissingTitleOverRealSocket() async throws {
        let container = makeContainer()
        let (server, fixture, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let client = try makeSocketClient(container: container)
        let listReply = try await client.send(
            family: .chat,
            operation: DaemonDomainOperation.Chat.list,
            payload: try JSONEncoder().encode(DaemonChatListRequest(
                wikiID: fixture.id.rawValue, json: true)))
        let listed = try DaemonCommandOutcome.decode(listReply.payload)
        // The JSON-lines stream for zero chats is the empty string.
        #expect(listed.text?.isEmpty == true)

        do {
            _ = try await client.send(
                family: .chat,
                operation: DaemonDomainOperation.Chat.get,
                payload: try JSONEncoder().encode(DaemonChatGetRequest(
                    wikiID: fixture.id.rawValue,
                    selector: DaemonCommandSelector(title: "No Such Chat"))))
            Issue.record("expected a typed command failure")
        } catch let error as DaemonDomainError {
            #expect(error.code == .operationFailed)
            #expect(error.message.contains("no chat titled"))
        }
    }

    // MARK: - bookmark family

    @Test func bookmarkListRoundTripOverRealSocket() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        try await seed(daemon, wikiID: fixture.id) { store in
            _ = try store.createBookmarkNode(
                parentID: nil, position: 0, content: .folder(label: "Reading"))
        }

        let client = try makeSocketClient(container: container)
        let reply = try await client.send(
            family: .bookmark,
            operation: DaemonDomainOperation.Bookmark.list,
            payload: try JSONEncoder().encode(DaemonBookmarkListRequest(
                wikiID: fixture.id.rawValue, json: false)))
        let listed = try DaemonCommandOutcome.decode(reply.payload)
        #expect(listed.text?.contains("Reading") == true)
        #expect(listed.text?.contains("folder") == true)

        let jsonReply = try await client.send(
            family: .bookmark,
            operation: DaemonDomainOperation.Bookmark.list,
            payload: try JSONEncoder().encode(DaemonBookmarkListRequest(
                wikiID: fixture.id.rawValue, json: true)))
        let jsonListed = try DaemonCommandOutcome.decode(jsonReply.payload)
        #expect(jsonListed.text?.contains("\"kind\":\"folder\"") == true)
    }

    // MARK: - workspace family

    @Test func workspaceStatusAndConflictsRoundTripOverRealSocket() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let workspaceID: WorkspaceID = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.createWorkspace(name: "speculative", activityID: nil)
        }

        let client = try makeSocketClient(container: container)
        let statusReply = try await client.send(
            family: .workspace,
            operation: DaemonDomainOperation.Workspace.status,
            payload: try JSONEncoder().encode(DaemonWorkspaceRequest(
                wikiID: fixture.id.rawValue, id: workspaceID.rawValue)))
        let status = try DaemonCommandOutcome.decode(statusReply.payload)
        #expect(status.text?.contains("open") == true)
        #expect(status.text?.contains("(no pages)") == true)

        let conflictsReply = try await client.send(
            family: .workspace,
            operation: DaemonDomainOperation.Workspace.conflicts,
            payload: try JSONEncoder().encode(DaemonWorkspaceRequest(
                wikiID: fixture.id.rawValue, id: workspaceID.rawValue)))
        let conflicts = try DaemonCommandOutcome.decode(conflictsReply.payload)
        #expect(conflicts.text == "(no conflicts)")
    }

    // MARK: - job (queue family: queueWikiItems)

    @Test func jobListAndGetThroughRouterOverRealSocket() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let sourceID = SourceID(rawValue: "0200000000000000000000000A")

        // A durable extraction item for the fixture wiki, written the way the
        // engine writes it (the daemon owns queue.sqlite; the test writes one
        // row directly to have something to inspect).
        let queueStore = try QueueStore(databaseURL: container.appendingPathComponent("queue.sqlite"))
        _ = try queueStore.enqueue(QueueItemRequest(
            queue: .extraction,
            wikiID: fixture.id,
            payload: QueueItemPayload(sourceIDs: [sourceID])))
        queueStore.close()

        let router = DaemonCommandRouter()
        let listed = try await router.runJob(
            .list(json: false),
            selector: fixture.displayName,
            containerDirectory: container)
        #expect(listed.output.contains("id\tqueue\tstate\tsource_ids"))
        #expect(listed.output.contains(sourceID.rawValue))
        #expect(listed.emptyList == false)

        let items = try await daemon.queueWikiItems(wikiID: fixture.id, itemID: nil).items
        guard let first = items.first else {
            Issue.record("expected the seeded queue item")
            return
        }
        let got = try await router.runJob(
            .get(id: first.id, json: true),
            selector: fixture.id.rawValue,
            containerDirectory: container)
        #expect(got.output.contains("\"\(sourceID.rawValue)\""))

        // `job get` with an unknown id keeps the CLI's typed failure.
        do {
            _ = try await router.runJob(
                .get(id: QueueItemID(rawValue: "01AAAAAAAAAAAAAAAAAAAAAAAA"), json: false),
                selector: fixture.id.rawValue,
                containerDirectory: container)
            Issue.record("expected notFound")
        } catch let error as JobCommand.Failure {
            #expect(error.localizedDescription.contains("No job with ID"))
        }
    }

    // MARK: - search (server-side resolution)

    /// `page search` runs ENTIRELY on the daemon — BM25 leg via the daemon's
    /// own runtime, catalog mapping, fusion, rendering. The CLI does no
    /// catalog work; the assertion pins the byte-stable TSV and the
    /// zero-results stderr note.
    @Test func pageSearchRunsServerSideOverRealSocket() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        try await seed(daemon, wikiID: fixture.id) { store in
            _ = try store.createPage(title: "Ironworkers Hall", body: "union hall minutes", createdBy: nil, provenance: [])
        }

        let client = try makeSocketClient(container: container)
        let reply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.search,
            payload: try JSONEncoder().encode(DaemonSearchCommandRequest(
                wikiID: fixture.id.rawValue, query: "Ironworkers", limit: 10)))
        let outcome = try DaemonCommandOutcome.decode(reply.payload)
        #expect(outcome.text?.contains("Ironworkers Hall") == true)
        #expect(outcome.stderr == nil)

        // A query matching nothing: empty stdout (byte-stable) + the named
        // zero-results note on stderr.
        let emptyReply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.search,
            payload: try JSONEncoder().encode(DaemonSearchCommandRequest(
                wikiID: fixture.id.rawValue, query: "zzz-no-such-thing", limit: 10)))
        let empty = try DaemonCommandOutcome.decode(emptyReply.payload)
        #expect(empty.text == "")
        #expect(empty.stderr?.contains("zzz-no-such-thing") == true)
    }

    /// The routing seam covers the search commands too: `page search` goes
    /// over the socket and the in-process store executor is never reached.
    @Test func runnerRoutesSearchThroughDaemonWithoutOpeningStore() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        try await seed(daemon, wikiID: fixture.id) { store in
            _ = try store.createPage(title: "Ironworkers Hall", body: "union minutes", createdBy: nil, provenance: [])
        }

        let runner = WikiCtlRunner(
            resolveContainer: { WikiResolver(containerDirectory: container) },
            daemonCommandRouter: DaemonCommandRouter())
        let invocation = try ArgumentParser.parse(
            ["--wiki", fixture.displayName, "page", "search", "--query", "Ironworkers"],
            env: { _ in nil })
        let output = try await runner.runOrdinary(
            command: invocation.command,
            wikiSelector: invocation.wikiSelector,
            environment: [:])
        #expect(String(decoding: output.stdout, as: UTF8.self).contains("Ironworkers Hall"))
        #expect(output.changedWikiID == nil)
    }

    // MARK: - Typed failures

    @Test func unknownWikiIsTypedNotFoundWithByteStableText() async throws {
        let container = makeContainer()
        let (server, _, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let client = try makeSocketClient(container: container)
        let missing = "01AAAAAAAAAAAAAAAAAAAAAAAA"
        do {
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.list,
                payload: try JSONEncoder().encode(DaemonPageListRequest(wikiID: missing, json: false)))
            Issue.record("expected notFound")
        } catch let error as DaemonDomainError {
            #expect(error.code == .notFound)
            #expect(error.message == "no wiki matching \(missing)")
        }
    }

    @Test func unknownPageOperationIsTypedInvalidRequest() async throws {
        let container = makeContainer()
        let (server, _, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let client = try makeSocketClient(container: container)
        do {
            _ = try await client.send(family: .page, operation: "teleportPage")
            Issue.record("expected invalidRequest")
        } catch let error as DaemonDomainError {
            #expect(error.code == .invalidRequest)
            #expect(error.message.contains("teleportPage"))
        }
    }

    @Test func malformedPagePayloadIsTypedInvalidRequest() async throws {
        let container = makeContainer()
        let (server, _, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let client = try makeSocketClient(container: container)
        do {
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.list,
                payload: Data("not json".utf8))
            Issue.record("expected invalidRequest")
        } catch let error as DaemonDomainError {
            #expect(error.code == .invalidRequest)
        }
    }

    @Test func pageCommandFailureSurfacesOperationFailedWithCommandText() async throws {
        let container = makeContainer()
        let (server, fixture, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let client = try makeSocketClient(container: container)
        do {
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.get,
                payload: try JSONEncoder().encode(DaemonPageGetRequest(
                    wikiID: fixture.id.rawValue,
                    selector: DaemonCommandSelector(title: "Missing Page"),
                    json: false)))
            Issue.record("expected operationFailed")
        } catch let error as DaemonDomainError {
            #expect(error.code == .operationFailed)
            #expect(error.message == "no page titled \"Missing Page\"")
        }
    }

    // MARK: - Routing seam

    /// The WikiCtlRunner seam: a migrated read goes over the socket and the
    /// in-process store executor is NEVER reached — that is the store-freedom
    /// guarantee, pinned by recording an issue if it runs.
    @Test func runnerRoutesMigratedReadThroughDaemonWithoutOpeningStore() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        try await seed(daemon, wikiID: fixture.id) { store in
            _ = try store.createPage(title: "Routed Page", body: "socket body", createdBy: nil, provenance: [])
        }

        let runner = WikiCtlRunner(
            resolveContainer: { WikiResolver(containerDirectory: container) },
            daemonCommandRouter: DaemonCommandRouter())
        let invocation = try ArgumentParser.parse(
            ["--wiki", fixture.displayName, "page", "list"],
            env: { _ in nil })
        let output = try await runner.runOrdinary(
            command: invocation.command,
            wikiSelector: invocation.wikiSelector,
            environment: [:])
        #expect(String(decoding: output.stdout, as: UTF8.self).contains("Routed Page"))
        #expect(output.changedWikiID == nil)
    }

    /// A Phase 4 WRITE now routes over the daemon like every other command —
    /// the in-process store executor is never reached for a registry-selected
    /// write. The in-process path survives only for `--database-path` fixture
    /// runs (covered by the dedicated fixture suites, not here).
    @Test func runnerRoutesWritesThroughDaemonWithoutOpeningStore() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let runner = WikiCtlRunner(
            resolveContainer: { WikiResolver(containerDirectory: container) },
            daemonCommandRouter: DaemonCommandRouter())
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dcm-body-\(UUID().uuidString.prefix(8)).md")
        try Data("routed body".utf8).write(to: bodyFile)
        let invocation = try ArgumentParser.parse(
            ["--wiki", fixture.displayName, "page", "add",
             "--title", "Routed Write", "--body-file", bodyFile.path],
            env: { _ in nil })
        let output = try await runner.runOrdinary(
            command: invocation.command,
            wikiSelector: invocation.wikiSelector,
            environment: [:])
        #expect(output.changedWikiID == fixture.id)
        let titles = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.listPages(sortBy: .lastUpdated).map(\.title)
        }
        #expect(titles.contains("Routed Write"))
    }

    /// Phase 5: a command with NO daemon route FAILS the runner — there is no
    /// local fallback (the in-process store path lives only in the build-only
    /// `wikictl-fixture` binary). `.wikiList` never reaches `runOrdinary` in
    /// wikictl's `run()` (it dispatches before), so reaching it here is
    /// exactly the wiring bug the guard exists for.
    @Test func registrySelectionWithoutDaemonRouteFailsInsteadOfBootingStore() async throws {
        let container = makeContainer()
        let runner = WikiCtlRunner(
            resolveContainer: { WikiResolver(containerDirectory: container) },
            daemonCommandRouter: DaemonCommandRouter())
        do {
            _ = try await runner.runOrdinary(
                command: .wikiList,
                wikiSelector: "any-wiki",
                environment: [:])
            Issue.record("expected the no-route guard")
        } catch let error as PageCommand.Failure {
            #expect(error.description.contains("no daemon route") == true)
            #expect(error.description.contains("no local fallback") == true)
        }
    }

    // MARK: - Absent daemon

    @Test func absentDaemonSurfacesExplicitNotRunningError() async throws {
        let container = makeContainer()
        let router = DaemonCommandRouter()
        do {
            _ = try await router.runJob(
                .list(json: false),
                selector: "any-wiki",
                containerDirectory: container)
            Issue.record("expected daemonNotRunning")
        } catch let error as PageCommand.Failure {
            #expect(error.description == "the wikid daemon is not running — launch the app")
        }
    }
}
#endif
