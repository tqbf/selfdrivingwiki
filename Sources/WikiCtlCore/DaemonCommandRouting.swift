#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

// Phase 3 of plans/cli-domain-commands.md: the per-family routing seam. A
// parsed command is mapped to a daemon call here — Phase 3 reads AND Phase 4
// writes. Since Phase 5, every registry-selected command MUST map here (an
// unmapped one fails in the runner instead of opening a local store); the
// in-process path serves only explicit `--database-path` fixture runs. The
// daemon EXECUTES the same command layer against its prepared services and
// answers with a uniform `DaemonCommandOutcome`, so the CLI's stdout bytes are
// whatever the command code produced — no formatting is duplicated client-side.

/// One routed daemon call: family + operation + a payload writer that embeds
/// the resolved wiki id. The wiki id is unknown at mapping time (the selector
/// resolves over the socket), so the payload closure receives it.
///
/// `timeout` is the CLIENT deadline for this call, resolved through
/// ``DaemonDomainBudgets``: long-running operations (admin sweeps, workspace
/// merge/reap) open with a deadline ABOVE the daemon's elevated handler budget
/// so the true outcome rides back instead of the client giving up first.
public struct DaemonCommandCall: Sendable {
    let family: DaemonDomainFamily
    let operation: String
    let timeout: TimeInterval
    let payload: @Sendable (_ wikiID: String) throws -> Data

    init(
        family: DaemonDomainFamily,
        operation: String,
        payload: @escaping @Sendable (_ wikiID: String) throws -> Data
    ) {
        self.family = family
        self.operation = operation
        self.timeout = DaemonDomainBudgets.clientTimeout(
            family: family, operation: operation)
        self.payload = payload
    }
}

/// Command → daemon-call mapping for the migrated commands — Phase 3 reads AND
/// Phase 4 writes. `nil` means "no daemon route": since Phase 5 of
/// plans/cli-domain-commands.md a registry-selected command without a route
/// FAILS in `WikiCtlRunner.runOrdinary` (no local fallback) — only an explicit
/// `--database-path` fixture run takes the in-process path, and the commands
/// that return nil here (`wiki` verbs, queue/transcribe/job, `extractor
/// list`, help/version/dump-config) are all dispatched before `runOrdinary`
/// in wikictl's `run()`.
public enum DaemonCommandRoute {

    public static func call(for command: ArgumentParser.Command) -> DaemonCommandCall? {
        switch command {
        case .page(let action):
            return page(action)
        case .source(let action):
            return source(action)
        case .chat(let action):
            return chat(action)
        case .bookmark(let action):
            return bookmark(action)
        case .workspace(let action):
            return workspace(action)
        case .strategy(let action):
            return strategy(action)
        case .logAppend(let kind, let title, let note, let source, let author):
            return DaemonCommandCall(
                family: .log,
                operation: DaemonDomainOperation.Log.logAppend) { wikiID in
                try JSONEncoder().encode(DaemonLogAppendRequest(
                    wikiID: wikiID,
                    kind: kind.rawValue,
                    title: title,
                    note: note,
                    source: source?.rawValue,
                    author: author))
            }
        case .indexSet(let bodyFile, let workspace):
            return DaemonCommandCall(
                family: .log,
                operation: DaemonDomainOperation.Log.indexSet) { wikiID in
                // The index body crosses RESOLVED — `-` (stdin) reads HERE,
                // in the caller's process; the daemon has no caller stdin.
                let body = try readBodyFile(from: bodyFile)
                return try JSONEncoder().encode(DaemonIndexSetRequest(
                    wikiID: wikiID, body: body, workspace: workspace))
            }
        case .admin(let action):
            return admin(action)
        case .extractor(.sync(let packageName, let force)):
            // The ENTIRE command runs daemon-side (catalog + store + durable
            // enqueue through the daemon's queue engine) — the CLI stops
            // writing queue.sqlite directly.
            return DaemonCommandCall(
                family: .extractor,
                operation: DaemonDomainOperation.Extractor.sync) { wikiID in
                try JSONEncoder().encode(DaemonExtractorSyncRequest(
                    wikiID: wikiID, packageName: packageName, force: force))
            }
        case .extractor(.fetch(let packageName, let itemKey, let force)):
            return DaemonCommandCall(
                family: .extractor,
                operation: DaemonDomainOperation.Extractor.fetch) { wikiID in
                try JSONEncoder().encode(DaemonExtractorFetchRequest(
                    wikiID: wikiID, packageName: packageName,
                    itemKey: itemKey, force: force))
            }
        default:
            return nil
        }
    }

