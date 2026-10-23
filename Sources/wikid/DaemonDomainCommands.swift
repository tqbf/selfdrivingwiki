#if os(macOS)
import Foundation
import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import WikiFSMarkdown
import WikiFSTypes

/// Daemon-side execution of the Phase 3 read-only command families
/// (`plans/cli-domain-commands.md`): `page`, `source`, `chat`, `bookmark`,
/// `workspace`, plus the queue family's `queueWikiItems` read behind
/// `wikictl job list/get`.
///
/// The design point: the daemon EXECUTES the CLI's existing command layer
/// (`PageCommand.run` / `SourceCommand.run` / …) against its prepared store —
/// admitted through ``WikiDaemon/domainCommandStore(wikiID:)``, the same
/// `prepareAndResolveWikiServices` path every other per-wiki operation uses.
/// The command code that produced a command's stdout in-process produces it
/// here, so the byte-stable scripting formats cannot drift and the CLI does
/// zero catalog work.
///
/// Error contract: an unknown wiki is a typed `notFound` resolved FIRST (no
/// store open for a wiki that does not exist); a malformed payload is a typed
/// `invalidRequest`; a command-level failure (missing page, missing source…)
/// propagates as `operationFailed` with the command's own message, which the
/// CLI prints verbatim (`wikictl: <message>`, exit 1).
//
// Sendable invariant: the single stored field is an immutable reference and
// the handler holds no mutable state of its own; `WikiDaemon` is internally
// synchronized (the daemon's queue discipline).
// swiftlint:disable:next unchecked_sendable
final class DaemonDomainCommands: @unchecked Sendable {

    private let daemon: WikiDaemon

    init(daemon: WikiDaemon) {
        self.daemon = daemon
    }

    // MARK: - Family entry

    /// Execute one command-family request and encode the success envelope.
    /// Throws `DaemonDomainError`; the dispatcher wraps any throw into the
    /// typed failure reply.
    ///
    /// Phase 4: the typed store CAS errors (`PageConflictError`,
    /// `PageCreateConflictError`, `PageExpectedTargetMissingError`,
    /// `SourceMarkdownConflictError`, `WikiStrategyConflictError`) are caught
    /// HERE and rethrown as the typed envelope error codes with a structured
    /// `DaemonConflictDetail` — never stringified into `operationFailed`, so
    /// the CLI can rebuild the exact typed error and its byte-stable exit-3
    /// text.
    func reply(for request: DaemonDomainRequest) async throws -> Data {
        let outcome: DaemonCommandOutcome
        do {
            outcome = try await execute(request)
        } catch let error as DaemonDomainError {
            throw error
        } catch let error as PageConflictError {
            throw Self.conflict(
                .casConflict, kind: "page",
                targetID: error.pageID.rawValue,
                expected: error.expectedVersionID.rawValue,
                actual: error.actualVersionID?.rawValue)
        } catch let error as PageCreateConflictError {
            throw Self.conflict(
                .createOnlyConflict, kind: "page",
                targetID: error.pageID.rawValue, title: error.title,
                actual: error.actualVersionID?.rawValue)
        } catch let error as PageExpectedTargetMissingError {
            throw Self.conflict(
                .expectedTargetMissing, kind: "page",
                targetID: error.pageID?.rawValue, title: error.title,
                expected: error.expectedHead.rawValue)
        } catch let error as SourceMarkdownConflictError {
            throw Self.conflict(
                .casConflict, kind: "sourceMarkdown",
                targetID: error.sourceID.rawValue,
                expected: error.expectedHead.rawValue,
                actual: error.currentHead?.rawValue)
        } catch let error as WikiStrategyConflictError {
            throw Self.conflict(
                .strategyRevisionConflict, kind: "strategy",
                expected: error.expectedRevision.map { String($0.rawValue) },
                actual: error.currentRevision.map { String($0.rawValue) })
        }
        return try Self.encodedOutcomeReply(request, outcome)
    }

    /// The typed CAS envelope error: code + structured detail, with a message
    /// that names the shape (the CLI reconstructs its own byte-stable text
    /// from the detail, so this message is diagnostics, not output).
    private static func conflict(
        _ code: DaemonDomainErrorCode,
        kind: String,
        targetID: String? = nil,
        title: String? = nil,
        expected: String? = nil,
        actual: String? = nil
    ) -> DaemonDomainError {
        DaemonDomainError(
            code: code,
            message: "CAS conflict (\(code.rawValue), kind \(kind))",
            conflict: DaemonConflictDetail(
                kind: kind, targetID: targetID, title: title,
                expected: expected, actual: actual))
    }

    private func execute(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        switch request.family {
        case .page:
            return try await pageOutcome(request)
        case .source:
            return try await sourceOutcome(request)
        case .chat:
            return try await chatOutcome(request)
        case .bookmark:
            return try await bookmarkOutcome(request)
        case .workspace:
            return try await workspaceOutcome(request)
        case .strategy:
            return try await strategyOutcome(request)
        case .log:
            return try await logOutcome(request)
        case .admin:
            return try await adminOutcome(request)
        case .extractor:
            return try await extractorOutcome(request)
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown command family: \(request.family.rawValue)")
        }
    }

    // MARK: - page

