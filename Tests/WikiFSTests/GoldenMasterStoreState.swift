import Foundation
import WikiFSCore
import WikiFSSearch

/// Deterministic golden-master state exporter (plans/daemon-only-access.md
/// Phase 0). The fixture sequence below drives ONE fixed operation script
/// against a fresh wiki database plus a fresh queue database; the exporter
/// dumps the resulting state (pages, versions, provenance, sources, markdown
/// chains, bookmarks, workspaces, strategy, chats, wiki index, log, queue
/// rows, vacuum reports) alongside the emitted `ResourceChangeEvent`
/// sequence. Every ULID and timestamp is normalized to encounter-order
/// counters (`u<n>` / `t<n>`), so the dump is byte-stable across runs of the
/// same build — and any behavior change to writes or event emission shows up
/// as a diff against the committed baseline artifact
/// (`Fixtures/GoldenMasterStoreState/baseline.txt`).
@MainActor
enum GoldenMasterStoreState {
    static let wikiID = WikiID(rawValue: "golden-master")

    // MARK: - Normalization

    /// Maps ULID-shaped tokens and ISO-8601 timestamps to encounter-order
    /// counters. Encounter order is deterministic because the dump is built
    /// in fixed section order.
    final class Normalizer {
        private var ulids: [String: Int] = [:]
        private var stamps: [String: Int] = [:]
        private static let ulidPattern = try! NSRegularExpression(pattern: "[0-9A-HJKMNP-TV-Z]{26}")
        private static let stampPattern = try! NSRegularExpression(
            pattern: "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z")

        func normalize(_ raw: String) -> String {
            var out = raw
            out = replaceMatches(in: out, pattern: Self.stampPattern) { token in
                register(token, into: &stamps, prefix: "t")
            }
            out = replaceMatches(in: out, pattern: Self.ulidPattern) { token in
                register(token, into: &ulids, prefix: "u")
            }
            return out
        }

        private func register(
            _ token: String, into table: inout [String: Int], prefix: String
        ) -> String {
            if let seq = table[token] { return "\(prefix)\(seq)" }
            let seq = table.count + 1
            table[token] = seq
            return "\(prefix)\(seq)"
        }