    private static func page(_ action: PageCommand.Action) -> DaemonCommandCall? {
        switch action {
        case .list(let json):
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.list) { wikiID in
                try JSONEncoder().encode(DaemonPageListRequest(wikiID: wikiID, json: json))
            }
        case .get(let selector, let json, let workspace):
            let wireSelector = DaemonCommandSelector(page: selector)
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.get) { wikiID in
                try JSONEncoder().encode(DaemonPageGetRequest(
                    wikiID: wikiID,
                    selector: wireSelector,
                    json: json,
                    workspace: workspace))
            }
        case .history(let selector):
            let wireSelector = DaemonCommandSelector(page: selector)
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.history) { wikiID in
                try JSONEncoder().encode(DaemonPageSelectorRequest(
                    wikiID: wikiID, selector: wireSelector))
            }
        case .info(let selector):
            let wireSelector = DaemonCommandSelector(page: selector)
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.info) { wikiID in
                try JSONEncoder().encode(DaemonPageSelectorRequest(
                    wikiID: wikiID, selector: wireSelector))
            }
        case .okfInspect(let versionID, let json):
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.okfInspect) { wikiID in
                try JSONEncoder().encode(DaemonPageOKFInspectRequest(
                    wikiID: wikiID, versionID: versionID.rawValue, json: json))
            }
        case .okfStatus(let versionID, let status):
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.okfStatus) { wikiID in
                try JSONEncoder().encode(DaemonPageOKFStatusRequest(
                    wikiID: wikiID, versionID: versionID.rawValue,
                    status: status?.rawValue))
            }
        case .okfFreshness(let versionID, let input):
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.okfFreshness) { wikiID in
                // The parsed policy crosses as embedded JSON (`--clear` → nil).
                let policy = try input.policy
                return try JSONEncoder().encode(DaemonPageOKFFreshnessRequest(
                    wikiID: wikiID,
                    versionID: versionID.rawValue,
                    policyJSON: policy.map { try JSONEncoder().encode($0) }))
            }
        case .okfVerify(let versionID, let input):
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.okfVerify) { wikiID in
                // The verify freshness (`--ttl`) always anchors on the
                // verification recorded by this same call, so the wire
                // carries whole seconds.
                let ttlSeconds: Int64?
                if case .ttl(let duration, _) = input.freshness {
                    ttlSeconds = duration.components.seconds
                } else {
                    ttlSeconds = nil
                }
                return try JSONEncoder().encode(DaemonPageOKFVerifyRequest(
                    wikiID: wikiID,
                    versionID: versionID.rawValue,
                    verifierJSON: try JSONEncoder().encode(input.verifier),
                    verifiedAt: input.verifiedAt,
                    basisJSON: try JSONEncoder().encode(input.basis),
                    ttlSeconds: ttlSeconds))
            }
        case .add(let id, let title, let bodySource, let expectHead, let createOnly, let workspace, let author, let provenance):
            // Phase 4 write. The body crosses RESOLVED (`-` = stdin reads
            // HERE — the daemon has no caller stdin), and the CLI's
            // environment is merged into provenance BEFORE the wire (the
            // daemon's environment is not the caller's).
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.add) { wikiID in
                let body = try resolveBodySource(bodySource)
                let merged = PageCommand.mergedAgentIngestProvenance(provenance)
                return try JSONEncoder().encode(DaemonPageAddRequest(
                    wikiID: wikiID,
                    id: id?.rawValue,
                    title: title,
                    body: body,
                    expectHead: expectHead?.rawValue,
                    createOnly: createOnly,
                    workspace: workspace,
                    author: author,
                    provenance: merged.map { input in
                        DaemonPageAddRequest.ProvenanceInput(
                            sourceID: input.sourceID.rawValue,
                            role: input.role.rawValue)
                    }))
            }
        case .delete(let id, let unlinkIncoming):
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.delete) { wikiID in
                try JSONEncoder().encode(DaemonPageDeleteRequest(
                    wikiID: wikiID, id: id.rawValue, unlinkIncoming: unlinkIncoming))
            }
        case .revert(let selector, let versionID):
            let wireSelector = DaemonCommandSelector(page: selector)
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.revert) { wikiID in
                try JSONEncoder().encode(DaemonPageRevertRequest(
                    wikiID: wikiID, selector: wireSelector,
                    versionID: versionID.rawValue))
            }
        case .okfCorrect(let versionID, let input):
            // Phase 4 completes the page writes; the correction input crosses
            // as embedded JSON like the verify payload.
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.okfCorrect) { wikiID in
                try JSONEncoder().encode(DaemonPageOKFCorrectRequest(
                    wikiID: wikiID, versionID: versionID.rawValue,
                    inputJSON: try JSONEncoder().encode(input)))
            }
        case .search(let query, let limit):
            // Server-side search: the daemon resolves the BM25 leg, fuses,
            // maps, and renders — the CLI does no catalog work.
            return DaemonCommandCall(
                family: .page, operation: DaemonDomainOperation.Page.search) { wikiID in
                try JSONEncoder().encode(DaemonSearchCommandRequest(
                    wikiID: wikiID, query: query, limit: limit))
            }
        }
    }

    private static func source(_ action: SourceCommand.Action) -> DaemonCommandCall? {
        switch action {
        case .list(let json):
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.list) { wikiID in
                try JSONEncoder().encode(DaemonSourceListRequest(wikiID: wikiID, json: json))
            }
        case .cat(let selector, let markdown):
            let wireSelector = DaemonCommandSelector(source: selector)
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.cat) { wikiID in
                try JSONEncoder().encode(DaemonSourceReadRequest(
                    wikiID: wikiID,
                    selector: wireSelector,
                    markdown: markdown))
            }
        case .export(let selector, let out, let markdown):
            let wireSelector = DaemonCommandSelector(source: selector)
            // The CLI's working directory rides the request: the daemon builds
            // the default output path and writes the exported file THERE.
            let cwd = FileManager.default.currentDirectoryPath
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.export) { wikiID in
                try JSONEncoder().encode(DaemonSourceExportRequest(
                    wikiID: wikiID,
                    selector: wireSelector,
                    out: out,
                    markdown: markdown,
                    cwd: cwd))
            }
        case .info(let selector):
            let wireSelector = DaemonCommandSelector(source: selector)
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.info) { wikiID in
                try JSONEncoder().encode(DaemonSourceInfoRequest(
                    wikiID: wikiID, selector: wireSelector))
            }
        case .search(let query, let limit):
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.search) { wikiID in
                try JSONEncoder().encode(DaemonSearchCommandRequest(
                    wikiID: wikiID, query: query, limit: limit))
            }
        case .addURL(let rawInput, let allowDuplicateURL):
            // Phase 4 write. Parameters only — the duplicate check and the
            // network materialization happen SERVER-side (the daemon owns the
            // fetcher wiring).
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.addURL) { wikiID in
                try JSONEncoder().encode(DaemonSourceAddURLRequest(
                    wikiID: wikiID, url: rawInput,
                    allowDuplicateURL: allowDuplicateURL))
            }
        case .addFile(let path, let name):
            // Phase 4 write. The bytes cross RESOLVED (`-` = stdin reads HERE);
            // `path` rides only for the command layer's default-filename
            // behavior.
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.addFile) { wikiID in
                let bytes = try SourceCommand.readSourceData(path)
                return try JSONEncoder().encode(DaemonSourceAddFileRequest(
                    wikiID: wikiID, path: path, name: name,
                    contentBase64: bytes.base64EncodedString()))
            }
        case .editMarkdown(let selector, let contentSource, let expectedHead):
            // Phase 4 CAS write. The content crosses RESOLVED and the
            // expectation RIDES the request; the store evaluates it inside the
            // write server-side and a stale head comes back as the typed
            // `casConflict`.
            let wireSelector = DaemonCommandSelector(source: selector)
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.editMarkdown) { wikiID in
                let content = try resolveBodySource(contentSource)
                return try JSONEncoder().encode(DaemonSourceEditMarkdownRequest(
                    wikiID: wikiID, selector: wireSelector, content: content,
                    expectedHead: expectedHead.rawValue))
            }
        case .rename(let selector, let to):
            let wireSelector = DaemonCommandSelector(source: selector)
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.rename) { wikiID in
                try JSONEncoder().encode(DaemonSourceRenameRequest(
                    wikiID: wikiID, selector: wireSelector, to: to))
            }
        case .setActive(let selector, let versionID):
            let wireSelector = DaemonCommandSelector(source: selector)
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.setActive) { wikiID in
                try JSONEncoder().encode(DaemonSourceSetActiveRequest(
                    wikiID: wikiID, selector: wireSelector,
                    versionID: versionID.rawValue))
            }
        case .refresh(let selector):
            // Phase 4 write. Parameters only — the origin re-fetch runs
            // SERVER-side.
            let wireSelector = DaemonCommandSelector(source: selector)
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.refresh) { wikiID in
                try JSONEncoder().encode(DaemonSourceRefreshRequest(
                    wikiID: wikiID, selector: wireSelector))
            }
        case .okfInspect(let versionID, let json):
            // Phase 4: the source okf family rides along (mirrors the page
            // family's Phase 3 okf ops).
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.okfInspect) { wikiID in
                try JSONEncoder().encode(DaemonSourceOKFInspectRequest(
                    wikiID: wikiID, versionID: versionID.rawValue, json: json))
            }
        case .okfStatus(let versionID, let status):
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.okfStatus) { wikiID in
                try JSONEncoder().encode(DaemonSourceOKFStatusRequest(
                    wikiID: wikiID, versionID: versionID.rawValue,
                    status: status?.rawValue))
            }
        case .okfFreshness(let versionID, let input):
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.okfFreshness) { wikiID in
                let policy = try input.policy
                return try JSONEncoder().encode(DaemonSourceOKFFreshnessRequest(
                    wikiID: wikiID,
                    versionID: versionID.rawValue,
                    policyJSON: policy.map { try JSONEncoder().encode($0) }))
            }
        case .okfVerify(let versionID, let input):
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.okfVerify) { wikiID in
                let ttlSeconds: Int64?
                if case .ttl(let duration, _) = input.freshness {
                    ttlSeconds = duration.components.seconds
                } else {
                    ttlSeconds = nil
                }
                return try JSONEncoder().encode(DaemonSourceOKFVerifyRequest(
                    wikiID: wikiID,
                    versionID: versionID.rawValue,
                    verifierJSON: try JSONEncoder().encode(input.verifier),
                    verifiedAt: input.verifiedAt,
                    basisJSON: try JSONEncoder().encode(input.basis),
                    ttlSeconds: ttlSeconds))
            }
        case .okfCorrect(let versionID, let input):
            return DaemonCommandCall(
                family: .source, operation: DaemonDomainOperation.Source.okfCorrect) { wikiID in
                try JSONEncoder().encode(DaemonSourceOKFCorrectRequest(
                    wikiID: wikiID, versionID: versionID.rawValue,
                    inputJSON: try JSONEncoder().encode(input)))
            }
        }
    }

    private static func chat(_ action: ChatCommand.Action) -> DaemonCommandCall? {
        switch action {
        case .list(let json):
            return DaemonCommandCall(
                family: .chat, operation: DaemonDomainOperation.Chat.list) { wikiID in
                try JSONEncoder().encode(DaemonChatListRequest(wikiID: wikiID, json: json))
            }
        case .get(let selector):
            let wireSelector = DaemonCommandSelector(chat: selector)
            return DaemonCommandCall(
                family: .chat, operation: DaemonDomainOperation.Chat.get) { wikiID in
                try JSONEncoder().encode(DaemonChatGetRequest(
                    wikiID: wikiID, selector: wireSelector))
            }
        case .rename(let selector, let to):
            // Phase 4 write.
            let wireSelector = DaemonCommandSelector(chat: selector)
            return DaemonCommandCall(
                family: .chat, operation: DaemonDomainOperation.Chat.rename) { wikiID in
                try JSONEncoder().encode(DaemonChatRenameRequest(
                    wikiID: wikiID, selector: wireSelector, to: to))
            }
        case .search(let query, let limit):
            return DaemonCommandCall(
                family: .chat, operation: DaemonDomainOperation.Chat.search) { wikiID in
                try JSONEncoder().encode(DaemonSearchCommandRequest(
                    wikiID: wikiID, query: query, limit: limit))
            }
        }
    }

    // MARK: - bookmark (Phase 3 read + Phase 4 writes)

    private static func bookmark(_ action: BookmarkCommand.Action) -> DaemonCommandCall? {
        switch action {
        case .list(let json):
            return DaemonCommandCall(
                family: .bookmark,
                operation: DaemonDomainOperation.Bookmark.list) { wikiID in
                try JSONEncoder().encode(DaemonBookmarkListRequest(
                    wikiID: wikiID, json: json))
            }
        case .createFolder(let parentID, let name):
            return DaemonCommandCall(
                family: .bookmark,
                operation: DaemonDomainOperation.Bookmark.createFolder) { wikiID in
                try JSONEncoder().encode(DaemonBookmarkCreateFolderRequest(
                    wikiID: wikiID, parentID: parentID, name: name))
            }
        case .addRef(let parentID, let content):
            let ref: DaemonBookmarkRef
            switch content {
            case .page(let id): ref = DaemonBookmarkRef(pageID: id.rawValue)
            case .source(let id): ref = DaemonBookmarkRef(sourceID: id.rawValue)
            case .chat(let id): ref = DaemonBookmarkRef(chatID: id.rawValue)
            case .folder:
                // The parser already rejects folder refs; keep the wire honest.
                return nil
            }
            return DaemonCommandCall(
                family: .bookmark,
                operation: DaemonDomainOperation.Bookmark.addRef) { wikiID in
                try JSONEncoder().encode(DaemonBookmarkAddRefRequest(
                    wikiID: wikiID, parentID: parentID, ref: ref))
            }
        case .rename(let id, let to):
            return DaemonCommandCall(
                family: .bookmark,
                operation: DaemonDomainOperation.Bookmark.rename) { wikiID in
                try JSONEncoder().encode(DaemonBookmarkRenameRequest(
                    wikiID: wikiID, id: id, to: to))
            }
        case .delete(let id):
            return DaemonCommandCall(
                family: .bookmark,
                operation: DaemonDomainOperation.Bookmark.delete) { wikiID in
                try JSONEncoder().encode(DaemonBookmarkDeleteRequest(
                    wikiID: wikiID, id: id))
            }
        case .move(let id, let toParentID, let position):
            return DaemonCommandCall(
                family: .bookmark,
                operation: DaemonDomainOperation.Bookmark.move) { wikiID in
                try JSONEncoder().encode(DaemonBookmarkMoveRequest(
                    wikiID: wikiID, id: id, toParentID: toParentID,
                    position: position))
            }
        }
    }

    // MARK: - workspace (Phase 3 reads + Phase 4 writes)

    private static func workspace(_ action: WorkspaceCommand.Action) -> DaemonCommandCall? {
        switch action {
        case .status(let id):
            return DaemonCommandCall(
                family: .workspace,
                operation: DaemonDomainOperation.Workspace.status) { wikiID in
                try JSONEncoder().encode(DaemonWorkspaceRequest(
                    wikiID: wikiID, id: id.rawValue))
            }
        case .conflicts(let id):
            return DaemonCommandCall(
                family: .workspace,
                operation: DaemonDomainOperation.Workspace.conflicts) { wikiID in
                try JSONEncoder().encode(DaemonWorkspaceRequest(
                    wikiID: wikiID, id: id.rawValue))
            }
        case .create(let name):
            return DaemonCommandCall(
                family: .workspace,
                operation: DaemonDomainOperation.Workspace.create) { wikiID in
                try JSONEncoder().encode(DaemonWorkspaceCreateRequest(
                    wikiID: wikiID, name: name))
            }
        case .abandon(let id):
            return DaemonCommandCall(
                family: .workspace,
                operation: DaemonDomainOperation.Workspace.abandon) { wikiID in
                try JSONEncoder().encode(DaemonWorkspaceIDRequest(
                    wikiID: wikiID, id: id.rawValue))
            }
        case .merge(let id):
            // Long-running: the call opens with the elevated client deadline.
            return DaemonCommandCall(
                family: .workspace,
                operation: DaemonDomainOperation.Workspace.merge) { wikiID in
                try JSONEncoder().encode(DaemonWorkspaceIDRequest(
                    wikiID: wikiID, id: id.rawValue))
            }
        case .refresh(let id):
            return DaemonCommandCall(
                family: .workspace,
                operation: DaemonDomainOperation.Workspace.refresh) { wikiID in
                try JSONEncoder().encode(DaemonWorkspaceIDRequest(
                    wikiID: wikiID, id: id.rawValue))
            }
        case .resolve(let id, let pageID, let body):
            let wireID = id.rawValue
            let wirePageID = pageID.rawValue
            return DaemonCommandCall(
                family: .workspace,
                operation: DaemonDomainOperation.Workspace.resolve) { wikiID in
                    // The merge body crosses RESOLVED (`-` = stdin reads HERE).
                    let content = try resolveBodySource(body)
                    return try JSONEncoder().encode(DaemonWorkspaceResolveRequest(
                        wikiID: wikiID, id: wireID, pageID: wirePageID,
                        content: content))
            }
        case .retry(let id):
            return DaemonCommandCall(
                family: .workspace,
                operation: DaemonDomainOperation.Workspace.retry) { wikiID in
                try JSONEncoder().encode(DaemonWorkspaceIDRequest(
                    wikiID: wikiID, id: id.rawValue))
            }
        case .reap(let ttl):
            // Long-running: the call opens with the elevated client deadline.
            return DaemonCommandCall(
                family: .workspace,
                operation: DaemonDomainOperation.Workspace.reap) { wikiID in
                try JSONEncoder().encode(DaemonWorkspaceReapRequest(
                    wikiID: wikiID, ttlSeconds: Int64(ttl)))
            }
        }
    }

    // MARK: - strategy (Phase 4)

    private static func strategy(_ action: StrategyCommand.Action) -> DaemonCommandCall? {
        switch action {
        case .read(let json):
            return DaemonCommandCall(
                family: .strategy,
                operation: DaemonDomainOperation.Strategy.read) { wikiID in
                try JSONEncoder().encode(DaemonStrategyReadRequest(
                    wikiID: wikiID, json: json))
            }
        case .save(let name, let content, let expect, let json):
            // The instructions cross RESOLVED; the CAS expectation RIDES the
            // request and is evaluated inside the store write server-side.
            let wireExpect = DaemonCommandRoute.expectation(expect)
            return DaemonCommandCall(
                family: .strategy,
                operation: DaemonDomainOperation.Strategy.save) { wikiID in
                    let instructions = try resolveBodySource(content)
                    return try JSONEncoder().encode(DaemonStrategySaveRequest(
                        wikiID: wikiID, name: name, content: instructions,
                        expect: wireExpect, json: json))
            }
        case .reset(let expect, let json):
            return DaemonCommandCall(
                family: .strategy,
                operation: DaemonDomainOperation.Strategy.reset) { wikiID in
                try JSONEncoder().encode(DaemonStrategyResetRequest(
                    wikiID: wikiID,
                    expect: DaemonCommandRoute.expectation(expect), json: json))
            }
        }
    }

    /// The wire form of the CLI's strategy CAS expectation.
    private static func expectation(
        _ expect: StrategyCommand.ExpectedRevision
    ) -> DaemonStrategyExpectation {
        switch expect {
        case .absent: return .absent()
        case .revision(let revision): return .revision(revision.rawValue)
        }
    }

    // MARK: - admin (Phase 4)

    private static func admin(_ action: AdminCommand.Action) -> DaemonCommandCall {
        let dryRun: Bool
        let json: Bool
        switch action {
        case .vacuumBlobs(let dry, let j), .vacuumActivities(let dry, let j),
             .vacuumPageVersions(let dry, let j), .vacuumAll(let dry, let j),
             .repairMIME(let dry, let j):
            dryRun = dry
            json = j
        }
        let operation: String
        switch action {
        case .vacuumBlobs: operation = DaemonDomainOperation.Admin.vacuumBlobs
        case .vacuumActivities: operation = DaemonDomainOperation.Admin.vacuumActivities
        case .vacuumPageVersions: operation = DaemonDomainOperation.Admin.vacuumPageVersions
        case .vacuumAll: operation = DaemonDomainOperation.Admin.vacuumAll
        case .repairMIME: operation = DaemonDomainOperation.Admin.repairMIME
        }
        // Long-running: every admin op opens with the elevated client deadline.
        return DaemonCommandCall(
            family: .admin, operation: operation) { wikiID in
            try JSONEncoder().encode(DaemonAdminRequest(
                wikiID: wikiID, dryRun: dryRun, json: json))
        }
    }
}