    private func pageOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        let action: PageCommand.Action
        let store: WikiStore
        switch request.operation {
        case DaemonDomainOperation.Page.list:
            let payload = try decode(DaemonPageListRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .list(json: payload.json)
        case DaemonDomainOperation.Page.get:
            let payload = try decode(DaemonPageGetRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .get(
                try pageSelector(payload.selector), json: payload.json,
                workspace: payload.workspace)
        case DaemonDomainOperation.Page.history:
            let payload = try decode(DaemonPageSelectorRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .history(try pageSelector(payload.selector))
        case DaemonDomainOperation.Page.info:
            let payload = try decode(DaemonPageSelectorRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .info(try pageSelector(payload.selector))
        case DaemonDomainOperation.Page.okfInspect:
            let payload = try decode(DaemonPageOKFInspectRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .okfInspect(
                versionID: PageVersionID(rawValue: payload.versionID), json: payload.json)
        case DaemonDomainOperation.Page.okfStatus:
            let payload = try decode(DaemonPageOKFStatusRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            let status = try payload.status.map { raw in
                guard let value = OKFConceptStatus(rawValue: raw) else {
                    throw DaemonDomainError(
                        code: .invalidRequest,
                        message: "okf status payload carries an unknown status: \(raw)")
                }
                return value
            }
            action = .okfStatus(versionID: PageVersionID(rawValue: payload.versionID), status: status)
        case DaemonDomainOperation.Page.okfFreshness:
            let payload = try decode(DaemonPageOKFFreshnessRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .okfFreshness(
                versionID: PageVersionID(rawValue: payload.versionID),
                input: try freshnessInput(payload.policyJSON, operation: request.operation))
        case DaemonDomainOperation.Page.okfVerify:
            let payload = try decode(DaemonPageOKFVerifyRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            let verifier = try decodeJSON(
                OKFVerifierIdentity.self, payload.verifierJSON, operation: request.operation)
            let basis = try decodeJSON(
                OKFVerificationBasis.self, payload.basisJSON, operation: request.operation)
            let freshness: OKFFreshnessInput?
            if let ttlSeconds = payload.ttlSeconds {
                // The CLI's `--ttl` verification freshness anchors on the
                // verification recorded by this same call.
                freshness = .ttl(.seconds(ttlSeconds), anchor: .recordedVerification)
            } else {
                freshness = nil
            }
            action = .okfVerify(
                versionID: PageVersionID(rawValue: payload.versionID),
                input: OKFVerificationInput(
                    verifier: verifier, verifiedAt: payload.verifiedAt,
                    basis: basis, freshness: freshness))
        case DaemonDomainOperation.Page.okfCorrect:
            let payload = try decode(DaemonPageOKFCorrectRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            let input = try decodeJSON(
                OKFCorrectionInput.self, payload.inputJSON, operation: request.operation)
            action = .okfCorrect(versionID: PageVersionID(rawValue: payload.versionID), input: input)
        case DaemonDomainOperation.Page.search:
            // The FULL search command, server-side: the daemon owns the BM25
            // runtime AND the store, so the leg resolution, RRF fusion, and
            // hit→summary mapping all happen here; the CLI does no catalog
            // work.
            let payload = try decode(DaemonSearchCommandRequest.self, request)
            let wikiID = try resolveWikiID(payload.wikiID)
            store = try await daemon.domainCommandStore(wikiID: wikiID)
            let leg = try await searchLeg(
                kind: .page, query: payload.query, limit: payload.limit,
                wikiID: wikiID, store: store,
                catalog: { try store.listPages(sortBy: .lastUpdated) },
                id: { PageID(rawValue: $0) })
            return Self.outcome(try PageCommand.run(
                .search(query: payload.query, limit: payload.limit),
                in: store, linter: nil, bm25Leg: leg))
        case DaemonDomainOperation.Page.add:
            // Phase 4 write. The body crossed RESOLVED (inline) — the daemon
            // has no caller stdin. The CLI already merged its environment into
            // `provenance`; the command layer re-runs its merge against the
            // DAEMON's environment (normally absent → passthrough).
            let payload = try decode(DaemonPageAddRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            let provenance = try payload.provenance.map { input in
                guard let role = PageVersionSourceRole(rawValue: input.role) else {
                    throw DaemonDomainError(
                        code: .invalidRequest,
                        message: "page add carries an unknown provenance role: \(input.role)")
                }
                return PageVersionSourceInput(
                    sourceID: SourceID(rawValue: input.sourceID), role: role)
            }
            action = .add(
                id: payload.id.map(PageID.init(rawValue:)),
                title: payload.title,
                body: .inline(payload.body),
                expectHead: payload.expectHead.map(PageVersionID.init(rawValue:)),
                createOnly: payload.createOnly,
                workspace: payload.workspace,
                author: payload.author,
                provenance: provenance)
        case DaemonDomainOperation.Page.patch:
            // The exact ranged write (REQ-52). Hunk/class pairs decode at
            // this boundary; the command layer re-validates and applies
            // atomically in exact-body mode — no linter, no fence validator,
            // no canonicalization on this path.
            let payload = try decode(DaemonPagePatchRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            let pairs = try payload.hunks.map { wire -> (PagePatchHunk, LintDefectClass) in
                guard let defect = LintDefectClass(rawValue: wire.defect) else {
                    throw DaemonDomainError(
                        code: .invalidRequest,
                        message: "page patch carries an unknown defect class: \(wire.defect)")
                }
                return (
                    PagePatchHunk(
                        startByte: wire.startByte, endByte: wire.endByte,
                        oldText: wire.oldText, newText: wire.newText, reason: wire.reason),
                    defect
                )
            }
            action = .patch(
                id: PageID(rawValue: payload.id),
                expectHead: PageVersionID(rawValue: payload.expectHead),
                hunks: pairs.map { $0.0 },
                defectClasses: pairs.map { $0.1 },
                author: payload.author)
        case DaemonDomainOperation.Page.delete:
            let payload = try decode(DaemonPageDeleteRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .delete(
                id: PageID(rawValue: payload.id), unlinkIncoming: payload.unlinkIncoming)
        case DaemonDomainOperation.Page.revert:
            let payload = try decode(DaemonPageRevertRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .revert(
                try pageSelector(payload.selector),
                versionID: PageVersionID(rawValue: payload.versionID))
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown page operation: \(request.operation)")
        }
        // Reads keep Phase 3's nil tooling: the linter only participates in
        // writes, so nil keeps reads off the JS bundle lookup (the in-process
        // path pays it too, for nothing).
        //
        // `.add` is a WRITE: the linter AUTO-FIXES the body and the fence
        // validator annotates fenced blocks, so the write must run the exact
        // tooling the in-process CLI path runs — nil here would silently
        // change what gets stored.
        if case .add = action {
            return Self.outcome(try PageCommand.run(
                action, in: store,
                validator: fenceValidator(),
                linter: MarkdownLinter.loadDefault()))
        }
        return Self.outcome(try PageCommand.run(action, in: store, linter: nil))
    }

    // MARK: - source

    private func sourceOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        let action: SourceCommand.Action
        let store: WikiStore
        let cwd: String
        switch request.operation {
        case DaemonDomainOperation.Source.list:
            let payload = try decode(DaemonSourceListRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .list(json: payload.json)
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.cat:
            let payload = try decode(DaemonSourceReadRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .cat(try sourceSelector(payload.selector), markdown: payload.markdown)
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.export:
            let payload = try decode(DaemonSourceExportRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .export(
                try sourceSelector(payload.selector), out: payload.out,
                markdown: payload.markdown)
            // The CLI's working directory rides the request: `export`'s
            // default output path is built (and the file written) HERE, so it
            // must land where the calling agent expects it, not in the
            // daemon's cwd.
            cwd = payload.cwd
        case DaemonDomainOperation.Source.info:
            let payload = try decode(DaemonSourceInfoRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .info(try sourceSelector(payload.selector))
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.search:
            let payload = try decode(DaemonSearchCommandRequest.self, request)
            let wikiID = try resolveWikiID(payload.wikiID)
            store = try await daemon.domainCommandStore(wikiID: wikiID)
            let leg = try await searchLeg(
                kind: .source, query: payload.query, limit: payload.limit,
                wikiID: wikiID, store: store,
                catalog: { try store.listSources() },
                id: { SourceID(rawValue: $0) })
            return try Self.outcome(SourceCommand.run(
                .search(query: payload.query, limit: payload.limit),
                in: store,
                cwd: FileManager.default.currentDirectoryPath,
                bm25Leg: leg))
        case DaemonDomainOperation.Source.addURL:
            // Phase 4 write. The URL identity check, duplicate guard, and the
            // NETWORK MATERIALIZATION all happen here — the daemon owns the
            // fetcher wiring; the CLI sent parameters only.
            let payload = try decode(DaemonSourceAddURLRequest.self, request)
            let store = try await storeForWikiID(payload.wikiID)
            return try Self.outcome(await SourceCommand.runAddURL(
                payload.url, allowDuplicateURL: payload.allowDuplicateURL,
                in: store, fetcher: URLSessionFetcher()))
        case DaemonDomainOperation.Source.addFile:
            // Phase 4 write. The bytes crossed RESOLVED (file/stdin read
            // CLI-side — the daemon has no caller stdin); `path` rides only
            // for the command layer's default-filename behavior.
            let payload = try decode(DaemonSourceAddFileRequest.self, request)
            let store = try await storeForWikiID(payload.wikiID)
            guard let bytes = Data(base64Encoded: payload.contentBase64) else {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "source addFile content is not valid base64")
            }
            return try Self.outcome(try SourceCommand.addFile(
                path: payload.path, name: payload.name, data: bytes, in: store))
        case DaemonDomainOperation.Source.editMarkdown:
            // Phase 4 write with the CAS expectation RIDING the request: the
            // store evaluates it inside the write, and a stale head surfaces
            // as the typed `casConflict` (kind sourceMarkdown).
            let payload = try decode(DaemonSourceEditMarkdownRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .editMarkdown(
                try sourceSelector(payload.selector),
                content: .inline(payload.content),
                expectedHead: SourceMarkdownVersionID(rawValue: payload.expectedHead))
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.rename:
            let payload = try decode(DaemonSourceRenameRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .rename(try sourceSelector(payload.selector), to: payload.to)
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.setActive:
            let payload = try decode(DaemonSourceSetActiveRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .setActive(
                try sourceSelector(payload.selector),
                versionID: SourceMarkdownVersionID(rawValue: payload.versionID))
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.refresh:
            // Phase 4 write. The origin re-fetch runs SERVER-side (the
            // daemon's fetcher wiring); persistence goes through the store's
            // own append seams.
            let payload = try decode(DaemonSourceRefreshRequest.self, request)
            let store = try await storeForWikiID(payload.wikiID)
            return try Self.outcome(await SourceCommand.runRefresh(
                try sourceSelector(payload.selector),
                in: store, fetcher: URLSessionFetcher()))
        case DaemonDomainOperation.Source.okfInspect:
            // Phase 4: the source okf family rides along (mirrors the page
            // family's Phase 3 okf ops).
            let payload = try decode(DaemonSourceOKFInspectRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .okfInspect(
                versionID: SourceMarkdownVersionID(rawValue: payload.versionID),
                json: payload.json)
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.okfStatus:
            let payload = try decode(DaemonSourceOKFStatusRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            let status = try payload.status.map { raw in
                guard let value = OKFConceptStatus(rawValue: raw) else {
                    throw DaemonDomainError(
                        code: .invalidRequest,
                        message: "okf status payload carries an unknown status: \(raw)")
                }
                return value
            }
            action = .okfStatus(
                versionID: SourceMarkdownVersionID(rawValue: payload.versionID),
                status: status)
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.okfFreshness:
            let payload = try decode(DaemonSourceOKFFreshnessRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .okfFreshness(
                versionID: SourceMarkdownVersionID(rawValue: payload.versionID),
                input: try freshnessInput(payload.policyJSON, operation: request.operation))
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.okfVerify:
            let payload = try decode(DaemonSourceOKFVerifyRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            let verifier = try decodeJSON(
                OKFVerifierIdentity.self, payload.verifierJSON, operation: request.operation)
            let basis = try decodeJSON(
                OKFVerificationBasis.self, payload.basisJSON, operation: request.operation)
            let freshness: OKFFreshnessInput?
            if let ttlSeconds = payload.ttlSeconds {
                freshness = .ttl(.seconds(ttlSeconds), anchor: .recordedVerification)
            } else {
                freshness = nil
            }
            action = .okfVerify(
                versionID: SourceMarkdownVersionID(rawValue: payload.versionID),
                input: OKFVerificationInput(
                    verifier: verifier, verifiedAt: payload.verifiedAt,
                    basis: basis, freshness: freshness))
            cwd = FileManager.default.currentDirectoryPath
        case DaemonDomainOperation.Source.okfCorrect:
            let payload = try decode(DaemonSourceOKFCorrectRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            let input = try decodeJSON(
                OKFCorrectionInput.self, payload.inputJSON, operation: request.operation)
            action = .okfCorrect(
                versionID: SourceMarkdownVersionID(rawValue: payload.versionID),
                input: input)
            cwd = FileManager.default.currentDirectoryPath
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown source operation: \(request.operation)")
        }
        return try Self.outcome(SourceCommand.run(action, in: store, cwd: cwd))
    }

    // MARK: - chat

    private func chatOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        let action: ChatCommand.Action
        let store: WikiStore
        switch request.operation {
        case DaemonDomainOperation.Chat.list:
            let payload = try decode(DaemonChatListRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .list(json: payload.json)
        case DaemonDomainOperation.Chat.get:
            let payload = try decode(DaemonChatGetRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .get(try chatSelector(payload.selector))
        case DaemonDomainOperation.Chat.rename:
            // Phase 4 write.
            let payload = try decode(DaemonChatRenameRequest.self, request)
            store = try await storeForWikiID(payload.wikiID)
            action = .rename(try chatSelector(payload.selector), to: payload.to)
        case DaemonDomainOperation.Chat.search:
            let payload = try decode(DaemonSearchCommandRequest.self, request)
            let wikiID = try resolveWikiID(payload.wikiID)
            store = try await daemon.domainCommandStore(wikiID: wikiID)
            let leg = try await searchLeg(
                kind: .chat, query: payload.query, limit: payload.limit,
                wikiID: wikiID, store: store,
                catalog: { try store.listChats() },
                id: { ChatID(rawValue: $0) })
            return Self.outcome(try ChatCommand.run(
                .search(query: payload.query, limit: payload.limit),
                in: store, bm25Leg: leg))
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown chat operation: \(request.operation)")
        }
        return Self.outcome(try ChatCommand.run(action, in: store))
    }

    // MARK: - bookmark

    private func bookmarkOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        let action: BookmarkCommand.Action
        switch request.operation {
        case DaemonDomainOperation.Bookmark.list:
            let payload = try decode(DaemonBookmarkListRequest.self, request)
            action = .list(json: payload.json)
        case DaemonDomainOperation.Bookmark.createFolder:
            let payload = try decode(DaemonBookmarkCreateFolderRequest.self, request)
            action = .createFolder(parentID: payload.parentID, name: payload.name)
        case DaemonDomainOperation.Bookmark.addRef:
            let payload = try decode(DaemonBookmarkAddRefRequest.self, request)
            action = .addRef(parentID: payload.parentID, content: try bookmarkContent(payload.ref))
        case DaemonDomainOperation.Bookmark.rename:
            let payload = try decode(DaemonBookmarkRenameRequest.self, request)
            action = .rename(id: payload.id, to: payload.to)
        case DaemonDomainOperation.Bookmark.delete:
            let payload = try decode(DaemonBookmarkDeleteRequest.self, request)
            action = .delete(id: payload.id)
        case DaemonDomainOperation.Bookmark.move:
            let payload = try decode(DaemonBookmarkMoveRequest.self, request)
            action = .move(id: payload.id, toParentID: payload.toParentID, position: payload.position)
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown bookmark operation: \(request.operation)")
        }
        let wikiID = try wikiIDFromPayload(request)
        let store = try await storeForWikiID(wikiID)
        return Self.outcome(try BookmarkCommand.run(action, in: store))
    }

    /// Rebuild the typed `BookmarkNode.Content` from its wire form: exactly
    /// one id side must be set.
    private func bookmarkContent(_ ref: DaemonBookmarkRef) throws -> BookmarkNode.Content {
        switch (ref.pageID, ref.sourceID, ref.chatID) {
        case (.some(let pageID), nil, nil):
            return .page(PageID(rawValue: pageID))
        case (nil, .some(let sourceID), nil):
            return .source(SourceID(rawValue: sourceID))
        case (nil, nil, .some(let chatID)):
            return .chat(ChatID(rawValue: chatID))
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "bookmark ref must carry exactly one of pageID, sourceID, chatID")
        }
    }

    // MARK: - workspace

    private func workspaceOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        let action: WorkspaceCommand.Action
        switch request.operation {
        case DaemonDomainOperation.Workspace.status:
            let payload = try decode(DaemonWorkspaceRequest.self, request)
            action = .status(id: WorkspaceID(rawValue: payload.id))
        case DaemonDomainOperation.Workspace.conflicts:
            let payload = try decode(DaemonWorkspaceRequest.self, request)
            action = .conflicts(id: WorkspaceID(rawValue: payload.id))
        case DaemonDomainOperation.Workspace.create:
            let payload = try decode(DaemonWorkspaceCreateRequest.self, request)
            action = .create(name: payload.name)
        case DaemonDomainOperation.Workspace.abandon:
            let payload = try decode(DaemonWorkspaceIDRequest.self, request)
            action = .abandon(id: WorkspaceID(rawValue: payload.id))
        case DaemonDomainOperation.Workspace.merge:
            // Long-running: races under DaemonDomainBudgets.longRunningHandler.
            let payload = try decode(DaemonWorkspaceIDRequest.self, request)
            action = .merge(id: WorkspaceID(rawValue: payload.id))
        case DaemonDomainOperation.Workspace.refresh:
            let payload = try decode(DaemonWorkspaceIDRequest.self, request)
            action = .refresh(id: WorkspaceID(rawValue: payload.id))
        case DaemonDomainOperation.Workspace.resolve:
            // `content` crossed RESOLVED (the daemon has no caller stdin); the
            // command layer receives it as an inline body.
            let payload = try decode(DaemonWorkspaceResolveRequest.self, request)
            action = .resolve(
                id: WorkspaceID(rawValue: payload.id),
                pageID: PageID(rawValue: payload.pageID),
                body: .inline(payload.content))
        case DaemonDomainOperation.Workspace.retry:
            let payload = try decode(DaemonWorkspaceIDRequest.self, request)
            action = .retry(id: WorkspaceID(rawValue: payload.id))
        case DaemonDomainOperation.Workspace.reap:
            // Long-running: races under DaemonDomainBudgets.longRunningHandler.
            let payload = try decode(DaemonWorkspaceReapRequest.self, request)
            action = .reap(ttl: TimeInterval(payload.ttlSeconds))
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown workspace operation: \(request.operation)")
        }
        // Every workspace verb carries the workspace's owning wiki in
        // `wikiID`; resolve + admit before the run.
        let wikiID = try wikiIDFromPayload(request)
        let store = try await storeForWikiID(wikiID)
        return Self.outcome(try WorkspaceCommand.run(action, in: store))
    }

    // MARK: - strategy (Phase 4)

    private func strategyOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        let action: StrategyCommand.Action
        switch request.operation {
        case DaemonDomainOperation.Strategy.read:
            let payload = try decode(DaemonStrategyReadRequest.self, request)
            action = .read(json: payload.json)
        case DaemonDomainOperation.Strategy.save:
            // The CAS expectation RIDES the request and is evaluated inside
            // the store write; a stale revision surfaces as the typed
            // `strategyRevisionConflict`.
            let payload = try decode(DaemonStrategySaveRequest.self, request)
            action = .save(
                name: payload.name,
                content: .inline(payload.content),
                expect: try strategyExpectation(payload.expect),
                json: payload.json)
        case DaemonDomainOperation.Strategy.reset:
            let payload = try decode(DaemonStrategyResetRequest.self, request)
            action = .reset(
                expect: try strategyExpectation(payload.expect),
                json: payload.json)
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown strategy operation: \(request.operation)")
        }
        let wikiID = try wikiIDFromPayload(request)
        let store = try await storeForWikiID(wikiID)
        return Self.outcome(try StrategyCommand.run(action, in: store))
    }

    private func strategyExpectation(
        _ expectation: DaemonStrategyExpectation
    ) throws -> StrategyCommand.ExpectedRevision {
        if expectation.absent, expectation.revision == nil {
            return .absent
        }
        if !expectation.absent, let revision = expectation.revision {
            return .revision(WikiStrategyRevision(rawValue: revision))
        }
        throw DaemonDomainError(
            code: .invalidRequest,
            message: "strategy expectation must be absent or carry a revision")
    }

    // MARK: - log family (Phase 4): log append / index set

    private func logOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        let action: LogIndexCommand.Action
        switch request.operation {
        case DaemonDomainOperation.Log.logAppend:
            let payload = try decode(DaemonLogAppendRequest.self, request)
            guard let kind = LogEntry.Kind(rawValue: payload.kind) else {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "log append carries an unknown kind: \(payload.kind)")
            }
            action = .logAppend(
                kind: kind,
                title: payload.title,
                note: payload.note,
                source: payload.source.map(SourceID.init(rawValue:)),
                author: PageAuthor(rawValue: payload.author))
        case DaemonDomainOperation.Log.indexSet:
            // `body` crossed RESOLVED (file/stdin read CLI-side).
            let payload = try decode(DaemonIndexSetRequest.self, request)
            action = .indexSet(body: payload.body, workspace: payload.workspace)
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown log operation: \(request.operation)")
        }
        let wikiID = try wikiIDFromPayload(request)
        let store = try await storeForWikiID(wikiID)
        return Self.outcome(try LogIndexCommand.run(action, in: store))
    }

    // MARK: - admin family (Phase 4): vacuums + MIME repair

    private func adminOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        guard let payloadData = request.payload else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "\(request.operation) carries no payload")
        }
        let payload: DaemonAdminRequest
        do {
            payload = try JSONDecoder().decode(DaemonAdminRequest.self, from: payloadData)
        } catch {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "\(request.operation) payload could not be decoded")
        }
        let wikiID = try wikiIDFromPayload(request)
        let store = try await grdbStoreForWikiID(wikiID)
        // Every admin operation runs under the LONG-RUNNING handler budget
        // (DaemonDomainBudgets) — a whole-store sweep is the operation the
        // elevated ceiling exists for.
        let action: AdminCommand.Action
        switch request.operation {
        case DaemonDomainOperation.Admin.vacuumBlobs:
            action = .vacuumBlobs(dryRun: payload.dryRun, json: payload.json)
        case DaemonDomainOperation.Admin.vacuumActivities:
            action = .vacuumActivities(dryRun: payload.dryRun, json: payload.json)
        case DaemonDomainOperation.Admin.vacuumPageVersions:
            action = .vacuumPageVersions(dryRun: payload.dryRun, json: payload.json)
        case DaemonDomainOperation.Admin.vacuumAll:
            action = .vacuumAll(dryRun: payload.dryRun, json: payload.json)
        case DaemonDomainOperation.Admin.repairMIME:
            action = .repairMIME(dryRun: payload.dryRun, json: payload.json)
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown admin operation: \(request.operation)")
        }
        return try Self.outcome(try AdminCommand.run(action, in: store))
    }

    // MARK: - extractor family (Phase 4): sync/fetch

    /// `wikictl extractor sync/fetch` — the ENTIRE command runs here: catalog
    /// discovery from the daemon's container (the durable machine catalog the
    /// app publishes; the reviewed overlay resolves beside the daemon binary,
    /// the same posture as the app-bundled CLI helper), the store reads, and
    /// the DURABLE ENQUEUE through the daemon's queue engine — the exact
    /// closure the `enqueueItem` operation's handler runs. The CLI never opens
    /// `queue.sqlite`; with the app closed these commands fail fast at
    /// connect (the CLI's old direct-write path is gone — fixture runs use
    /// the build-only `wikictl-fixture` binary).
    private func extractorOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        #if canImport(WikiFSEngine)
        let wikiIDRaw = try wikiIDFromPayload(request)
        let wikiID = try resolveWikiID(wikiIDRaw)
        let store = try await grdbStoreForWikiID(wikiIDRaw)
        let containerDirectory = daemon.containerDirectory
        // The catalog: a fixture daemon's injected double (tests), else the
        // production durable machine catalog (+ the daemon's reviewed
        // overlay).
        let catalog: any ExtractorPackageCatalogReading
        if let injected = daemon.testExtractorCatalog {
            catalog = injected
        } else {
            catalog = try ExtractorSyncCommand.productionCatalogReader(
                containerDirectory: containerDirectory,
                reviewedPackageRoot: ExtractorSyncCommand.reviewedPackageRoot())
        }
        // The enqueue write is the daemon's own durable queue write — the
        // same `engine.enqueue` the `enqueueItem` queue-family operation
        // performs (durable queue.sqlite row; the dispatch scan picks it up).
        let enqueue: @Sendable (SourceID) async throws -> QueueItem.ID? = { sourceID in
            let queueRequest = QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID]))
            return try await self.daemon.performQueueOperation { engine in
                try await engine.enqueue(queueRequest)
            }.value
        }
        switch request.operation {
        case DaemonDomainOperation.Extractor.sync:
            let payload = try decode(DaemonExtractorSyncRequest.self, request)
            let output = try await ExtractorSyncCommand.run(
                packageName: payload.packageName,
                force: payload.force,
                in: store,
                containerDirectory: containerDirectory,
                catalog: catalog,
                enqueueJob: enqueue)
            return DaemonCommandOutcome(text: output, didCommit: true)
        case DaemonDomainOperation.Extractor.fetch:
            let payload = try decode(DaemonExtractorFetchRequest.self, request)
            let output = try await ExtractorFetchCommand.run(
                packageName: payload.packageName,
                itemKey: payload.itemKey,
                force: payload.force,
                in: store,
                containerDirectory: containerDirectory,
                catalog: catalog,
                enqueueJob: enqueue)
            return DaemonCommandOutcome(text: output, didCommit: true)
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown extractor operation: \(request.operation)")
        }
        #else
        throw DaemonDomainError(
            code: .unavailable,
            message: "extractor commands require the engine (this build has none)")
        #endif
    }

    // MARK: - queue family: queueWikiItems (job list/get)

    func queueWikiItemsReply(for request: DaemonDomainRequest) async throws -> Data {
        let payload = try decode(DaemonQueueWikiItemsRequest.self, request)
        let wikiID = try resolveWikiID(payload.wikiID)
        let selected = try await daemon.queueWikiItems(
            wikiID: wikiID,
            itemID: payload.itemID.map(QueueItemID.init(rawValue:)))
        let itemsJSON: Data
        do {
            itemsJSON = try JSONEncoder().encode(selected.items)
        } catch {
            throw DaemonDomainError(
                code: .operationFailed,
                message: "queue items could not be encoded: \(error)")
        }
        let reply = DaemonQueueWikiItemsReply(
            itemsJSON: itemsJSON,
            completedSourceIDs: selected.completedSourceIDs.map(\.rawValue).sorted())
        // The PAYLOAD only — the dispatcher's shared reply encoder wraps it in
        // the envelope (and guards the frame cap).
        return try JSONEncoder().encode(reply)
    }

    // MARK: - queue family: queueItemState (transcribe completion wait)

    func queueItemStateReply(for request: DaemonDomainRequest) async throws -> Data {
        let payload = try decode(DaemonQueueItemStateRequest.self, request)
        let snapshot = try await daemon.queueItemState(
            itemID: QueueItemID(rawValue: payload.itemID))
        let reply = DaemonQueueItemStateReply(
            state: snapshot.state,
            error: snapshot.error)
        // The PAYLOAD only — the dispatcher's shared reply encoder wraps it in
        // the envelope (and guards the frame cap).
        return try JSONEncoder().encode(reply)
    }

    // MARK: - queue family: transcribePreflight (speech enqueue preflight)

    func transcribePreflightReply(for request: DaemonDomainRequest) async throws -> Data {
        let payload = try decode(DaemonTranscribePreflightRequest.self, request)
        let wikiID = try resolveWikiID(payload.wikiID)
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        // The same acceptance rule `GRDBWikiStore.youtubeSpeechPreflight` read
        // CLI-side until Phase 5: the source must exist and its origin agent
        // must be YouTube (the explicit on-device speech scope). A missing
        // source answers inScope=false — the CLI renders one typed failure for
        // missing and non-YouTube alike — never an error.
        let sourceID = SourceID(rawValue: payload.sourceID)
        let summaries = try store.listSources()
        var inScope = false
        if summaries.contains(where: { $0.id == sourceID }) {
            let origin = try store.sourceOrigin(sourceID: sourceID)
            inScope = origin?.provider == SourceProvider.youtube
        }
        return try JSONEncoder().encode(DaemonTranscribePreflightReply(inScope: inScope))
    }

    // MARK: - Shared helpers

    /// The package-driven fence validator, resolved from the daemon's
    /// container — the same resolution the CLI's in-process path performs
    /// (`wikictl` main). An unresolvable layout skips validation (nil
    /// semantics), exactly like the CLI.
    private func fenceValidator() -> (any FenceSyntaxValidating)? {
        do {
            return try FenceSyntaxValidationService(
                layout: RendererPackageStoreLayout(
                    appGroupContainerRoot: daemon.containerDirectory))
        } catch {
            DebugLog.store(
                "wikid: fence validation service unresolvable (skipping validation): \(error)")
            return nil
        }
    }

    /// The daemon-side BM25 leg for the CLI search commands: the daemon's own
    /// per-wiki Tantivy runtime ranks ulids; the store catalog resolves them
    /// to typed summaries (hits naming absent ids are dropped; an all-empty
    /// resolution is NO leg — "no BM25 results", never an error). Mirrors
    /// `CLITantivyLegResolver.resolveHits`, server-side, so the CLI does no
    /// catalog work.
    #if canImport(WikiFSEngine)
    private func searchLeg<Summary: Identifiable & Sendable>(
        kind: TantivyDocumentKind,
        query: String,
        limit: Int,
        wikiID: WikiID,
        store: WikiStore,
        catalog: () throws -> [Summary],
        id: (String) -> Summary.ID
    ) async throws -> [Summary]? {
        let runtime = try await daemon.ensureSearchRuntime(wikiID: wikiID)
        let hits = try await runtime.search(query: query, kinds: [kind], limit: max(0, limit))
        guard !hits.isEmpty else { return nil }
        let byID = Dictionary(try catalog().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let resolved = hits.compactMap { byID[id($0.ulid)] }
        return resolved.isEmpty ? nil : resolved
    }
    #endif

    /// Resolve + admit the wiki's store. `payloadWikiID` is the resolved ULID
    /// the CLI sent (it resolved the selector over the `wiki` family first);
    /// raw clients may send a display name — resolution tolerates both.
    private func storeForWikiID(_ payloadWikiID: String) async throws -> WikiStore {
        let wikiID = try resolveWikiID(payloadWikiID)
        return try await daemon.domainCommandStore(wikiID: wikiID)
    }

    /// The store for the GRDB-specific command seams (`AdminCommand` vacuums,
    /// `ExtractorSync/FetchCommand`): the daemon's prepared store IS a
    /// `GRDBWikiStore` in every production and fixture configuration; a
    /// non-SQLite store is an honest typed failure, not a silent cast.
    private func grdbStoreForWikiID(_ payloadWikiID: String) async throws -> GRDBWikiStore {
        let store = try await storeForWikiID(payloadWikiID)
        guard let grdb = store as? GRDBWikiStore else {
            throw DaemonDomainError(
                code: .operationFailed,
                message: "this command requires the SQLite store backend")
        }
        return grdb
    }

    /// For payloads whose wiki id must be read before the op struct decodes
    /// (the workspace verbs share one struct).
    private func wikiIDFromPayload(_ request: DaemonDomainRequest) throws -> String {
        struct EnvelopeWikiID: Decodable { let wikiID: String }
        let payload = try decode(EnvelopeWikiID.self, request)
        return payload.wikiID
    }

    /// Registry resolution BEFORE any store open: an unknown wiki is the
    /// daemon's typed notFound with the byte-stable "no wiki matching" text.
    private func resolveWikiID(_ rawID: String) throws -> WikiID {
        guard let data = daemon.resolveWiki(selector: rawID) else {
            throw DaemonDomainError(code: .notFound, message: "no wiki matching \(rawID)")
        }
        do {
            return try JSONDecoder().decode(WikiDescriptor.self, from: data).id
        } catch {
            throw DaemonDomainError(
                code: .operationFailed,
                message: "wiki descriptor could not be decoded")
        }
    }

    private func pageSelector(_ selector: DaemonCommandSelector) throws -> PageCommand.Selector {
        if let id = selector.id, selector.title == nil {
            return .id(PageID(rawValue: id))
        }
        if let title = selector.title, selector.id == nil {
            return .title(title)
        }
        throw DaemonDomainError(
            code: .invalidRequest,
            message: "selector must carry exactly one of id or title")
    }

    private func sourceSelector(_ selector: DaemonCommandSelector) throws -> SourceCommand.Selector {
        if let id = selector.id, selector.title == nil {
            return .id(SourceID(rawValue: id))
        }
        if let name = selector.title, selector.id == nil {
            return .name(name)
        }
        throw DaemonDomainError(
            code: .invalidRequest,
            message: "selector must carry exactly one of id or title")
    }

    private func chatSelector(_ selector: DaemonCommandSelector) throws -> ChatCommand.Selector {
        if let id = selector.id, selector.title == nil {
            return .id(ChatID(rawValue: id))
        }
        if let title = selector.title, selector.id == nil {
            return .title(title)
        }
        throw DaemonDomainError(
            code: .invalidRequest,
            message: "selector must carry exactly one of id or title")
    }

    /// Rebuild the CLI's freshness input from the embedded policy JSON.
    /// `nil` data is the `--clear` form.
    private func freshnessInput(
        _ policyJSON: Data?, operation: String
    ) throws -> OKFFreshnessInput {
        guard let policyJSON else { return .clear }
        let policy = try decodeJSON(OKFFreshnessPolicy.self, policyJSON, operation: operation)
        switch policy {
        case .fixed(let date):
            return .fixed(date)
        case .ttl(let seconds, let anchor):
            return .ttl(.seconds(seconds), anchor: anchor)
        }
    }

    private func decode<Payload: Decodable>(
        _ type: Payload.Type, _ request: DaemonDomainRequest
    ) throws -> Payload {
        guard let data = request.payload else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "\(request.operation) carries no payload")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "\(request.operation) payload could not be decoded")
        }
    }

    private func decodeJSON<Type: Decodable>(
        _ type: Type.Type, _ data: Data, operation: String
    ) throws -> Type {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "\(operation) embedded payload could not be decoded")
        }
    }

    // MARK: - Outcome + reply encoding

    private static func outcome(_ result: PageCommand.Result) -> DaemonCommandOutcome {
        DaemonCommandOutcome(
            text: result.output,
            didCommit: result.didCommit,
            stderr: result.stderrOutput)
    }

    private static func outcome(_ result: ChatCommand.Result) -> DaemonCommandOutcome {
        DaemonCommandOutcome(
            text: result.output,
            didCommit: result.didCommit,
            stderr: result.stderrOutput)
    }

    private static func outcome(_ result: BookmarkCommand.Result) -> DaemonCommandOutcome {
        DaemonCommandOutcome(
            text: result.output,
            didCommit: result.didCommit,
            stderr: result.stderrOutput)
    }

    private static func outcome(_ result: WorkspaceCommand.Result) -> DaemonCommandOutcome {
        DaemonCommandOutcome(
            text: result.output,
            didCommit: result.didCommit,
            stderr: result.stderrOutput)
    }

    private static func outcome(_ result: StrategyCommand.Result) -> DaemonCommandOutcome {
        DaemonCommandOutcome(
            text: result.output,
            didCommit: result.didCommit,
            stderr: result.stderrOutput)
    }

    private static func outcome(_ result: SourceCommand.Result) throws -> DaemonCommandOutcome {
        switch result.payload {
        case .text(let text):
            return DaemonCommandOutcome(
                text: text,
                didCommit: result.didCommit,
                stderr: result.stderrOutput)
        case .bytes(let bytes):
            return DaemonCommandOutcome(
                bytesBase64: bytes.base64EncodedString(),
                didCommit: result.didCommit,
                stderr: result.stderrOutput)
        }
    }

    /// Encode the success envelope, guarding the 4 MiB frame cap: a reply
    /// that would exceed it fails TYPED (`operationFailed`) instead of being
    /// truncated or blowing up the connection. Chunked replies are out of
    /// scope (plans/cli-domain-commands.md §"Long-running operations").
    static func encodedOutcomeReply(
        _ request: DaemonDomainRequest, _ outcome: DaemonCommandOutcome
    ) throws -> Data {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(outcome)
        } catch {
            throw DaemonDomainError(
                code: .operationFailed,
                message: "command outcome could not be encoded: \(error)")
        }
        return try frameCappedReply(request, payload: payload)
    }

    private static func frameCappedReply(
        _ request: DaemonDomainRequest, payload: Data
    ) throws -> Data {
        let envelope = DaemonDomainReply.success(
            requestID: request.requestID,
            family: request.family,
            operation: request.operation,
            payload: payload)
        let encoded = try DaemonDomainWire.encode(envelope)
        guard encoded.count <= Int(SearchSocketWire.maxFrameSize) else {
            throw DaemonDomainError(
                code: .operationFailed,
                message: "reply payload (\(encoded.count) bytes) exceeds the socket frame cap "
                    + "(\(SearchSocketWire.maxFrameSize) bytes) — use a narrower read "
                    + "(for example `source export --out <file>`); nothing was truncated")
        }
        return encoded
    }
}
#endif
