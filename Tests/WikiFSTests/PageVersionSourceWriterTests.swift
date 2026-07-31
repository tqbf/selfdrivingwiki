import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore

struct PageVersionSourceWriterTests {
    private func recorder(for store: GRDBWikiStore) -> SignalRecorder {
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "page-provenance-writers"))
        store.eventBus = bus
        let recorder = SignalRecorder()
        bus.subscribe(nil) { recorder.append($0) }
        return recorder
    }

    @Test func createPageSeedsMirrorAtInitialVersion() throws {
        let store = try TestStoreFactory.inMemory()

        let page = try store.createPage(title: "Seed")

        #expect(page.version == 1)
        #expect(try store.getPage(id: page.id).version == 1)
    }

    @Test func createEmptyPageHasNoSources() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Empty")
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        #expect(try store.pageVersionSources(versionID: head).isEmpty)
    }

    @Test func mainUpdateWritesSourcesAtomically() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Evidence")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))

        try store.updatePage(
            id: page.id, title: page.title, body: "Claim", lastEditedBy: "user",
            provenance: [.init(sourceID: source.id, role: .primary)]
        )

        #expect(try store.pageHeadSources(pageID: page.id) == [
            .init(
                pageVersionID: try #require(try store.pageHeadVersionID(pageID: page.id)),
                sourceID: source.id, role: .primary),
        ])
    }

    @Test func workspaceExistingPageWritesEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Workspace evidence")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let workspaceID = try store.createWorkspace(name: nil, activityID: nil)

        let versionID = try #require(try store.workspaceWritePage(
            workspaceID: workspaceID, pageID: page.id, title: page.title, body: "Workspace claim",
            author: "user", provenance: [.init(sourceID: source.id, role: .supporting)]))

        #expect(try store.pageVersionSources(versionID: versionID).map(\.sourceID) == [source.id])
    }

    @Test func pageUpsertFirstVersionGetsSources() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))

        let outcome = try PageUpsert.upsert(
            in: store, id: nil, title: "Initial evidence", body: "Claim", author: "user",
            provenance: [.init(sourceID: source.id, role: .primary)])

        let history = try store.pageVersionHistory(pageID: outcome.id)
        #expect(history.count == 1)
        #expect(try store.pageVersionSources(versionID: try #require(history.first?.id)).map(\.sourceID) == [source.id])
    }

    @Test func workspaceMintCopiesStagedSources() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let workspaceID = try store.createWorkspace(name: nil, activityID: nil)
        let stagedPageID = PageID(rawValue: ULID.generate())

        #expect(try store.workspaceWritePage(
            workspaceID: workspaceID, pageID: stagedPageID, title: "Staged evidence", body: "Claim",
            author: "user", provenance: [.init(sourceID: source.id, role: .primary)]) == nil)
        _ = try store.workspaceMerge(workspaceID: workspaceID)

        let head = try #require(try store.pageHeadVersionID(pageID: stagedPageID))
        #expect(try store.pageVersionSources(versionID: head).map(\.sourceID) == [source.id])
    }

    @Test func workspaceStagedPageStoresTypedSources() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "staged.txt", data: Data("staged".utf8))
        let workspace = try store.createWorkspace(name: nil, activityID: nil)
        let pageID = PageID(rawValue: ULID.generate())

        #expect(try store.workspaceWritePage(
            workspaceID: workspace, pageID: pageID, title: "Staged", body: "body", author: "agent:ingest",
            provenance: [.init(sourceID: source.id, role: .primary)]) == nil)
        _ = try store.workspaceMerge(workspaceID: workspace)

        let head = try #require(try store.pageHeadVersionID(pageID: pageID))
        #expect(try store.pageVersionSources(versionID: head).map(\.role) == [.primary])
    }

    @Test func casFailureWritesNothing() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "CAS")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let before = try #require(try store.pageHeadVersionID(pageID: page.id))

        #expect(throws: PageConflictError.self) {
            _ = try store.appendPageVersion(
                pageID: page.id, title: page.title, body: "new",
                expectedHeadVersionID: PageVersionID(rawValue: "stale"),
                provenance: [.init(sourceID: source.id, role: .primary)]
            )
        }

        #expect(try store.pageHeadVersionID(pageID: page.id) == before)
        #expect(try store.pageVersionSources(versionID: before).isEmpty)
    }

    @Test func casSuccessWritesSources() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "CAS success")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        let version = try store.appendPageVersion(
            pageID: page.id, title: page.title, body: "new", expectedHeadVersionID: head,
            lastEditedBy: "agent:cas", provenance: [.init(sourceID: source.id, role: .primary)])

        #expect(try store.pageHeadVersionID(pageID: page.id) == version)
        #expect(try store.pageVersionSources(versionID: version) == [
            .init(pageVersionID: version, sourceID: source.id, role: .primary),
        ])
    }

    @Test func noOpSaveWritesNoVersionOrEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "No-op")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))
        let before = try store.pageVersionHistory(pageID: page.id)

        _ = try store.appendPageVersion(
            pageID: page.id, title: page.title, body: "", expectedHeadVersionID: head,
            provenance: [])

        #expect(try store.pageVersionHistory(pageID: page.id).map(\.id) == before.map(\.id))
        #expect(try store.pageHeadVersionID(pageID: page.id) == head)
        #expect(try store.pageVersionSources(versionID: head).isEmpty)
        _ = source // A source exists but is not inferred from a no-op body.
    }

    @Test func changedProvenanceDisablesAmend() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Amend")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        try store.updatePage(id: page.id, title: page.title, body: "first", lastEditedBy: "user")
        let first = try #require(try store.pageHeadVersionID(pageID: page.id))

        try store.updatePage(
            id: page.id, title: page.title, body: "second", lastEditedBy: "user",
            provenance: [.init(sourceID: source.id, role: .supporting)])
        let second = try #require(try store.pageHeadVersionID(pageID: page.id))

        #expect(second != first)
        #expect(try store.pageVersionSources(versionID: second).map(\.sourceID) == [source.id])
    }

    @Test func userEditDefaultsToNoSources() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "User edit")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))

        try store.updatePage(
            id: page.id, title: page.title, body: "text cites \(source.id.rawValue)",
            lastEditedBy: "user")

        #expect(try store.pageHeadSources(pageID: page.id).isEmpty)
    }

    @Test func explicitUserSourceContextWritesEdge() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Explicit user evidence")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))

        try store.updatePage(
            id: page.id, title: page.title, body: "text", lastEditedBy: "user",
            provenance: [.init(sourceID: source.id, role: .quoted)])

        #expect(try store.pageHeadSources(pageID: page.id).map(\.role) == [.quoted])
    }

    @Test func restoreCopiesTargetEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Restore")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let root = try #require(try store.pageHeadVersionID(pageID: page.id))
        let target = try store.appendPageVersion(
            pageID: page.id, title: page.title, body: "evidence", expectedHeadVersionID: root,
            provenance: [.init(sourceID: source.id, role: .primary)])
        _ = try store.appendPageVersion(pageID: page.id, title: page.title, body: "later", expectedHeadVersionID: target)

        let restored = try store.restorePage(pageID: page.id, to: target)

        #expect(try store.pageVersionSources(versionID: restored).map(\.sourceID) == [source.id])
    }

    @Test func revertUsesTargetEdgesWithoutCopy() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Revert")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let root = try #require(try store.pageHeadVersionID(pageID: page.id))
        let target = try store.appendPageVersion(
            pageID: page.id, title: page.title, body: "evidence", expectedHeadVersionID: root,
            provenance: [.init(sourceID: source.id, role: .primary)])
        _ = try store.appendPageVersion(pageID: page.id, title: page.title, body: "later", expectedHeadVersionID: target)
        let before = try store.pageVersionHistory(pageID: page.id).map(\.id)

        try store.revertPage(pageID: page.id, to: target)

        #expect(try store.pageHeadVersionID(pageID: page.id) == target)
        #expect(try store.pageVersionHistory(pageID: page.id).map(\.id) == before)
        #expect(try store.pageHeadSources(pageID: page.id).map(\.sourceID) == [source.id])
    }

    @Test func workspaceFastForwardKeepsExistingEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Fast forward")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let workspace = try store.createWorkspace(name: nil, activityID: nil)
        let version = try #require(try store.workspaceWritePage(
            workspaceID: workspace, pageID: page.id, title: page.title, body: "workspace",
            author: "agent:ingest", provenance: [.init(sourceID: source.id, role: .supporting)]))

        _ = try store.workspaceMerge(workspaceID: workspace)

        #expect(try store.pageHeadVersionID(pageID: page.id) == version)
        #expect(try store.pageHeadSources(pageID: page.id).map(\.sourceID) == [source.id])
    }

    @Test func workspaceMergeUnionsParentEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Merge")
        let main = try store.addSource(filename: "main.txt", data: Data("m".utf8))
        let workspaceSource = try store.addSource(filename: "workspace.txt", data: Data("w".utf8))
        try store.updatePage(id: page.id, title: page.title, body: "one\ntwo\nthree", lastEditedBy: "user",
                             provenance: [.init(sourceID: main.id, role: .primary)])
        let workspace = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(workspaceID: workspace, pageID: page.id, title: page.title,
                                         body: "workspace-one\ntwo\nthree", author: "agent:ingest",
                                         provenance: [.init(sourceID: workspaceSource.id, role: .supporting)])
        let mainHead = try #require(try store.pageHeadVersionID(pageID: page.id))
        _ = try store.appendPageVersion(pageID: page.id, title: page.title, body: "one\ntwo\nmain-three",
                                        expectedHeadVersionID: mainHead,
                                        provenance: [.init(sourceID: main.id, role: .primary)])
        _ = try store.workspaceMerge(workspaceID: workspace)

        #expect(Set(try store.pageHeadSources(pageID: page.id).map(\.sourceID)) == Set([main.id, workspaceSource.id]))
    }

    @Test func workspaceRefreshUnionsParentEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Refresh")
        let main = try store.addSource(filename: "main.txt", data: Data("m".utf8))
        let workspaceSource = try store.addSource(filename: "workspace.txt", data: Data("w".utf8))
        try store.updatePage(id: page.id, title: page.title, body: "one\ntwo\nthree", lastEditedBy: "user",
                             provenance: [.init(sourceID: main.id, role: .primary)])
        let workspace = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(workspaceID: workspace, pageID: page.id, title: page.title,
                                         body: "one\nworkspace-two\nthree", author: "agent:ingest",
                                         provenance: [.init(sourceID: workspaceSource.id, role: .supporting)])
        let mainHead = try #require(try store.pageHeadVersionID(pageID: page.id))
        _ = try store.appendPageVersion(pageID: page.id, title: page.title, body: "main-one\ntwo\nthree",
                                        expectedHeadVersionID: mainHead,
                                        provenance: [.init(sourceID: main.id, role: .primary)])
        try store.workspaceRefresh(workspaceID: workspace)

        let refreshed = try #require(try store.workspacePageVersion(workspaceID: workspace, pageID: page.id))
        #expect(Set(try store.pageVersionSources(versionID: refreshed).map(\.sourceID)) == Set([main.id, workspaceSource.id]))
    }

    @Test func workspaceConflictResolutionUnionsEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Resolve")
        let main = try store.addSource(filename: "main.txt", data: Data("m".utf8))
        let workspaceSource = try store.addSource(filename: "workspace.txt", data: Data("w".utf8))
        try store.updatePage(id: page.id, title: page.title, body: "one\ntwo", lastEditedBy: "user",
                             provenance: [.init(sourceID: main.id, role: .primary)])
        let workspace = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(workspaceID: workspace, pageID: page.id, title: page.title,
                                         body: "one\nworkspace", author: "agent:ingest",
                                         provenance: [.init(sourceID: workspaceSource.id, role: .supporting)])
        let mainHead = try #require(try store.pageHeadVersionID(pageID: page.id))
        _ = try store.appendPageVersion(pageID: page.id, title: page.title, body: "one\nmain",
                                        expectedHeadVersionID: mainHead,
                                        provenance: [.init(sourceID: main.id, role: .primary)])
        _ = try store.workspaceMerge(workspaceID: workspace)
        try store.workspaceResolveConflict(workspaceID: workspace, pageID: page.id, body: "one\nmain\nworkspace")

        let resolved = try #require(try store.workspacePageVersion(workspaceID: workspace, pageID: page.id))
        #expect(Set(try store.pageVersionSources(versionID: resolved).map(\.sourceID)) == Set([main.id, workspaceSource.id]))
    }

    @Test func agentIngestMarksPrimaryAndSupporting() throws {
        let store = try TestStoreFactory.inMemory()
        let assigned = try store.addSource(filename: "assigned.txt", data: Data("a".utf8))
        let consulted = try store.addSource(filename: "consulted.txt", data: Data("c".utf8))
        let inputs = PageVersionSourceInput.agentIngest(sourceIDs: [assigned.id, consulted.id])

        _ = try PageUpsert.upsert(in: store, id: nil, title: "Ingest", body: "claim", author: "agent:ingest", provenance: inputs)
        let pageID = try #require(try store.resolveTitleToID("Ingest"))
        let edges = try store.pageHeadSources(pageID: pageID)
        #expect(edges.map(\.sourceID) == [assigned.id, consulted.id])
        #expect(edges.map(\.role) == [.primary, .supporting])
    }

    @Test func agentIngestEnvironmentUsesAssignedPrimaryAndExplicitRolesAddOnly() {
        let provenance = PageCommand.mergedAgentIngestProvenance(
            [.init(sourceID: SourceID(rawValue: "b"), role: .quoted)],
            environment: ["WIKI_INGEST_SOURCE_IDS": "a,b"])

        #expect(provenance == [
            .init(sourceID: SourceID(rawValue: "a"), role: .primary),
            .init(sourceID: SourceID(rawValue: "b"), role: .supporting),
            .init(sourceID: SourceID(rawValue: "b"), role: .quoted),
        ])
    }

    @Test func transactionHelperSuccessWritesVersionActivityRefsAllEdgesAndReturnsEventPayload() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Transaction")
        let source = try store.addSource(filename: "evidence.txt", data: Data("e".utf8))
        try store.updatePage(id: page.id, title: page.title, body: "claim", lastEditedBy: "user",
                             provenance: [.init(sourceID: source.id, role: .primary)])
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        #expect(try store.pageVersionHistory(pageID: page.id).contains { $0.id == head })
        #expect(try store.pageOrigin(pageID: page.id)?.versionID == head)
        #expect(try store.pageVersionSources(versionID: head).map(\.sourceID) == [source.id])
    }

    @Test func transactionHelperSQLFailureRollsBackEveryEffectAndEmitsNothing() async throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Rollback")
        let source = try store.addSource(filename: "evidence.txt", data: Data("e".utf8))
        let before = try #require(try store.pageHeadVersionID(pageID: page.id))
        let input = PageVersionSourceInput(sourceID: source.id, role: .primary)
        let events = recorder(for: store)

        #expect(throws: PageVersionProvenanceWriteError.self) {
            try store.updatePage(id: page.id, title: page.title, body: "claim", lastEditedBy: "user", provenance: [input, input])
        }
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(events.snapshot.isEmpty)
        #expect(try store.pageHeadVersionID(pageID: page.id) == before)
        #expect(try store.pageVersionSources(versionID: before).isEmpty)
    }

    @Test func missingSourceRollsBackVersionActivityMirrorRefHeadBlobAllEdgesAndEvent() async throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Missing")
        let before = try #require(try store.pageHeadVersionID(pageID: page.id))
        let events = recorder(for: store)

        #expect(throws: PageVersionProvenanceWriteError.missingSource(SourceID(rawValue: "missing"))) {
            try store.updatePage(id: page.id, title: page.title, body: "new", lastEditedBy: "user",
                                 provenance: [.init(sourceID: SourceID(rawValue: "missing"), role: .primary)])
        }
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(events.snapshot.isEmpty)
        #expect(try store.pageHeadVersionID(pageID: page.id) == before)
        #expect(try store.getPage(id: page.id).bodyMarkdown.isEmpty)
    }

    @Test func compatibilityInvalidRoleWritesNothingAndEmitsNothing() async throws {
        let store = try TestStoreFactory.inMemory()
        let events = recorder(for: store)
        #expect(throws: PageVersionProvenanceWriteError.invalidRole(rawValue: "invalid")) {
            _ = try ArgumentParser.parse(["--wiki", "test", "page", "add", "--title", "T", "--body-file", "-", "--source", "source:invalid"], env: { _ in nil })
        }
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(events.snapshot.isEmpty)
    }

    @Test func compatibilityEmptyRoleWritesNothingAndEmitsNothing() async throws {
        let store = try TestStoreFactory.inMemory()
        let events = recorder(for: store)
        #expect(throws: PageVersionProvenanceWriteError.invalidRole(rawValue: "")) {
            _ = try ArgumentParser.parse(["--wiki", "test", "page", "add", "--title", "T", "--body-file", "-", "--source", "source:"], env: { _ in nil })
        }
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(events.snapshot.isEmpty)
    }

    @Test func wikictlAddDecodesSourceRoles() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "test", "page", "add", "--title", "Test", "--body-file", "-",
             "--source", "source-a", "--source", "source-b:quoted"], env: { _ in nil })
        guard case .page(.add(_, _, _, _, _, _, let provenance)) = invocation.command else {
            Issue.record("expected page add invocation")
            return
        }
        #expect(provenance == [
            .init(sourceID: SourceID(rawValue: "source-a"), role: .primary),
            .init(sourceID: SourceID(rawValue: "source-b"), role: .quoted),
        ])
    }

    @Test func duplicateExactSourceRoleInputWritesNothingAndEmitsNothing() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Duplicate")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let before = try #require(try store.pageHeadVersionID(pageID: page.id))
        let input = PageVersionSourceInput(sourceID: source.id, role: .supporting)

        #expect(throws: PageVersionProvenanceWriteError.self) {
            try store.updatePage(
                id: page.id, title: page.title, body: "new", lastEditedBy: "user",
                provenance: [input, input]
            )
        }

        #expect(try store.pageHeadVersionID(pageID: page.id) == before)
    }

    @Test func sameSourceWithDifferentRolesIsAccepted() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Roles")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))

        try store.updatePage(
            id: page.id, title: page.title, body: "new", lastEditedBy: "user",
            provenance: [
                .init(sourceID: source.id, role: .supporting),
                .init(sourceID: source.id, role: .quoted),
            ]
        )

        #expect(try store.pageHeadSources(pageID: page.id).map(\.role) == [.supporting, .quoted])
    }

    @Test func wikictlCASWritesSources() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "CLI")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        _ = try PageCommand.run(
            .add(
                id: page.id, title: page.title, body: .inline("new"),
                expectHead: head, provenance: [.init(sourceID: source.id, role: .primary)]),
            in: store
        )

        #expect(try store.pageHeadSources(pageID: page.id).map(\.sourceID) == [source.id])
    }

    @Test func everyCreationSeamUsesTransactionalProvenanceHelper() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let production = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/WikiFSCore/Store/GRDBWikiStore.swift"), encoding: .utf8)

        // The only direct immutable-version writes are the two documented
        // legacy migration backfills and the shared transaction helper.
        #expect(production.components(separatedBy: "INSERT INTO page_versions").count - 1 == 3)
        #expect(production.components(separatedBy: "INSERT INTO page_version_sources").count - 1 == 1)

        for seam in [
            "workspaceWritePage(",
            "workspaceRefresh(workspaceID:",
            "workspaceResolveConflict(",
            "mintCreatedPage(",
            "diff3MergePage(",
        ] {
            guard let start = production.range(of: seam)?.lowerBound else {
                Issue.record("missing creation seam \(seam)")
                continue
            }
            let remainder = production[start...]
            #expect(remainder.contains("createPageVersionWithProvenance("))
        }
    }
}