extension DaemonCommandSelector {
    init(page: PageCommand.Selector) {
        switch page {
        case .id(let id): self.init(id: id.rawValue)
        case .title(let title): self.init(title: title)
        }
    }

    init(source: SourceCommand.Selector) {
        switch source {
        case .id(let id): self.init(id: id.rawValue)
        case .name(let name): self.init(title: name)
        }
    }

    init(chat: ChatCommand.Selector) {
        switch chat {
        case .id(let id): self.init(id: id.rawValue)
        case .title(let title): self.init(title: title)
        }
    }
}

/// Executes mapped calls over the CLI ⇄ daemon socket. Production resolves
/// the wiki selector through the `wiki` family (typed notFound for an unknown
/// wiki) and then runs the command family op; tests inject the executor.
public struct DaemonCommandRouter: Sendable {

    public struct RoutedOutput: Sendable {
        public let result: SourceCommand.Result
        public let wikiID: WikiID

        public init(result: SourceCommand.Result, wikiID: WikiID) {
            self.result = result
            self.wikiID = wikiID
        }
    }

    public typealias Executor = @Sendable (
        _ call: DaemonCommandCall,
        _ selector: String,
        _ containerDirectory: URL
    ) async throws -> RoutedOutput

    private let executor: Executor

    public init(executor: @escaping Executor) {
        self.executor = executor
    }

