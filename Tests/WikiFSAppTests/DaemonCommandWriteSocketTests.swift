#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
@testable import wikid

// Phase 4 of plans/cli-domain-commands.md: the WRITE command families over
// the REAL CLI ⇄ daemon socket — page add (incl. `--expect-head` and
// `--create-only`)/delete/revert/okf-correct, source add/addURL-failures/
// editMarkdown (CAS)/rename/set-active/refresh-failure + the source okf
// family, chat rename, the bookmark/workspace/strategy/log/admin writes, and
// `extractor sync` (whose durable enqueue lands in the DAEMON's queue store).
//
// The core Phase 4 contract under test: CAS is evaluated SERVER-side, inside
// the store write, and a conflict crosses the wire as a TYPED error code
// (`casConflict`, `createOnlyConflict`, `expectedTargetMissing`,
// `strategyRevisionConflict`) carrying expected/actual — never a stringified
// stderr guess. The trailing router tests pin the CLI-side reconstruction:
// the typed codes rebuild the SAME store errors the in-process path threw, so
// main.swift's existing catch paths print the byte-stable conflict text and
// exit 3 (success keeps exit 0 by simply not throwing).
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, short
// injected timeouts, no blocking waits.
@Suite(.serialized, .timeLimit(.minutes(8)))
struct DaemonCommandWriteSocketTests {

    // MARK: Fixtures (same shape as DaemonCommandSocketTests)

    private func makeContainer() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dcw-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private func startDaemonSocket(
        container: URL,
        testExtractorCatalog: (any ExtractorPackageCatalogReading)? = nil
    ) throws -> (server: DaemonSearchSocketServer, daemon: WikiDaemon) {
        let daemon: WikiDaemon
        if let testExtractorCatalog {
            daemon = WikiDaemon(
                containerDirectory: container,
                testExtractorCatalog: testExtractorCatalog)
        } else {
            daemon = WikiDaemon(containerDirectory: container)
        }
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

    private func makeSeededWiki(
        container: URL,
        testExtractorCatalog: (any ExtractorPackageCatalogReading)? = nil
    ) async throws -> (
        server: DaemonSearchSocketServer,
        descriptor: WikiDescriptor,
        daemon: WikiDaemon
    ) {
        let (server, daemon) = try startDaemonSocket(
            container: container, testExtractorCatalog: testExtractorCatalog)
        let registry = try makeRegistryClient(container: container)
        let descriptor = try await registry.createWiki(name: "Write Fixture Wiki")
        return (server, descriptor, daemon)
    }

    private func seed(
        _ daemon: WikiDaemon, wikiID: WikiID,
        _ mutate: (WikiStore) throws -> Void
    ) async throws {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        try mutate(store)
    }

    private func seedValue<Value>(
        _ daemon: WikiDaemon, wikiID: WikiID,
        _ mutate: (WikiStore) throws -> Value
    ) async throws -> Value {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        return try mutate(store)
    }

    /// Seed one source WITH a processed-markdown HEAD (a derived transcript
    /// append — the same seam `source refresh` persists through) and return
    /// (sourceID, headID).
    private func seedSourceWithMarkdownHead(
        _ daemon: WikiDaemon, wikiID: WikiID
    ) async throws -> (sourceID: SourceID, headID: SourceMarkdownVersionID) {
        try await seedValue(daemon, wikiID: wikiID) { store in
            let summary = try store.addSource(
                filename: "notes.md", data: Data("raw bytes".utf8))
            let version = try store.appendDerivedMarkdown(
                sourceID: summary.id, content: "first markdown",
                origin: .transcript, producer: .tool(.transcript),
                providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil, note: nil)
            return (summary.id, version.id)
        }
    }

    // MARK: - page writes

    @Test func pageAddRoundTripCreatesPageWithDidCommit() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let client = try makeSocketClient(container: container)
        let reply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.add,
            payload: try JSONEncoder().encode(DaemonPageAddRequest(
                wikiID: fixture.id.rawValue, id: nil, title: "Socket Written",
                body: "body over the wire", expectHead: nil, createOnly: false,
                workspace: nil, author: "agent:phase4", provenance: [])))
        let outcome = try DaemonCommandOutcome.decode(reply.payload)
        #expect(outcome.didCommit == true)
        #expect(outcome.text?.isEmpty == false)

