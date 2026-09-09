#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

/// Closed-wiki name resolution (value level).
///
/// A queue job whose wiki window is closed used to lose its target names:
/// rows resolved only through the live session index, so lint inputs
/// rendered "Deleted page" and offered no navigation even though the pages
/// exist. The fix has three layers, and this suite pins each one's
/// value-level contract:
///
/// 1. **Enqueue-time capture** — `QueueItemPayload.recordedNames` (additive,
///    optional, back-compat) captured at the lint/ingestion enqueue sites;
///    the ingestion chokepoint test drives `enqueueIngestion` end-to-end
///    (the IngestGateTests pattern).
/// 2. **Precedence** — `QueueTargetNameIndex.effective` layers live →
///    recorded → read-only; first-match recording makes the layering the
///    precedence.
/// 3. **Read-only fallback** — a closed wiki's names resolve through
///    `WikiReadService` against the real database, bounded to the payload's
///    IDs, cached per wiki in `QueueActivityTracker`.
/// 4. **Click-through** — `QueueTargetRouter` routes a known target into an
///    open session (navigate, then focus) or a closed one (stash the
///    `wiki://` deep link, then open) using existing seams only.
@MainActor
@Suite
struct QueueClosedWikiNameResolutionTests {

    // MARK: - Payload: additive + back-compat

    /// A payload persisted before `recordedNames` existed — the field is
    /// absent from the stored JSON — must decode unchanged with `nil`.
    @Test func legacyPayloadWithoutRecordedNamesDecodesNil() throws {
        let json = #"{"sourceIDs":["rs1"]}"#
        let payload = try JSONDecoder().decode(QueueItemPayload.self, from: Data(json.utf8))
        #expect(payload.sourceIDs == [SourceID(rawValue: "rs1")])
        #expect(payload.recordedNames == nil)
        #expect(payload.recordedPageTitle(for: PageID(rawValue: "rs1")) == nil)
    }