    public init() {
        self.executor = { call, selector, containerDirectory in
            // Resolution FIRST — an unknown wiki is the daemon's typed
            // notFound ("no wiki matching <selector>"), and nothing opens for
            // a wiki that does not exist.
            let registry = try DaemonWikiRegistryClient(
                containerDirectory: containerDirectory)
            let descriptor = try await registry.resolveWiki(selector: selector)
            let payload = try call.payload(descriptor.id.rawValue)
            let socket = try DaemonDomainSocketClient(
                containerDirectory: containerDirectory,
                // Per-endpoint client deadline (DaemonDomainBudgets): the
                // long-running operations open with a deadline ABOVE the
                // daemon's elevated handler budget so the true outcome rides
                // back instead of the client giving up first.
                timeout: call.timeout)
            let reply = try await socket.send(
                family: call.family, operation: call.operation, payload: payload)
            let outcome = try DaemonCommandOutcome.decode(reply.payload)
            return RoutedOutput(
                result: try Self.result(from: outcome),
                wikiID: descriptor.id)
        }
    }

    /// Run one routed call, mapping daemon/transport failures onto the CLI's
    /// failure types so the process layer's existing catch paths keep their
    /// exit codes and byte-stable messages. The typed CAS codes
    /// (`casConflict`, `createOnlyConflict`, `expectedTargetMissing`,
    /// `strategyRevisionConflict`) reconstruct the SAME typed store errors the
    /// in-process path threw, so main.swift's existing catch paths print the
    /// byte-stable conflict text and exit 3.
    public func run(
        _ call: DaemonCommandCall,
        selector: String,
        containerDirectory: URL
    ) async throws -> RoutedOutput {
        do {
            return try await executor(call, selector, containerDirectory)
        } catch let error as PageCommand.Failure {
            throw error
        } catch let error as SourceCommand.Failure {
            throw error
        } catch let error as JobCommand.Failure {
            throw error
        } catch let error as SearchSocketError {
            // The fail-fast transport signal (app closed ⇒ socket gone). The
            // message names the cause: "the wikid daemon is not running —
            // launch the app".
            throw PageCommand.Failure.message(error.localizedDescription)
        } catch let error as DaemonDomainError {
            // Typed CAS codes rebuild the typed store error BEFORE the
            // generic-message fallback: the process layer's conflict catch
            // paths (exit 3) are keyed on these types.
            if let conflict = Self.conflictError(from: error) {
                throw conflict
            }
            // Daemon rejections keep their message verbatim: notFound ("no
            // wiki matching …"), command failures, the frame-cap refusal.
            throw PageCommand.Failure.message(error.message)
        }
    }