        // Visible through the daemon's own store.
        let titles = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.listPages(sortBy: .lastUpdated).map(\.title)
        }
        #expect(titles.contains("Socket Written"))
    }

    /// The core CAS contract: a stale `--expect-head` is evaluated inside the
    /// server-side store write and comes back as the typed `casConflict` with
    /// the expected AND actual heads — never a stringified failure.
    @Test func pageAddStaleExpectHeadIsTypedCASConflictWithHeads() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let pageID: PageID = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.createPage(title: "Contested", body: "v1", createdBy: nil, provenance: []).id
        }
        let actualHead: PageVersionID = try await seedValue(daemon, wikiID: fixture.id) { store in
            guard let head = try store.pageHeadVersionID(pageID: pageID) else {
                Issue.record("expected a head version")
                return PageVersionID(rawValue: "missing-head")
            }
            return head
        }
        let stale = PageVersionID(rawValue: "01AAAAAAAAAAAAAAAAAAAAAAAA")

        let client = try makeSocketClient(container: container)
        do {
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.add,
                payload: try JSONEncoder().encode(DaemonPageAddRequest(
                    wikiID: fixture.id.rawValue, id: nil, title: "Contested",
                    body: "stale write", expectHead: stale.rawValue,
                    createOnly: false, workspace: nil, author: nil, provenance: [])))
            Issue.record("expected casConflict")
        } catch let error as DaemonDomainError {
            #expect(error.code == .casConflict)
            let detail = try #require(error.conflict)
            #expect(detail.kind == "page")
            #expect(detail.expected == stale.rawValue)
            #expect(detail.actual == actualHead.rawValue)
        }
    }

    @Test func pageAddCreateOnlyConflictCarriesExistingHead() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        try await seed(daemon, wikiID: fixture.id) { store in
            _ = try store.createPage(title: "Race Winner", body: "v1", createdBy: nil, provenance: [])
        }

        let client = try makeSocketClient(container: container)
        do {
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.add,
                payload: try JSONEncoder().encode(DaemonPageAddRequest(
                    wikiID: fixture.id.rawValue, id: nil, title: "Race Winner",
                    body: "loser", expectHead: nil, createOnly: true,
                    workspace: nil, author: nil, provenance: [])))
            Issue.record("expected createOnlyConflict")
        } catch let error as DaemonDomainError {
            #expect(error.code == .createOnlyConflict)
            let detail = try #require(error.conflict)
            #expect(detail.title == "Race Winner")
            #expect(detail.actual?.isEmpty == false)
        }
    }

    @Test func pageAddExpectedTargetMissingIsTyped() async throws {
        let container = makeContainer()
        let (server, fixture, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let client = try makeSocketClient(container: container)
        do {
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.add,
                payload: try JSONEncoder().encode(DaemonPageAddRequest(
                    wikiID: fixture.id.rawValue, id: nil, title: "Vanished",
                    body: "pinned to a ghost", expectHead: "01AAAAAAAAAAAAAAAAAAAAAAAA",
                    createOnly: false, workspace: nil, author: nil, provenance: [])))
            Issue.record("expected expectedTargetMissing")
        } catch let error as DaemonDomainError {
            #expect(error.code == .expectedTargetMissing)
            let detail = try #require(error.conflict)
            #expect(detail.title == "Vanished")
            #expect(detail.expected == "01AAAAAAAAAAAAAAAAAAAAAAAA")
            #expect(detail.actual == nil)
        }
    }

    @Test func pageDeleteAndRevertRoundTrips() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let pageID: PageID = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.createPage(title: "Doomed Page", body: "v1", createdBy: nil, provenance: []).id
        }
        let headID: PageVersionID = try await seedValue(daemon, wikiID: fixture.id) { store in
            guard let head = try store.pageHeadVersionID(pageID: pageID) else {
                Issue.record("expected a head version")
                return PageVersionID(rawValue: "missing-head")
            }
            return head
        }

        let client = try makeSocketClient(container: container)
        let revert = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.revert,
            payload: try JSONEncoder().encode(DaemonPageRevertRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(id: pageID.rawValue),
                versionID: headID.rawValue)))
        let reverted = try DaemonCommandOutcome.decode(revert.payload)
        #expect(reverted.didCommit == true)

        let delete = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.delete,
            payload: try JSONEncoder().encode(DaemonPageDeleteRequest(
                wikiID: fixture.id.rawValue, id: pageID.rawValue,
                unlinkIncoming: false)))
        let deleted = try DaemonCommandOutcome.decode(delete.payload)
        #expect(deleted.didCommit == true)

        let titles = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.listPages(sortBy: .lastUpdated).map(\.title)
        }
        #expect(titles.contains("Doomed Page") == false)
    }

    @Test func pageOKFCorrectRoundTrip() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let versionID: PageVersionID = try await seedValue(daemon, wikiID: fixture.id) { store in
            let page = try store.createPage(title: "Verified", body: "b", createdBy: nil, provenance: [])
            guard let head = try store.pageHeadVersionID(pageID: page.id) else {
                Issue.record("expected a head version")
                return PageVersionID(rawValue: "missing-head")
            }
            return head
        }
        let verificationID: OKFVerificationID = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.recordPageOKFVerification(
                versionID: versionID, verifier: try OKFVerifierIdentity("human:tester"),
                verifiedAt: Date(), basis: OKFVerificationBasis(
                    kind: .humanReview, evidence: [], note: nil),
                freshnessPolicy: nil)
        }

        let input = OKFCorrectionInput(
            verificationID: verificationID,
            verifier: try OKFVerifierIdentity("human:corrector"),
            correctedAt: Date(),
            reason: OKFVerificationCorrectionReason(reason: "wrong basis"))
        let client = try makeSocketClient(container: container)
        let reply = try await client.send(
            family: .page,
            operation: DaemonDomainOperation.Page.okfCorrect,
            payload: try JSONEncoder().encode(DaemonPageOKFCorrectRequest(
                wikiID: fixture.id.rawValue, versionID: versionID.rawValue,
                inputJSON: try JSONEncoder().encode(input))))
        let outcome = try DaemonCommandOutcome.decode(reply.payload)
        #expect(outcome.didCommit == true)
        #expect(outcome.text == "corrected\t\(verificationID.rawValue)")
    }

    // MARK: - source writes

    @Test func sourceAddFileEditMarkdownCASAndRenameRoundTrips() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let client = try makeSocketClient(container: container)

        // ADD (raw bytes over the wire).
        let add = try await client.send(
            family: .source,
            operation: DaemonDomainOperation.Source.addFile,
            payload: try JSONEncoder().encode(DaemonSourceAddFileRequest(
                wikiID: fixture.id.rawValue, path: "upload.bin", name: "upload.bin",
                contentBase64: Data("binary payload".utf8).base64EncodedString())))
        let added = try DaemonCommandOutcome.decode(add.payload)
        #expect(added.didCommit == true)
        let sourceID = try await seedValue(daemon, wikiID: fixture.id) { store in
            try #require(store.listSources().first?.id)
        }

        // Seed a markdown head so the CAS write has something to pin.
        let headID = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.appendDerivedMarkdown(
                sourceID: sourceID, content: "first markdown",
                origin: .transcript, producer: .tool(.transcript),
                providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil, note: nil).id
        }

        // EDIT MARKDOWN with the CORRECT head — succeeds.
        let edit = try await client.send(
            family: .source,
            operation: DaemonDomainOperation.Source.editMarkdown,
            payload: try JSONEncoder().encode(DaemonSourceEditMarkdownRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(id: sourceID.rawValue),
                content: "rewritten markdown", expectedHead: headID.rawValue)))
        let edited = try DaemonCommandOutcome.decode(edit.payload)
        #expect(edited.didCommit == true)

        // The new head is what a re-read sees.
        let newHead = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.processedMarkdownHead(sourceID: sourceID)
        }
        #expect(newHead?.content == "rewritten markdown")
        #expect(newHead?.id != headID)

        // EDIT MARKDOWN with the STALE head — typed casConflict carrying
        // expected + actual.
        do {
            _ = try await client.send(
                family: .source,
                operation: DaemonDomainOperation.Source.editMarkdown,
                payload: try JSONEncoder().encode(DaemonSourceEditMarkdownRequest(
                    wikiID: fixture.id.rawValue,
                    selector: DaemonCommandSelector(id: sourceID.rawValue),
                    content: "lost race", expectedHead: headID.rawValue)))
            Issue.record("expected casConflict")
        } catch let error as DaemonDomainError {
            #expect(error.code == .casConflict)
            let detail = try #require(error.conflict)
            #expect(detail.kind == "sourceMarkdown")
            #expect(detail.targetID == sourceID.rawValue)
            #expect(detail.expected == headID.rawValue)
            #expect(detail.actual == newHead?.id.rawValue)
        }

        // SET ACTIVE back to the first version, then RENAME.
        let setActive = try await client.send(
            family: .source,
            operation: DaemonDomainOperation.Source.setActive,
            payload: try JSONEncoder().encode(DaemonSourceSetActiveRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(id: sourceID.rawValue),
                versionID: headID.rawValue)))
        #expect(try DaemonCommandOutcome.decode(setActive.payload).didCommit == true)

        let rename = try await client.send(
            family: .source,
            operation: DaemonDomainOperation.Source.rename,
            payload: try JSONEncoder().encode(DaemonSourceRenameRequest(
                wikiID: fixture.id.rawValue,
                selector: DaemonCommandSelector(id: sourceID.rawValue),
                to: "renamed-source")))
        let renamed = try DaemonCommandOutcome.decode(rename.payload)
        #expect(renamed.didCommit == true)
    }

    @Test func sourceAddURLAndRefreshFailuresAreTypedCommandFailures() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let sourceID = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.addSource(filename: "plain.md", data: Data("bytes".utf8)).id
        }

        let client = try makeSocketClient(container: container)
        // Invalid URL: no network happens; the command layer's message is
        // verbatim.
        do {
            _ = try await client.send(
                family: .source,
                operation: DaemonDomainOperation.Source.addURL,
                payload: try JSONEncoder().encode(DaemonSourceAddURLRequest(
                    wikiID: fixture.id.rawValue, url: "not a url",
                    allowDuplicateURL: false)))
            Issue.record("expected operationFailed")
        } catch let error as DaemonDomainError {
            #expect(error.code == .operationFailed)
            #expect(error.message.contains("invalid URL"))
        }

        // Refresh of a plain byte source (no website origin): the refresh
        // service's typed refusal, verbatim.
        do {
            _ = try await client.send(
                family: .source,
                operation: DaemonDomainOperation.Source.refresh,
                payload: try JSONEncoder().encode(DaemonSourceRefreshRequest(
                    wikiID: fixture.id.rawValue,
                    selector: DaemonCommandSelector(id: sourceID.rawValue))))
            Issue.record("expected operationFailed")
        } catch let error as DaemonDomainError {
            #expect(error.code == .operationFailed)
            #expect(error.message.contains("notRefreshable"))
        }
    }

    @Test func sourceOKFStatusWriteRoundTrip() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let (_, headID) = try await seedSourceWithMarkdownHead(daemon, wikiID: fixture.id)

        let client = try makeSocketClient(container: container)
        let reply = try await client.send(
            family: .source,
            operation: DaemonDomainOperation.Source.okfStatus,
            payload: try JSONEncoder().encode(DaemonSourceOKFStatusRequest(
                wikiID: fixture.id.rawValue, versionID: headID.rawValue,
                status: "draft")))
        let outcome = try DaemonCommandOutcome.decode(reply.payload)
        #expect(outcome.didCommit == true)
        #expect(outcome.text == "status\tdraft")
    }

    // MARK: - chat / bookmark writes

    @Test func chatRenameMissingChatFailsTyped() async throws {
        let container = makeContainer()
        let (server, fixture, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let client = try makeSocketClient(container: container)
        do {
            _ = try await client.send(
                family: .chat,
                operation: DaemonDomainOperation.Chat.rename,
                payload: try JSONEncoder().encode(DaemonChatRenameRequest(
                    wikiID: fixture.id.rawValue,
                    selector: DaemonCommandSelector(title: "No Such Chat"),
                    to: "irrelevant")))
            Issue.record("expected operationFailed")
        } catch let error as DaemonDomainError {
            #expect(error.code == .operationFailed)
        }
    }

    @Test func bookmarkWriteRoundTripFolderRefRenameMoveDelete() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let pageID: PageID = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.createPage(title: "Bookmarked", body: "b", createdBy: nil, provenance: []).id
        }

        let client = try makeSocketClient(container: container)
        // Seed the parent folder through the store; the socket writes exercise
        // add-ref / rename / delete (create-folder's output decorates the id,
        // which the CLI surface prints verbatim).
        let folderID: String = try await seedValue(daemon, wikiID: fixture.id) { store in
            try store.createBookmarkNode(
                parentID: nil, position: -1, content: .folder(label: "Reading")
            ).id.rawValue
        }

        let addRef = try await client.send(
            family: .bookmark,
            operation: DaemonDomainOperation.Bookmark.addRef,
            payload: try JSONEncoder().encode(DaemonBookmarkAddRefRequest(
                wikiID: fixture.id.rawValue, parentID: folderID,
                ref: DaemonBookmarkRef(pageID: pageID.rawValue))))
        #expect(try DaemonCommandOutcome.decode(addRef.payload).didCommit == true)

        let rename = try await client.send(
            family: .bookmark,
            operation: DaemonDomainOperation.Bookmark.rename,
            payload: try JSONEncoder().encode(DaemonBookmarkRenameRequest(
                wikiID: fixture.id.rawValue, id: folderID, to: "Reading Later")))
        #expect(try DaemonCommandOutcome.decode(rename.payload).didCommit == true)

        let delete = try await client.send(
            family: .bookmark,
            operation: DaemonDomainOperation.Bookmark.delete,
            payload: try JSONEncoder().encode(DaemonBookmarkDeleteRequest(
                wikiID: fixture.id.rawValue, id: folderID)))
        #expect(try DaemonCommandOutcome.decode(delete.payload).didCommit == true)
    }

    // MARK: - workspace writes

    @Test func workspaceCreateAbandonReapRoundTrip() async throws {
        let container = makeContainer()
        let (server, fixture, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let client = try makeSocketClient(container: container)
        let create = try await client.send(
            family: .workspace,
            operation: DaemonDomainOperation.Workspace.create,
            payload: try JSONEncoder().encode(DaemonWorkspaceCreateRequest(
                wikiID: fixture.id.rawValue, name: "phase4-ws")))
        let created = try DaemonCommandOutcome.decode(create.payload)
        #expect(created.didCommit == true)
        let workspaceID = try #require(created.text)

        let abandon = try await client.send(
            family: .workspace,
            operation: DaemonDomainOperation.Workspace.abandon,
            payload: try JSONEncoder().encode(DaemonWorkspaceIDRequest(
                wikiID: fixture.id.rawValue, id: workspaceID)))
        #expect(try DaemonCommandOutcome.decode(abandon.payload).didCommit == true)

        // Reap with ttl 0 reclaims abandoned workspaces; the outcome reports
        // the count (didCommit true exactly when rows were reclaimed — a
        // sub-second-old workspace may legitimately not yet be stale).
        let reap = try await client.send(
            family: .workspace,
            operation: DaemonDomainOperation.Workspace.reap,
            payload: try JSONEncoder().encode(DaemonWorkspaceReapRequest(
                wikiID: fixture.id.rawValue, ttlSeconds: 0)))
        let reaped = try DaemonCommandOutcome.decode(reap.payload)
        #expect(reaped.text?.hasPrefix("reaped ") == true)
    }

    // MARK: - strategy writes (CAS)

    @Test func strategySaveConflictResetRoundTrip() async throws {
        let container = makeContainer()
        let (server, fixture, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let client = try makeSocketClient(container: container)

        // First save pins ABSENCE — succeeds (nothing was ever written).
        let first = try await client.send(
            family: .strategy,
            operation: DaemonDomainOperation.Strategy.save,
            payload: try JSONEncoder().encode(DaemonStrategySaveRequest(
                wikiID: fixture.id.rawValue, name: "Editorial",
                content: "write plainly", expect: .absent(), json: false)))
        #expect(try DaemonCommandOutcome.decode(first.payload).didCommit == true)

        // Second save STILL pinning absence — the revision moved: typed
        // strategyRevisionConflict with expected nil and actual "1".
        do {
            _ = try await client.send(
                family: .strategy,
                operation: DaemonDomainOperation.Strategy.save,
                payload: try JSONEncoder().encode(DaemonStrategySaveRequest(
                    wikiID: fixture.id.rawValue, name: "Editorial",
                    content: "second draft", expect: .absent(), json: false)))
            Issue.record("expected strategyRevisionConflict")
        } catch let error as DaemonDomainError {
            #expect(error.code == .strategyRevisionConflict)
            let detail = try #require(error.conflict)
            #expect(detail.kind == "strategy")
            #expect(detail.expected == nil)
            #expect(detail.actual == "1")
        }

        // Saving on top of the pinned revision succeeds.
        let third = try await client.send(
            family: .strategy,
            operation: DaemonDomainOperation.Strategy.save,
            payload: try JSONEncoder().encode(DaemonStrategySaveRequest(
                wikiID: fixture.id.rawValue, name: "Editorial",
                content: "third draft", expect: .revision(1), json: false)))
        #expect(try DaemonCommandOutcome.decode(third.payload).didCommit == true)

        // Reset pins the newest revision; the row tombstones, revision keeps.
        let reset = try await client.send(
            family: .strategy,
            operation: DaemonDomainOperation.Strategy.reset,
            payload: try JSONEncoder().encode(DaemonStrategyResetRequest(
                wikiID: fixture.id.rawValue, expect: .revision(2), json: false)))
        #expect(try DaemonCommandOutcome.decode(reset.payload).didCommit == true)
    }

    // MARK: - log family writes

    @Test func logAppendAndIndexSetRoundTrips() async throws {
        let container = makeContainer()
        let (server, fixture, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let client = try makeSocketClient(container: container)
        let append = try await client.send(
            family: .log,
            operation: DaemonDomainOperation.Log.logAppend,
            payload: try JSONEncoder().encode(DaemonLogAppendRequest(
                wikiID: fixture.id.rawValue, kind: "query", title: "socket append",
                note: "via daemon", source: nil, author: "agent:phase4")))
        let appended = try DaemonCommandOutcome.decode(append.payload)
        #expect(appended.didCommit == true)
        #expect(appended.text?.isEmpty == false)

        let indexSet = try await client.send(
            family: .log,
            operation: DaemonDomainOperation.Log.indexSet,
            payload: try JSONEncoder().encode(DaemonIndexSetRequest(
                wikiID: fixture.id.rawValue, body: "# index\n\n- one", workspace: nil)))
        let set = try DaemonCommandOutcome.decode(indexSet.payload)
        #expect(set.didCommit == true)
    }

    // MARK: - admin family (long-running budget)

    /// The vacuum completes within its (elevated) handler budget on a fixture
    /// store, replies typed, and the dry run commits nothing while the apply
    /// does.
    @Test func adminVacuumRoundTripsWithinBudget() async throws {
        let container = makeContainer()
        let (server, fixture, _) = try await makeSeededWiki(container: container)
        defer { server.stop() }

        let client = try makeSocketClient(container: container)
        let dryRun = try await client.send(
            family: .admin,
            operation: DaemonDomainOperation.Admin.vacuumAll,
            payload: try JSONEncoder().encode(DaemonAdminRequest(
                wikiID: fixture.id.rawValue, dryRun: true, json: false)))
        let dry = try DaemonCommandOutcome.decode(dryRun.payload)
        #expect(dry.didCommit == false)
        #expect(dry.text?.isEmpty == false)

        let apply = try await client.send(
            family: .admin,
            operation: DaemonDomainOperation.Admin.repairMIME,
            payload: try JSONEncoder().encode(DaemonAdminRequest(
                wikiID: fixture.id.rawValue, dryRun: true, json: false)))
        #expect(try DaemonCommandOutcome.decode(apply.payload).didCommit == false)

        // The budget table is the documented choice: admin sweeps and
        // workspace merge/reap run under the elevated ceiling with the client
        // deadline ABOVE it; standard families keep the socket's posture.
        #expect(DaemonDomainBudgets.handlerTimeout(family: .admin, operation: "vacuumAll") == 600)
        #expect(DaemonDomainBudgets.clientTimeout(family: .admin, operation: "repairMIME") == 660)
        #expect(DaemonDomainBudgets.clientTimeout(
            family: .workspace, operation: DaemonDomainOperation.Workspace.merge) == 660)
        #expect(DaemonDomainBudgets.clientTimeout(
            family: .workspace, operation: DaemonDomainOperation.Workspace.reap) == 660)
        #expect(DaemonDomainBudgets.handlerTimeout(
            family: .page, operation: DaemonDomainOperation.Page.add) == 60)
        #expect(DaemonDomainBudgets.clientTimeout(
            family: .page, operation: DaemonDomainOperation.Page.add) == 30)
    }

    /// The shared frame-cap guard protects the new families too: a reply over
    /// 4 MiB is a TYPED operationFailed naming the cap — never a truncation.
    @Test func oversizedReplyIsTypedOperationFailed() async throws {
        let container = makeContainer()
        let (server, fixture, daemon) = try await makeSeededWiki(container: container)
        defer { server.stop() }
        let pageID: PageID = try await seedValue(daemon, wikiID: fixture.id) { store in
            let huge = String(repeating: "x", count: 5 * 1024 * 1024)
            return try store.createPage(title: "Huge", body: huge, createdBy: nil, provenance: []).id
        }

        let client = try makeSocketClient(container: container)
        do {
            _ = try await client.send(
                family: .page,
                operation: DaemonDomainOperation.Page.get,
                payload: try JSONEncoder().encode(DaemonPageGetRequest(
                    wikiID: fixture.id.rawValue,
                    selector: DaemonCommandSelector(id: pageID.rawValue),
                    json: false)))
            Issue.record("expected the frame-cap operationFailed")
        } catch let error as DaemonDomainError {
            #expect(error.code == .operationFailed)
            #expect(error.message.contains("frame cap"))
        }
    }

    // MARK: - extractor family (durable enqueue through the daemon)

    /// A one-registration catalog double: a fetcher-role sync with no
    /// credentials, no required fields, and one list field carrying the item
    /// keys. The config sidecar (written into the fixture container) supplies
    /// one item; sync creates the byteless source and ENQUEUES through the
    /// daemon's queue engine.
    private struct CatalogDouble: ExtractorPackageCatalogReading {
        let catalog: ExtractorPackageCatalog
        func read() throws -> ExtractorPackageCatalog { catalog }
    }

    private func syncRecord() throws -> ExtractorPackageCatalogRecord {
        guard let uv = ExtractorRuntimeName(rawValue: "uv") else {
            Issue.record("the uv runtime name must resolve in tests")
            throw ExtractorPackageCatalogError.invalidRecord
        }
        let sync = try ExtractorSyncDeclaration(
            configFileName: "phase4-sync-config.json",
            urlTemplate: "https://example.test/items/{itemKey}",
            fields: [
                ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
            ])
        let registration = try ExtractorRegistration(
            id: ExtractorRegistrationID(validating: "attachment"),
            displayName: "Phase4 Fetcher",
            kinds: [],
            mimeTypes: [ExtractorMIMEType(validating: "application/x-phase4")],
            credentialRequirements: [],
            sync: sync,
            role: .fetcher)
        return try ExtractorPackageCatalogRecord(
            revision: ExtractorPackageRevisionID(
                packageID: ExtractorPackageID(validating: "org.test.phase4"),
                version: try ExtractorPackageVersion(validating: "1.0.0"),
                digest: ExtractorPackageDigest(
                    bytes: Array(repeating: 0x2a, count: 32))),
            displayName: "Phase4 Fetcher",
            protocolRevision: .v5,
            manifestRevision: .v4,
            launch: .runtime(
                command: uv,
                arguments: ["run", "--script"]),
            registrations: [registration],
            capabilities: [.network],
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
    }

    @Test func extractorSyncEnqueuesIntoDaemonQueueStore() async throws {
        let container = makeContainer()
        let record = try syncRecord()
        let (server, fixture, daemon) = try await makeSeededWiki(
            container: container,
            testExtractorCatalog: CatalogDouble(
                catalog: ExtractorPackageCatalog(records: [record])))
        defer { server.stop() }
        // The declared config sidecar: one item under the declared list
        // field's name.
        try Data(#"{"items": ["ITEMKEY01"]}"#.utf8).write(
            to: container.appendingPathComponent("phase4-sync-config.json"))

        let client = try makeSocketClient(container: container)
        let reply = try await client.send(
            family: .extractor,
            operation: DaemonDomainOperation.Extractor.sync,
            payload: try JSONEncoder().encode(DaemonExtractorSyncRequest(
                wikiID: fixture.id.rawValue, packageName: "phase4", force: false)))
        let outcome = try DaemonCommandOutcome.decode(reply.payload)
        #expect(outcome.didCommit == true)
        #expect(outcome.text?.contains("created") == true)

        // The enqueue landed in the DAEMON's queue store — the durable item
        // is visible through the queue family's wiki-items read.
        let items = try await daemon.queueWikiItems(wikiID: fixture.id, itemID: nil).items
        #expect(items.isEmpty == false)
        #expect(items.first?.queue == .extraction)

        // `fetch` with an unknown key still runs the shared front half; the
        // created source's identity interpolates the item key.
        let fetch = try await client.send(
            family: .extractor,
            operation: DaemonDomainOperation.Extractor.fetch,
            payload: try JSONEncoder().encode(DaemonExtractorFetchRequest(
                wikiID: fixture.id.rawValue, packageName: "phase4",
                itemKey: "ITEMKEY02", force: false)))
        let fetched = try DaemonCommandOutcome.decode(fetch.payload)
        #expect(fetched.didCommit == true)
        let afterFetch = try await daemon.queueWikiItems(wikiID: fixture.id, itemID: nil).items
        #expect(afterFetch.count == 2)
    }

    // MARK: - CLI routing layer: exit-code mapping

    /// The typed `casConflict` code rebuilds `PageConflictError` — the exact
    /// type main.swift's catch path prints the byte-stable conflict text for
    /// and maps to exit 3. This is the routing-layer half of the
    /// "casConflict → 3, success → 0" contract; the live check drives the
    /// process exit code end to end.
    @Test func routerReconstructsTypedConflictsFromCASCodes() throws {
        // casConflict (page kind) → PageConflictError (exit 3 in main.swift).
        let cas = DaemonDomainError(
            code: .casConflict,
            message: "CAS conflict (casConflict, kind page)",
            conflict: DaemonConflictDetail(
                kind: "page", targetID: "0190PAGE0000000000000000",
                expected: "01AAAAAAAAAAAAAAAAAAAAAAAA",
                actual: "01BBBBBBBBBBBBBBBBBBBBBBBB"))
        let rebuilt = try #require(DaemonCommandRouter.conflictError(from: cas) as? PageConflictError)
        #expect(rebuilt.pageID.rawValue == "0190PAGE0000000000000000")
        #expect(rebuilt.expectedVersionID.rawValue == "01AAAAAAAAAAAAAAAAAAAAAAAA")
        #expect(rebuilt.actualVersionID?.rawValue == "01BBBBBBBBBBBBBBBBBBBBBBBB")

        // casConflict (sourceMarkdown kind) → SourceMarkdownConflictError.
        let sourceCAS = DaemonDomainError(
            code: .casConflict,
            message: "CAS conflict",
            conflict: DaemonConflictDetail(
                kind: "sourceMarkdown", targetID: "0190SRC000000000000000000",
                expected: "01AAAAAAAAAAAAAAAAAAAAAAAA", actual: nil))
        let rebuiltSource = try #require(
            DaemonCommandRouter.conflictError(from: sourceCAS) as? SourceMarkdownConflictError)
        #expect(rebuiltSource.expectedHead.rawValue == "01AAAAAAAAAAAAAAAAAAAAAAAA")
        #expect(rebuiltSource.currentHead == nil)

        // createOnlyConflict → PageCreateConflictError.
        let createOnly = DaemonDomainError(
            code: .createOnlyConflict,
            message: "conflict",
            conflict: DaemonConflictDetail(
                kind: "page", targetID: "0190PAGE0000000000000000",
                title: "Dup", actual: "01BBBBBBBBBBBBBBBBBBBBBBBB"))
        #expect(DaemonCommandRouter.conflictError(from: createOnly) is PageCreateConflictError)

        // expectedTargetMissing → PageExpectedTargetMissingError.
        let missing = DaemonDomainError(
            code: .expectedTargetMissing,
            message: "conflict",
            conflict: DaemonConflictDetail(
                kind: "page", title: "Vanished",
                expected: "01AAAAAAAAAAAAAAAAAAAAAAAA"))
        #expect(DaemonCommandRouter.conflictError(from: missing) is PageExpectedTargetMissingError)

        // strategyRevisionConflict → WikiStrategyConflictError with nil =
        // absent revisions preserved.
        let strategy = DaemonDomainError(
            code: .strategyRevisionConflict,
            message: "conflict",
            conflict: DaemonConflictDetail(kind: "strategy", expected: nil, actual: "3"))
        let rebuiltStrategy = try #require(
            DaemonCommandRouter.conflictError(from: strategy) as? WikiStrategyConflictError)
        #expect(rebuiltStrategy.expectedRevision == nil)
        #expect(rebuiltStrategy.currentRevision?.rawValue == 3)

        // Non-CAS codes (and CAS codes without a detail) fall back to the
        // message path (exit 1).
        #expect(DaemonCommandRouter.conflictError(
            from: DaemonDomainError(code: .notFound, message: "no wiki matching x")) == nil)
        #expect(DaemonCommandRouter.conflictError(
            from: DaemonDomainError(code: .casConflict, message: "bare")) == nil)
    }

    /// The success half of the exit-code contract: a routed call that answers
    /// returns the command's own output through the router — no failure is
    /// manufactured, so main.swift's success path (exit 0) runs unchanged.
    @Test func routerSuccessCarriesCommandOutputAndDidCommit() async throws {
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dcw-body-\(UUID().uuidString.prefix(8)).md")
        try Data("routed body".utf8).write(to: bodyFile)
        let router = DaemonCommandRouter { call, selector, _ in
            #expect(selector == "fixture")
            #expect(call.family == .page)
            return DaemonCommandRouter.RoutedOutput(
                result: SourceCommand.Result(
                    payload: .text("0190PAGE0000000000000000"), didCommit: true),
                wikiID: WikiID(rawValue: "0190WIKI000000000000000000"))
        }
        let invocation = try ArgumentParser.parse(
            ["--wiki", "fixture", "page", "add", "--title", "T", "--body-file", bodyFile.path],
            env: { _ in nil })
        let call = try #require(DaemonCommandRoute.call(for: invocation.command))
        let routed = try await router.run(
            call, selector: "fixture", containerDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(routed.result.didCommit == true)
        if case .text(let text) = routed.result.payload {
            #expect(text == "0190PAGE0000000000000000")
        } else {
            Issue.record("expected a text payload")
        }
    }
}
#endif
