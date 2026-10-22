#if os(macOS)
import Foundation
import WikiCtlCore
import WikiDaemonContract
import WikiFSCore

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
    func reply(for request: DaemonDomainRequest) async throws -> Data {
        let outcome = try await execute(request)
        return try Self.encodedOutcomeReply(request, outcome)
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
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown page operation: \(request.operation)")
        }
        // The linter only participates in writes; nil keeps reads off the JS
        // bundle lookup (the in-process path pays it too, for nothing).
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
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown chat operation: \(request.operation)")
        }
        return Self.outcome(try ChatCommand.run(action, in: store))
    }

    // MARK: - bookmark

    private func bookmarkOutcome(_ request: DaemonDomainRequest) async throws -> DaemonCommandOutcome {
        guard request.operation == DaemonDomainOperation.Bookmark.list else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown bookmark operation: \(request.operation)")
        }
        let payload = try decode(DaemonBookmarkListRequest.self, request)
        let store = try await storeForWikiID(payload.wikiID)
        return Self.outcome(try BookmarkCommand.run(.list(json: payload.json), in: store))
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
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown workspace operation: \(request.operation)")
        }
        // Both workspace verbs carry the workspace's owning wiki in `wikiID`;
        // resolve + admit before the read.
        let wikiID = try wikiIDFromPayload(request)
        let store = try await storeForWikiID(wikiID)
        return Self.outcome(try WorkspaceCommand.run(action, in: store))
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

    // MARK: - Shared helpers

    /// Resolve + admit the wiki's store. `payloadWikiID` is the resolved ULID
    /// the CLI sent (it resolved the selector over the `wiki` family first);
    /// raw clients may send a display name — resolution tolerates both.
    private func storeForWikiID(_ payloadWikiID: String) async throws -> WikiStore {
        let wikiID = try resolveWikiID(payloadWikiID)
        return try await daemon.domainCommandStore(wikiID: wikiID)
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