    /// Rebuild the typed store error from a typed CAS envelope error, so the
    /// CLI's exit-3 catch paths fire exactly as they do in-process. Returns
    /// nil for any error that is not a fully-populated CAS rejection (the
    /// caller falls back to the message path).
    static func conflictError(from error: DaemonDomainError) -> (any Error)? {
        guard let detail = error.conflict else { return nil }
        switch error.code {
        case .casConflict:
            switch detail.kind {
            case "sourceMarkdown":
                guard let targetID = detail.targetID,
                      let expected = detail.expected else { return nil }
                return SourceMarkdownConflictError(
                    sourceID: SourceID(rawValue: targetID),
                    expectedHead: SourceMarkdownVersionID(rawValue: expected),
                    currentHead: detail.actual.map(SourceMarkdownVersionID.init(rawValue:)))
            default:
                guard let targetID = detail.targetID,
                      let expected = detail.expected else { return nil }
                return PageConflictError(
                    pageID: PageID(rawValue: targetID),
                    expectedVersionID: PageVersionID(rawValue: expected),
                    actualVersionID: detail.actual.map(PageVersionID.init(rawValue:)))
            }
        case .createOnlyConflict:
            guard let targetID = detail.targetID else { return nil }
            return PageCreateConflictError(
                pageID: PageID(rawValue: targetID),
                title: detail.title ?? "",
                actualVersionID: detail.actual.map(PageVersionID.init(rawValue:)))
        case .expectedTargetMissing:
            guard let expected = detail.expected else { return nil }
            return PageExpectedTargetMissingError(
                pageID: detail.targetID.map(PageID.init(rawValue:)),
                expectedHead: PageVersionID(rawValue: expected),
                title: detail.title ?? "")
        case .strategyRevisionConflict:
            return WikiStrategyConflictError(
                expectedRevision: detail.expected.flatMap { Int64($0) }
                    .map(WikiStrategyRevision.init),
                currentRevision: detail.actual.flatMap { Int64($0) }
                    .map(WikiStrategyRevision.init),
                currentStrategy: nil)
        default:
            return nil
        }
    }