        private func replaceMatches(
            in text: String,
            pattern: NSRegularExpression,
            replacement: (String) -> String
        ) -> String {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = pattern.matches(in: text, range: nsRange)
            var edits = [(Range<String.Index>, String)]()
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                let token = String(text[range])
                edits.append((range, replacement(token)))
            }
            var out = text
            for (range, value) in edits.reversed() {
                out.replaceSubrange(range, with: value)
            }
            return out
        }
    }

    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func stamp(_ date: Date, _ normalizer: Normalizer) -> String {
        // Timestamps normalize to a CONSTANT: two operations can land in the
        // same clock millisecond on one run and different milliseconds on
        // another, so per-value counters are not cross-run stable. Row order
        // within each section already carries the sequence information.
        _ = date
        return "t*"
    }

    private static func id(_ raw: String, _ normalizer: Normalizer) -> String {
        normalizer.normalize(raw)
    }

    // MARK: - Fixture sequence

    /// The recorded fixture script. Executes against fresh databases and
    /// returns the normalized dump (state + script notes + event sequence).
    /// Errors EXPECTED by the script (duplicate content, CAS conflict) are
    /// recorded as `note` lines so the baseline pins typed-error behavior.
    static func runFixture(
        wikiDirectory: URL, queueURL: URL
    ) async throws -> String {
        let store = try GRDBWikiStore(
            databaseURL: wikiDirectory.appendingPathComponent("WikiFS.sqlite"))
        let bus = WikiEventBus(wikiID: wikiID)
        store.eventBus = bus
        let normalizer = Normalizer()
        var notes: [String] = []
        var events: [ResourceChangeEvent] = []
        let token = bus.subscribe(nil) { event in
            events.append(event)
        }
        defer { bus.unsubscribe(token) }

        let state = try runOperations(store: store, queueURL: queueURL, notes: &notes, normalizer: normalizer)

        // The bus dispatches handlers via main-actor tasks; pump the main
        // actor until the event stream settles. Yields, not sleeps: the exit
        // condition is count stability across consecutive yields, so the wait
        // is scheduler-driven and has no wall-clock budget to overrun under
        // `--parallel` MainActor contention (a truncated settle made two
        // otherwise-identical fixture runs capture different event lists).
        var yieldBudget = 1000
        var settled = false
        while !settled, yieldBudget > 0 {
            let before = events.count
            for _ in 0..<3 {
                await Task.yield()
                yieldBudget -= 1
            }
            settled = events.count == before
        }
        if !settled {
            DebugLog.store("GoldenMaster: event stream never settled within the yield budget")
        }

        let eventLines = events.map { event in
            "event kind=\(event.kind?.rawValue ?? "nil") id=\(id(event.id, normalizer)) change=\(event.change.rawValue) seq=\(event.seq)"
        }
        var dump = "# state\n"
        dump += state
        if !settled {
            // Visible-in-the-diff signal instead of a Testing macro (this
            // exporter is a plain helper): an unsettled event stream makes
            // the determinism comparison fail loudly.
            dump += "# WARNING event stream unsettled\n"
        }
        dump += "# script notes\n"
        dump += notes.map { "note \($0)" }.joined(separator: "\n") + "\n"
        dump += "# events\n"
        dump += eventLines.joined(separator: "\n") + "\n"
        dump += "# end\n"
        return dump
    }

    /// Builds the state dump (already normalized section by section so the
    /// encounter order of ULIDs/timestamps is the section order).
    private static func runOperations(
        store: GRDBWikiStore,
        queueURL: URL,
        notes: inout [String],
        normalizer: Normalizer
    ) throws -> String {
        var out = ""

        // 1. Pages: bootstrap home, two linked pages, a composed upsert.
        let home = try store.createPage(title: "Home", createdBy: "user", provenance: [])
        _ = home
        let alpha = try store.createPage(
            title: "Alpha", body: "Alpha v1 body.\n\nSee [[Beta]].",
            createdBy: "user", provenance: [])
        let beta = try store.createPage(
            title: "Beta", body: "Beta cites [[Alpha]].",
            createdBy: "user", provenance: [])
        try store.updatePage(
            id: alpha.id, title: "Alpha", body: "Alpha v2 body.",
            lastEditedBy: "user", provenance: [])
        let alphaHead = try store.pageHeadVersionID(pageID: alpha.id)
        // Same-actor append within the coalescing window AMENDS the head in
        // place (no new version row, event still emitted).
        let amended = try store.appendPageVersion(
            pageID: alpha.id, title: "Alpha", body: "Alpha v3 body.",
            expectedHeadVersionID: alphaHead, lastEditedBy: "user", provenance: [])
        notes.append("append-amended returned=\(id(amended.rawValue, normalizer))")
        // A different actor is amend-ineligible: a fresh version row.
        let coauthored = try store.appendPageVersion(
            pageID: alpha.id, title: "Alpha", body: "Alpha v4 body.",
            expectedHeadVersionID: amended, lastEditedBy: "coauthor", provenance: [])
        notes.append("append-coauthored returned=\(id(coauthored.rawValue, normalizer))")
        do {
            _ = try store.appendPageVersion(
                pageID: alpha.id, title: "Alpha", body: "Alpha v5 body.",
                expectedHeadVersionID: amended, lastEditedBy: "coauthor", provenance: [])
            notes.append("cas-conflict expected PageConflictError but write SUCCEEDED")
        } catch {
            notes.append("cas-conflict error=\(String(describing: type(of: error)))")
        }
        _ = try store.upsertPage(
            id: nil, title: "Gamma",
            rawBody: "Gamma body linking [[source:notes]].",
            expectation: .expectedAbsence, author: "agent:ingest", provenance: [])
        guard let gammaID = try store.resolveTitleToID("Gamma") else {
            preconditionFailure("fixture: Gamma upsert did not resolve")
        }
        notes.append("resolved gamma=\(id(gammaID.rawValue, normalizer))")

        // 2. Sources: add, duplicate (typed error), markdown chain, rename.
        let sourceBytes = Data("golden notes body".utf8)
        let notesSource = try store.addSource(filename: "notes.txt", data: sourceBytes)
        do {
            _ = try store.addSource(filename: "copy.txt", data: sourceBytes)
            notes.append("duplicate-content expected but write SUCCEEDED")
        } catch let error as WikiStoreError {
            if case .duplicateContent(let existing) = error {
                notes.append("duplicate-content existing=\(id(existing.id.rawValue, normalizer))")
            } else {
                notes.append("duplicate-content unexpected=\(error)")
            }
        }
        let first = try store.appendProcessedMarkdown(
            sourceID: notesSource.id, content: "extracted v1",
            origin: .extraction, note: nil, technique: "fixture-extractor")
        let second = try store.appendProcessedMarkdown(
            sourceID: notesSource.id, content: "extracted v2",
            origin: .extraction, note: nil, technique: "fixture-extractor")
        try store.setActiveMarkdown(sourceID: notesSource.id, to: first.id)
        _ = try store.revertProcessedMarkdown(sourceID: notesSource.id, to: first.id)
        notes.append("markdown-head=\(id(second.id.rawValue, normalizer))")
        try store.renameSource(id: notesSource.id, to: "renamed-notes")

        // 3. Protected deletion: impact then unlink-delete Beta.
        let impact = try store.deletionImpact(for: [.page(beta.id)])
        out += "deletion-impact linkingPages=\(impact.linkingPages.count) bookmarks=\(impact.bookmarks.count) incomingLinks=\(impact.incomingLinkCount)\n"
        let deletion = try store.deleteResources(ResourceDeletionRequest(
            targets: [.page(beta.id)], linkPolicy: .unlink))
        out += "deletion targets=\(deletion.deletedTargets.count) rewritten=\(deletion.rewrittenPageIDs.count) removedBookmarks=\(deletion.removedBookmarkIDs.count) unlinked=\(deletion.incomingLinkCount)\n"

        // 4. Bookmarks: folder + page ref, move, delete ref.
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "Read later"))
        let ref = try store.createBookmarkNode(
            parentID: folder.id, position: 0, content: .page(alpha.id))
        try store.moveBookmarkNode(id: folder.id, toParentID: nil, position: 2)
        try store.deleteBookmarkNode(id: ref.id)

        // 5. Workspaces: speculative merge + abandoned branch.
        let wsMerged = try store.createWorkspace(name: "speculative", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsMerged, pageID: alpha.id, title: "Alpha",
            body: "workspace-staged Alpha body", author: "agent:ingest", provenance: [])
        let mergedIDs = try store.workspaceMerge(workspaceID: wsMerged)
        out += "workspace-merged pages=\(mergedIDs.count)\n"
        let wsAbandoned = try store.createWorkspace(name: "abandoned", activityID: nil)
        try store.abandonWorkspace(id: wsAbandoned)

        // 6. Strategy: create → unchanged (no event) → reset tombstone.
        let revision0 = try store.wikiStrategyRevision()
        let save1 = try store.saveWikiStrategy(
            name: "Golden", instructions: "Write clearly.", expectedRevision: revision0)
        var currentRevision: WikiStrategyRevision? = revision0
        if case .saved(let revision1, _) = save1 {
            notes.append("strategy-revision=\(revision1.rawValue)")
            currentRevision = revision1
        }
        _ = try store.saveWikiStrategy(
            name: "Golden", instructions: "Write clearly.", expectedRevision: currentRevision)
        notes.append("strategy-unchanged-save-emits-nothing")
        _ = try store.saveWikiStrategy(
            name: "Golden", instructions: "   ", expectedRevision: currentRevision)
        notes.append("strategy-reset-tombstone")

        // 7. Chats: create, append, title, delete.
        let chat = try store.createChat(kind: .edit, title: "")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .userText("hello"), .assistantText("hi there"),
        ])
        _ = try store.setChatTitleIfEmpty(chatID: chat.id, title: "Golden chat")
        let doomed = try store.createChat(kind: .edit, title: "doomed")
        try store.deleteChat(id: doomed.id)

        // 8. Wiki index + log.
        try store.updateWikiIndex(body: "# Index\n\n- Alpha")
        _ = try store.appendLog(kind: .ingest, title: "golden-master ingest", note: nil)

        // 9. Queue rows (separate queue.sqlite — daemon-owned from P4).
        let queue = try QueueStore(databaseURL: queueURL)
        let extractionItem = try queue.enqueue(QueueItemRequest(
            queue: .extraction, wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [notesSource.id])))
        let ingestionItem = try queue.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [notesSource.id])))
        try queue.markRunning(id: extractionItem.id, providerID: ProviderID(rawValue: "fixture"))
        try queue.markFailed(id: extractionItem.id, error: "fixture failure")
        try queue.markRunning(id: ingestionItem.id, providerID: ProviderID(rawValue: "fixture"))
        try queue.markCompleted(id: ingestionItem.id)

        // 10. Vacuum sweeps.
        let blobReport = try store.vacuumBlobs(dryRun: false)
        let activityReport = try store.vacuumActivities(dryRun: false)
        let versionReport = try store.vacuumPageVersions(dryRun: false)
        out += "vacuum blobs=\(blobReport.orphanCount)/\(blobReport.bytesReclaimed) activities=\(activityReport.orphanCount) versions=\(versionReport.deletedCount)\n"

        // ---- Dump sections (fixed order) ----
        out += "# pages\n"
        for summary in try store.listPages(sortBy: .titleAZ) {
            let page = try store.getPage(id: summary.id)
            out += "page id=\(id(summary.id.rawValue, normalizer)) title=\(summary.title) body-bytes=\(page.bodyMarkdown.utf8.count)\n"
            for version in try store.pageVersionHistory(pageID: summary.id) {
                out += "  version id=\(id(version.id.rawValue, normalizer)) title=\(version.title) saved=\(stamp(version.savedAt, normalizer))\n"
            }
            for origin in try store.pageEditHistory(pageID: summary.id) {
                out += "  edit agent=\(origin.agentName.rawValue) kind=\(origin.agentKind.rawValue) activity=\(origin.activityKind.rawValue) saved=\(stamp(origin.savedAt, normalizer))\n"
            }
        }

        out += "# sources\n"
        for summary in try store.listSources() {
            out += "source id=\(id(summary.id.rawValue, normalizer)) file=\(summary.filename) display=\(summary.displayName ?? "-") bytes=\(summary.byteSize) role=\(summary.role.rawValue)\n"
            for version in try store.processedMarkdownHistory(sourceID: summary.id) {
                out += "  markdown id=\(id(version.id.rawValue, normalizer)) origin=\(version.origin.rawValue)\n"
            }
            for origin in try store.sourceEditHistory(sourceID: summary.id) {
                out += "  edit agent=\(origin.agentName) kind=\(origin.agentKind) fetched=\(stamp(origin.fetchedAt, normalizer))\n"
            }
        }

        out += "# bookmarks\n"
        for node in try store.listBookmarkNodes() {
            let parent = node.parentID.map { id($0.rawValue, normalizer) } ?? "-"
            out += "bookmark id=\(id(node.id.rawValue, normalizer)) parent=\(parent) position=\(node.position) content=\(describeBookmarkContent(node.content, normalizer))\n"
        }

        out += "# workspaces\n"
        for workspaceID in [wsMerged, wsAbandoned] {
            if let summary = try store.workspaceSummary(id: workspaceID) {
                let refs = try store.workspaceRefs(workspaceID: workspaceID)
                out += "workspace id=\(id(workspaceID.rawValue, normalizer)) name=\(summary.name ?? "-") status=\(summary.status.rawValue) refs=\(refs.count)\n"
            }
        }

        out += "# strategy\n"
        let strategyState = try store.getWikiStrategyState()
        out += "strategy name=\(strategyState.strategy?.name ?? "-") revision=\(strategyState.revision.map { "\($0.rawValue)" } ?? "-")\n"

        out += "# chats\n"
        for summary in try store.listChats() {
            out += "chat id=\(id(summary.id.rawValue, normalizer)) title=\(summary.title) messages=\(summary.messageCount)\n"
            for message in try store.chatMessages(chatID: summary.id) {
                out += "  message seq=\(message.seq) role=\(message.event.chatRole) draft=\(message.isDraft)\n"
            }
        }

        out += "# wiki-index\n"
        let index = try store.getWikiIndex()
        out += "index version=\(index.version) body-bytes=\(index.body.utf8.count)\n"

        out += "# log\n"
        for entry in try store.recentLogEntries(limit: 10) {
            out += "log kind=\(entry.kind.rawValue) title=\(entry.title)\n"
        }

        out += "# queue\n"
        // Recency order (loadRecent: finished_at DESC) races for jobs that
        // complete concurrently — the fixture's extraction and ingestion jobs
        // are independent and their terminal transitions have no scripted
        // order. The golden master pins existence + state, not incidental
        // completion timing, so the section is dumped in a script-derived
        // order instead (same normalization philosophy as ULIDs/timestamps).
        let recentQueueItems = try queue.loadRecent(limit: 50).sorted {
            ($0.queue.rawValue, $0.id.rawValue) < ($1.queue.rawValue, $1.id.rawValue)
        }
        for item in recentQueueItems {
            out += "queue-item id=\(id(item.id.rawValue, normalizer)) queue=\(item.queue.rawValue) state=\(item.state.rawValue) sources=\(item.payload.sourceIDs.count) attempts=\(item.attempt)\n"
        }
        queue.close()
        return out
    }

    private static func describeBookmarkContent(
        _ content: BookmarkNode.Content, _ normalizer: Normalizer
    ) -> String {
        switch content {
        case .folder(let label): return "folder:\(label)"
        case .page(let pageID): return "page:\(id(pageID.rawValue, normalizer))"
        case .source(let sourceID): return "source:\(id(sourceID.rawValue, normalizer))"
        case .chat(let chatID): return "chat:\(id(chatID.rawValue, normalizer))"
        }
    }
}