    /// The field round-trips through the storage encoding, and the typed
    /// accessors restore the namespace. An empty recorded string counts as
    /// unrecorded — it can never resolve to a display name.
    @Test func recordedNamesRoundTripThroughStorageEncoding() throws {
        let payload = QueueItemPayload(
            sourceIDs: [],
            lintPageIDs: [PageID(rawValue: "pg1")],
            recordedNames: ["pg1": "Design Notes", "pg2": ""])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(QueueItemPayload.self, from: data)
        #expect(decoded.recordedPageTitle(for: PageID(rawValue: "pg1")) == "Design Notes")
        #expect(decoded.recordedPageTitle(for: PageID(rawValue: "pg2")) == nil,
                "an empty recorded string is unrecorded")
        #expect(decoded.recordedPageTitle(for: PageID(rawValue: "missing")) == nil)
        #expect(decoded.recordedSourceName(for: SourceID(rawValue: "pg1")) == "Design Notes")
    }

    // MARK: - Precedence: live → recorded → read-only

    private func effectiveIndex(
        liveTitles: [PageID: String] = [:],
        cacheTitles: [PageID: String] = [:],
        recorded: [String: String]? = nil
    ) -> QueueTargetNameIndex {
        var live = QueueTargetNameIndex()
        for (id, title) in liveTitles { live.recordPage(id, title: title) }
        var cache = QueueTargetNameIndex()
        for (id, title) in cacheTitles { cache.recordPage(id, title: title) }
        return QueueTargetNameIndex.effective(
            live: live,
            readOnlyCache: cache,
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: [], recordedNames: recorded))
    }

    @Test func effectiveIndexLiveBeatsRecordedBeatsReadOnly() {
        let pageID = PageID(rawValue: "pg1")
        let recorded = [pageID.rawValue: "Recorded Title"]
        // Live wins over recorded:
        #expect(effectiveIndex(
            liveTitles: [pageID: "Live Title"],
            cacheTitles: [pageID: "ReadOnly Title"],
            recorded: recorded).pageTitle(pageID) == "Live Title")
        // Recorded wins over the read-only cache when live misses:
        #expect(effectiveIndex(
            cacheTitles: [pageID: "ReadOnly Title"],
            recorded: recorded).pageTitle(pageID) == "Recorded Title")
        // The read-only cache fills when neither live nor recorded has it:
        #expect(effectiveIndex(
            cacheTitles: [pageID: "ReadOnly Title"]).pageTitle(pageID) == "ReadOnly Title")
    }

    /// An empty recorded string is unrecorded: it must not shadow a
    /// read-only-resolved name with nothing.
    @Test func effectiveIndexEmptyRecordedNameSkipsToCache() {
        let pageID = PageID(rawValue: "pg1")
        #expect(effectiveIndex(
            cacheTitles: [pageID: "ReadOnly Title"],
            recorded: [pageID.rawValue: ""]).pageTitle(pageID) == "ReadOnly Title")
    }

    /// The recorded map records into both typed maps (lint payloads → page
    /// lookups, ingestion payloads → source lookups) without cross-
    /// contamination: the dictionaries are keyed by typed IDs, so an
    /// identical raw string under PageID and SourceID stays two independent
    /// entries — the page lookup keeps live's answer while the source
    /// namespace carries the recorded name.
    @Test func effectiveIndexRecordedNamesAreNamespacedByTypedID() {
        let effective = effectiveIndex(
            liveTitles: [PageID(rawValue: "dup"): "A Page"],
            recorded: ["dup": "Recorded Name"])
        #expect(effective.pageTitle(PageID(rawValue: "dup")) == "A Page")
        #expect(effective.sourceName(SourceID(rawValue: "dup")) == "Recorded Name")
    }

    // MARK: - Action gate: live-store membership on open wikis (review F1)

    /// OPEN wiki + recorded name + live-store miss → NO action. The
    /// effective index still carries the enqueue-time title (titles come
    /// from the effective index in all cases), but the page was deleted
    /// from the store after enqueue, so clicking would navigate a live
    /// store that cannot answer — the dead-end action is suppressed.
    @Test func openWikiLiveMissSuppressesActionButKeepsRecordedTitle() {
        let pageID = PageID(rawValue: "pg1")
        let payload = QueueItemPayload(
            sourceIDs: [],
            lintPageIDs: [pageID],
            recordedNames: [pageID.rawValue: "Recorded Title"])
        // The effective index resolves through the recorded layer…
        let effective = QueueTargetNameIndex.effective(
            live: QueueTargetNameIndex(), readOnlyCache: nil, payload: payload)
        // …but the live store no longer lists the page.
        let live = QueueTargetNameIndex()

        var routed: [QueueWorkspaceTargetIdentity] = []
        let actions = ActivityWindowView.targetRowActions(
            for: .page(pageID),
            wikiID: WikiID(rawValue: "wiki"),
            nameIndex: effective,
            liveIndex: live,
            isSessionOpen: true) { target, _ in routed.append(target) }

        #expect(actions.isEmpty,
                "an open wiki with a live miss must not offer dead-end navigation")
        #expect(routed.isEmpty)
        // The title still comes from the effective index in all cases.
        #expect(effective.pageTitle(pageID) == "Recorded Title")
    }

    /// CLOSED wiki with the same recorded name → the click-through action
    /// stays: the stash+open route resolves at click time, when the deep
    /// link navigates the freshly opened session. The route receives the
    /// effective index's title.
    @Test func closedWikiRecordedNameKeepsClickThrough() {
        let pageID = PageID(rawValue: "pg1")
        let payload = QueueItemPayload(
            sourceIDs: [],
            lintPageIDs: [pageID],
            recordedNames: [pageID.rawValue: "Recorded Title"])
        let effective = QueueTargetNameIndex.effective(
            live: QueueTargetNameIndex(), readOnlyCache: nil, payload: payload)

        var routedTitles: [String] = []
        let actions = ActivityWindowView.targetRowActions(
            for: .page(pageID),
            wikiID: WikiID(rawValue: "wiki"),
            nameIndex: effective,
            liveIndex: QueueTargetNameIndex(),
            isSessionOpen: false) { _, title in routedTitles.append(title) }

        #expect(actions.map(\.label) == ["Open Page"])
        // Fire the action: the route hands over the effective index's title.
        actions.first?.perform()
        #expect(routedTitles == ["Recorded Title"])
    }

    /// OPEN wiki where the live store still has the target → the action
    /// remains: the gate only suppresses live misses.
    @Test func openWikiLiveHitKeepsAction() {
        let pageID = PageID(rawValue: "pg1")
        var live = QueueTargetNameIndex()
        live.recordPage(pageID, title: "Live Title")
        let effective = QueueTargetNameIndex.effective(
            live: live, readOnlyCache: nil,
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: [pageID]))
        let actions = ActivityWindowView.targetRowActions(
            for: .page(pageID),
            wikiID: WikiID(rawValue: "wiki"),
            nameIndex: effective,
            liveIndex: live,
            isSessionOpen: true) { _, _ in }
        #expect(actions.map(\.label) == ["Open Page"])
    }

    // MARK: - Closed-wiki task identity (review F2)

    /// The `.task(id:)` identity for the closed-wiki name loads changes
    /// when a wiki window CLOSES (or opens), even with an unchanged
    /// displayed set — the session set is part of the key. Without it,
    /// closing a window never re-ran the load and its rows stayed
    /// "Resolving…" forever.
    @Test func closedWikiNamesKeyChangesWhenTheSessionSetChanges() {
        let item = QueueItem(
            id: QueueItemID(rawValue: "lint-job"),
            queue: .ingestion,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(
                sourceIDs: [],
                lintPageIDs: [PageID(rawValue: "lp1")],
                recordedNames: ["lp1": "Design Notes"]),
            state: .completed,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        let keyWhenOpen = ActivityWindowView.closedWikiNamesKey(
            for: [item], openWikiIDs: [WikiID(rawValue: "wiki")])
        let keyWhenClosed = ActivityWindowView.closedWikiNamesKey(
            for: [item], openWikiIDs: [])
        #expect(keyWhenOpen != keyWhenClosed,
                "closing the wiki's window must change the task identity")
        // Unrelated key churn stays stable for the same inputs.
        #expect(keyWhenClosed == ActivityWindowView.closedWikiNamesKey(
            for: [item], openWikiIDs: []))
    }

    // MARK: - Navigator titles (displayNames + computeRowTitle)

    /// A closed-wiki lint job with recorded names keeps readable input rows:
    /// the recorded titles flow through `displayNames` into the row title,
    /// instead of collapsing to "Lint N pages".
    @Test func closedWikiLintRowTitleUsesRecordedNames() {
        let ids = [PageID(rawValue: "lp1"), PageID(rawValue: "lp2")]
        let item = QueueItem(
            id: QueueItemID(rawValue: "lint-job"),
            queue: .ingestion,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(
                sourceIDs: [],
                lintPageIDs: ids,
                recordedNames: ["lp1": "Design Notes", "lp2": "Meeting Minutes"]),
            state: .completed,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        // No live session: the live index is empty; recorded names resolve.
        let effective = QueueTargetNameIndex.effective(
            live: QueueTargetNameIndex(),
            readOnlyCache: nil,
            payload: item.payload)
        let names = effective.displayNames(for: item)
        #expect(names.names == ["Design Notes", "Meeting Minutes"])
        #expect(names.targets == ["Design Notes", "Meeting Minutes"])
        #expect(
            ActivityWindowView.computeRowTitle(
                for: item, wikiName: "Wiki", names: names.names)
            == "Lint: Design Notes +1")
    }

    /// The legacy no-recorded-names path still collapses (titles absent →
    /// count fallback) — that is what the read-only fallback layer fills in.
    @Test func legacyClosedWikiLintRowTitleFallsBackToCount() {
        let item = QueueItem(
            id: QueueItemID(rawValue: "legacy-lint"),
            queue: .ingestion,
            wikiID: WikiID(rawValue: "wiki"),
            payload: QueueItemPayload(
                sourceIDs: [],
                lintPageIDs: [PageID(rawValue: "lp1"), PageID(rawValue: "lp2")]),
            state: .completed,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        let effective = QueueTargetNameIndex.effective(
            live: QueueTargetNameIndex(), readOnlyCache: nil, payload: item.payload)
        #expect(effective.displayNames(for: item).names.isEmpty)
        #expect(
            ActivityWindowView.computeRowTitle(
                for: item, wikiName: "Wiki", names: [])
            == "Lint 2 pages")
    }

    // MARK: - Read-only fallback against a real store

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-closedwiki-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Legacy job (no recorded names), wiki closed (absent from `sessions`):
    /// the load resolves the payload's page/source names from the wiki's
    /// real database, skips missing IDs, caches per wiki, and records the
    /// loaded state.
    @Test func readOnlyFallbackResolvesNamesFromRealStoreAbsentFromSessions() async throws {
        let dir = try tempDirectory()
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        let alpha = try store.createPage(title: "Alpha")
        let beta = try store.createPage(title: "Beta")
        let source = try store.addSource(filename: "notes.md", data: Data("# body".utf8))
        _ = try store.createPage(title: "Unrelated") // must NOT enter the cache

        let wikiID = WikiID(rawValue: "closed-wiki")
        let lintJob = QueueItem(
            id: QueueItemID(rawValue: "legacy-lint"),
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(
                sourceIDs: [],
                lintPageIDs: [alpha.id, beta.id, PageID(rawValue: "deleted-page")]),
            state: .completed,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        let ingestJob = QueueItem(
            id: QueueItemID(rawValue: "legacy-ingest"),
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [source.id]),
            state: .completed,
            orderingKey: 2,
            attempt: 0,
            createdAt: 0)

        let tracker = QueueActivityTracker()
        await tracker.refreshClosedWikiNames(
            for: [lintJob, ingestJob],
            sessions: [:], // the wiki's window is closed
            databaseURL: { _ in dir.appendingPathComponent("WikiFS.sqlite") })

        #expect(tracker.closedWikiNameLoadStates[wikiID] == .loaded)
        let index = try #require(tracker.closedWikiNameIndexes[wikiID])
        #expect(index.pageTitle(alpha.id) == "Alpha")
        #expect(index.pageTitle(beta.id) == "Beta")
        // Missing ID: an expected miss, not an error — absent from the cache
        // so the row falls through to the deletion fallback text.
        #expect(index.pageTitle(PageID(rawValue: "deleted-page")) == nil)
        // effectiveName prefers the recorded display name — addSource derives
        // one from the markdown's first heading — over the raw filename.
        #expect(index.sourceName(source.id) == source.effectiveName)
        // Bounded: only the payload's IDs resolved — never the whole wiki.
        #expect(index.pageEntries.count == 2)
        #expect(index.sourceEntries.count == 1)
    }

    /// A failed read (nonexistent database) marks the wiki unavailable and
    /// leaves the cache empty — rows degrade to the fallback text, and the
    /// failure is logged via DebugLog (the state here is the contract).
    @Test func readOnlyFallbackMarksUnavailableWhenDatabaseCannotOpen() async throws {
        let wikiID = WikiID(rawValue: "closed-wiki")
        let item = QueueItem(
            id: QueueItemID(rawValue: "legacy-lint"),
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(
                sourceIDs: [],
                lintPageIDs: [PageID(rawValue: "lp1")]),
            state: .completed,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        let tracker = QueueActivityTracker()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-no-such-db-\(UUID().uuidString).sqlite")
        await tracker.refreshClosedWikiNames(
            for: [item], sessions: [:], databaseURL: { _ in missing })
        #expect(tracker.closedWikiNameLoadStates[wikiID] == .unavailable)
        #expect(tracker.closedWikiNameIndexes[wikiID] == nil)
    }

    /// Open wikis and fully-recorded payloads never reach the read-only
    /// layer: no load is planned, no state is recorded.
    @Test func fullyRecordedPayloadSkipsTheReadOnlyLoad() async throws {
        let wikiID = WikiID(rawValue: "wiki")
        let recorded = QueueItem(
            id: QueueItemID(rawValue: "recorded-lint"),
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(
                sourceIDs: [],
                lintPageIDs: [PageID(rawValue: "lp1")],
                recordedNames: ["lp1": "Already Recorded"]),
            state: .completed,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        let tracker = QueueActivityTracker()
        await tracker.refreshClosedWikiNames(
            for: [recorded], sessions: [:], databaseURL: { _ in nil })
        #expect(tracker.closedWikiNameLoadStates[wikiID] == nil,
                "a fully recorded payload needs no read-only load")
        #expect(tracker.closedWikiNameIndexes[wikiID] == nil)
    }

    // MARK: - Negative cache (review F4)

    /// IDs a completed load proved missing are negative-cached: a second
    /// refresh for the same displayed jobs does NOT reopen the read-only
    /// database (the spy loader is never invoked again), while the found
    /// IDs stay served from the name cache and the missing one keeps the
    /// honest deletion fallback.
    @Test func secondRefreshSkipsKnownMissingIDs() async throws {
        let wikiID = WikiID(rawValue: "closed-wiki")
        let pageID = PageID(rawValue: "pg-keep")
        let missingID = PageID(rawValue: "pg-missing")
        let item = QueueItem(
            id: QueueItemID(rawValue: "legacy-lint"),
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: [pageID, missingID]),
            state: .completed,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        let tracker = QueueActivityTracker()
        let unused = URL(fileURLWithPath: "/unused.sqlite")
        // First load: pg-keep resolves; pg-missing is skipped (notFound).
        await tracker.refreshClosedWikiNames(
            for: [item], sessions: [:],
            databaseURL: { _ in unused },
            loader: { _, pageIDs, _, _ in
                var index = QueueTargetNameIndex()
                for id in pageIDs where id == pageID {
                    index.recordPage(id, title: "Kept")
                }
                return index
            })
        #expect(tracker.closedWikiNameLoadStates[wikiID] == .loaded)

        // A second refresh (an unrelated key change re-planning the same
        // displayed jobs): nothing left to read — the loader must not run.
        await tracker.refreshClosedWikiNames(
            for: [item], sessions: [:],
            databaseURL: { _ in unused },
            loader: { _, _, _, _ in
                Issue.record("known-missing IDs must not reopen the read-only database")
                return QueueTargetNameIndex()
            })
        #expect(tracker.closedWikiNameIndexes[wikiID]?.pageTitle(pageID) == "Kept")
        #expect(tracker.closedWikiNameIndexes[wikiID]?.pageTitle(missingID) == nil,
                "the missing ID stays absent so the row keeps the deletion fallback")
    }

    // MARK: - Cancellation is not unavailability (review F5)

    /// A CANCELLED load is not evidence about the wiki's database: the
    /// load state returns to `.loading` (not `.unavailable`) so the next
    /// `.task(id:)` run re-plans and retries instead of pinning the
    /// deletion fallback text on rows whose read never answered.
    @Test func cancelledLoadRestoresLoadingState() async throws {
        let wikiID = WikiID(rawValue: "closed-wiki")
        let item = QueueItem(
            id: QueueItemID(rawValue: "legacy-lint"),
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(
                sourceIDs: [], lintPageIDs: [PageID(rawValue: "lp1")]),
            state: .completed,
            orderingKey: 1,
            attempt: 0,
            createdAt: 0)
        let tracker = QueueActivityTracker()
        await tracker.refreshClosedWikiNames(
            for: [item], sessions: [:],
            databaseURL: { _ in URL(fileURLWithPath: "/unused.sqlite") },
            loader: { _, _, _, _ in throw CancellationError() })
        #expect(tracker.closedWikiNameLoadStates[wikiID] == .loading,
                "cancellation must restore .loading so a re-run retries")
    }

    // MARK: - Mid-load re-plan (review F3)

    /// Lock-protected call recorder for the `@Sendable` loader seam.
    private final class LoadCallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var pageCalls: [[PageID]] = []
        private var nestedFired = false
        /// Records one loader invocation; returns true exactly once (the
        /// first), so the first call can simulate a job being displayed
        /// mid-load.
        func record(pages: [PageID]) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            pageCalls.append(pages)
            if nestedFired { return false }
            nestedFired = true
            return true
        }
    }

    /// An item displayed while its wiki's load is in flight is re-planned
    /// exactly once after that load: the spy loader's second invocation is
    /// for the second job's page, with no further displayed-set change.
    @Test func midLoadDisplayedItemIsRePlannedAfterTheLoad() async throws {
        let wikiID = WikiID(rawValue: "closed-wiki")
        let pageA = PageID(rawValue: "pg-a")
        let pageB = PageID(rawValue: "pg-b")
        func job(_ id: String, _ pages: [PageID]) -> QueueItem {
            QueueItem(
                id: QueueItemID(rawValue: id),
                queue: .ingestion,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [], lintPageIDs: pages),
                state: .completed,
                orderingKey: 1,
                attempt: 0,
                createdAt: 0)
        }
        let jobA = job("job-a", [pageA])
        let jobB = job("job-b", [pageB])

        let calls = LoadCallRecorder()
        let tracker = QueueActivityTracker()
        let unused = URL(fileURLWithPath: "/unused.sqlite")
        let loader: QueueClosedWikiNameLoader.Load = { _, pageIDs, _, _ in
            let shouldNest = calls.record(pages: pageIDs)
            if shouldNest {
                // While jobA's load is in flight, jobB appears: the refresh
                // must park it on the in-flight wiki, not stack a duplicate
                // read-only connection.
                await tracker.refreshClosedWikiNames(
                    for: [jobB], sessions: [:], databaseURL: { _ in unused })
            }
            var index = QueueTargetNameIndex()
            for id in pageIDs { index.recordPage(id, title: "T-\(id.rawValue)") }
            return index
        }
        await tracker.refreshClosedWikiNames(
            for: [jobA], sessions: [:],
            databaseURL: { _ in unused },
            loader: loader)

        #expect(calls.pageCalls == [[pageA], [pageB]],
                "jobB must be re-planned once after the in-flight load")
        #expect(tracker.closedWikiNameLoadStates[wikiID] == .loaded)
        #expect(tracker.closedWikiNameIndexes[wikiID]?.pageTitle(pageB) == "T-pg-b")
    }

    // MARK: - Click-through seam

    /// Spies recording the effect order for the router scenarios. `@MainActor`
    /// matches the router's isolation (the suite is main-actor too).
    @MainActor
    private final class RouterSpy {
        private(set) var effects: [String] = []
        private(set) var stashedLinks: [(wikiID: WikiID, url: URL)] = []
        private(set) var navigatedIdentities: [QueueWorkspaceTargetIdentity] = []
        var liveStore: WikiStoreModel?

        var router: QueueTargetRouter {
            QueueTargetRouter(
                liveStore: { [weak self] _ in self?.liveStore },
                navigateInSession: { [weak self] _, identity in
                    self?.effects.append("navigate")
                    self?.navigatedIdentities.append(identity)
                },
                stashDeepLink: { [weak self] wikiID, url in
                    self?.effects.append("stash")
                    self?.stashedLinks.append((wikiID: wikiID, url: url))
                },
                openWiki: { [weak self] _ in self?.effects.append("openWiki") })
        }
    }

    /// Closed wiki: the click stashes the `wiki://page` deep link (the #635
    /// cross-window seam `RootView` consumes once the session exists) and
    /// then opens the wiki window. The link parses back to the exact page
    /// ID through the same router the in-wiki transcript uses.
    @Test func clickThroughStashesDeepLinkThenOpensClosedWiki() throws {
        let spy = RouterSpy()
        let wikiID = WikiID(rawValue: "closed-wiki")
        let pageID = PageID(rawValue: "pg-123")
        spy.router.route(.page(pageID), title: "Design Notes", in: wikiID)
        #expect(spy.effects == ["stash", "openWiki"])
        #expect(spy.navigatedIdentities.isEmpty)
        let link = try #require(spy.stashedLinks.first)
        #expect(link.wikiID == wikiID)
        guard case .page(let title, let id, _) = WikiReaderView.linkRoute(for: link.url) else {
            #expect(Bool(false), "the stashed URL must route as a page link")
            return
        }
        #expect(id == pageID)
        #expect(title == "Design Notes")
    }

    /// A source target stashes a `wiki://source` link (#598 reveal seam).
    @Test func clickThroughStashesSourceDeepLink() throws {
        let spy = RouterSpy()
        let sourceID = SourceID(rawValue: "src-9")
        spy.router.route(.source(sourceID), title: "notes.md", in: WikiID(rawValue: "closed-wiki"))
        #expect(spy.effects == ["stash", "openWiki"])
        let url = try #require(spy.stashedLinks.first).url
        guard case .source(_, let id, _, _) = WikiReaderView.linkRoute(for: url) else {
            #expect(Bool(false), "the stashed URL must route as a source link")
            return
        }
        #expect(id == sourceID)
    }

    /// Live session: the navigation lands on the shared store BEFORE the
    /// window focus (the historical #583/#598 order), and no stash happens.
    @Test func clickThroughNavigatesLiveSessionBeforeFocusingWindow() throws {
        let dir = try tempDirectory()
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        let model = WikiStoreModel(store: store)
        let spy = RouterSpy()
        spy.liveStore = model
        spy.router.route(
            .page(PageID(rawValue: "pg-1")), title: "Live", in: WikiID(rawValue: "open-wiki"))
        #expect(spy.effects == ["navigate", "openWiki"])
        #expect(spy.navigatedIdentities == [.page(PageID(rawValue: "pg-1"))])
        #expect(spy.stashedLinks.isEmpty)
    }

    /// An empty/missing recorded title degrades to the raw ID as the link's
    /// title query item — the `id` query still drives the canonical route.
    @Test func deepLinkTitleFallsBackToRawID() throws {
        let pageID = PageID(rawValue: "pg-77")
        let url = QueueTargetRouter.deepLinkURL(for: .page(pageID), title: nil)
        guard case .page(let title, let id, _) = WikiReaderView.linkRoute(for: url) else {
            #expect(Bool(false), "the URL must route as a page link")
            return
        }
        #expect(id == pageID)
        #expect(title == pageID.rawValue)
    }

    // MARK: - Enqueue capture (ingestion chokepoint, IngestGateTests pattern)

    /// A no-op worker factory: we only care about the payload the chokepoint
    /// enqueues, not any work it would do.
    private struct NoopWorkerFactory: QueueWorkerFactory {
        func providerID(for item: QueueItem) async -> ProviderID? { ProviderID(rawValue: "test-ingest") }
        func worker(for item: QueueItem) async throws -> any QueueWorker {
            struct W: QueueWorker { func execute(_ item: QueueItem) async throws {} }
            return W()
        }
    }

    /// `enqueueIngestion` records each source's effective name at enqueue
    /// time — the ingestion counterpart of the two lint view sites'
    /// `recordedNames` capture.
    @Test func ingestionEnqueueRecordsSourceEffectiveNames() async throws {
        let store = try TestStoreFactory.inMemory()
        let model = WikiStoreModel(store: store)
        model.addSource(filename: "notes.md", data: Data("# Heading\n\nbody".utf8))
        model.reloadFromStore()
        let md = try #require(model.sources.first)
        let queueStore = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let engine = QueueEngine(store: queueStore, workerFactory: NoopWorkerFactory())

        await enqueueIngestion(
            sourceIDs: [md.id],
            store: model,
            wikiID: WikiID(rawValue: "test-wiki"),
            queueEngine: engine)

        let snapshot = await engine.snapshot()
        let item = try #require(
            snapshot.activeItems.first { $0.queue == .ingestion && $0.payload.sourceIDs.contains(md.id) })
        // The recorded name is the source's effectiveName AT ENQUEUE TIME —
        // the same string the live index would render. (addSource derives a
        // display name from the markdown's first heading; pin that here so
        // the comparison below is concrete, not tautological.)
        #expect(md.effectiveName == "Heading")
        #expect(item.payload.recordedNames?[md.id.rawValue] == md.effectiveName)
        #expect(item.payload.recordedSourceName(for: md.id) == md.effectiveName)
    }
}
#endif