    private static func result(from outcome: DaemonCommandOutcome) throws -> SourceCommand.Result {
        if let base64 = outcome.bytesBase64 {
            guard let bytes = Data(base64Encoded: base64) else {
                throw PageCommand.Failure.message(
                    "command reply carried an undecodable bytes payload")
            }
            return SourceCommand.Result(
                payload: .bytes(bytes),
                didCommit: outcome.didCommit,
                stderrOutput: outcome.stderr)
        }
        return SourceCommand.Result(
            payload: .text(outcome.text ?? ""),
            didCommit: outcome.didCommit,
            stderrOutput: outcome.stderr)
    }

    // MARK: - job list/get

    /// `wikictl job list/get` over the queue family's durable wiki-items read.
    /// The rendering stays CLI-side (`JobCommand.renderList/renderGet` — pure
    /// presentation over the daemon's items + completed-source set); the
    /// queue.sqlite and wiki store reads happen on the daemon. Returns the
    /// output text and whether a `list` came back EMPTY (the caller writes the
    /// zero-results note to stderr; exit stays 0).
    public func runJob(
        _ action: JobCommand.Action,
        selector: String,
        containerDirectory: URL
    ) async throws -> (output: String, emptyList: Bool) {
        let itemID: String?
        let json: Bool
        switch action {
        case .list(let wantsJSON):
            itemID = nil
            json = wantsJSON
        case .get(let id, let wantsJSON):
            itemID = id.rawValue
            json = wantsJSON
        }
        do {
            let registry = try DaemonWikiRegistryClient(containerDirectory: containerDirectory)
            let descriptor = try await registry.resolveWiki(selector: selector)
            let socket = try DaemonDomainSocketClient(containerDirectory: containerDirectory)
            let reply = try await socket.send(
                family: .queue,
                operation: DaemonDomainOperation.Queue.queueWikiItems,
                payload: try JSONEncoder().encode(DaemonQueueWikiItemsRequest(
                    wikiID: descriptor.id.rawValue,
                    itemID: itemID)))
            guard let payloadData = reply.payload else {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "queueWikiItems reply carried no payload")
            }
            let decoded: DaemonQueueWikiItemsReply
            do {
                decoded = try JSONDecoder().decode(DaemonQueueWikiItemsReply.self, from: payloadData)
            } catch {
                // Name the payload so a wire-shape regression is diagnosable
                // from the failure alone.
                let preview = String(decoding: payloadData.prefix(200), as: UTF8.self)
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "queueWikiItems reply payload could not be decoded "
                        + "(\(error)); began: \(preview)")
            }
            let items: [QueueItem]
            do {
                items = try JSONDecoder().decode([QueueItem].self, from: decoded.itemsJSON)
            } catch {
                let preview = String(decoding: decoded.itemsJSON.prefix(200), as: UTF8.self)
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "queueWikiItems items could not be decoded "
                        + "(\(error)); began: \(preview)")
            }
            let completed = Set(decoded.completedSourceIDs.map(SourceID.init(rawValue:)))
            switch action {
            case .list:
                let output = try JobCommand.renderList(
                    items: items, completedSourceIDs: completed, json: json)
                return (output, items.isEmpty)
            case .get(let id, _):
                guard let item = items.first(where: { $0.id == id }) else {
                    throw JobCommand.Failure.notFound(id)
                }
                let output = try JobCommand.renderGet(
                    item: item, completedSourceIDs: completed, json: json)
                return (output, false)
            }
        } catch let error as PageCommand.Failure {
            throw error
        } catch let error as JobCommand.Failure {
            throw error
        } catch let error as SearchSocketError {
            throw PageCommand.Failure.message(error.localizedDescription)
        } catch let error as DaemonDomainError {
            throw PageCommand.Failure.message(error.message)
        }
    }
}
#endif
