#if os(macOS)
import CryptoKit
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes

// Phase 2d slice 1 (plans/daemon-only-access.md): the RemoteWikiStore CLIENT
// core — the concrete `WikiStore` conformer whose operations cross the
// daemon's structured store family (`.store` domain envelopes carrying one
// `DaemonStoreRequest` / `DaemonStoreReply` pair) instead of opening SQLite
// in-process. The daemon-side semantics this client speaks live in
// `Sources/wikid/DaemonStoreCommandExecutor.swift`; the wire shapes live in
// `Sources/WikiDaemonContract/DaemonStoreWire.swift` + the per-family DTO
// files.
//
// Discipline this file preserves (the mirror image of the executor's):
// - Idempotent reads carry NO mutation stamp; every stamped mutator stamps a
//   fresh `DaemonMutationStamp(requestID: ULID, expectedEpoch:)` from the
//   cached handshake epoch. An epoch-mismatch rejection reconstructs as
//   ``RemoteStoreClientError/epochMismatch`` so the caller's restart
//   detection is reachable typed, never a string.
// - Store-level failures arrive INSIDE the `DaemonStoreReply` envelope; this
//   client reconstructs the SAME typed error the in-process path would have
//   thrown (``reconstructStoreError`` — the exact inverse of the executor's
//   `wireError`, associated values intact).
// - Transport failures are typed (`daemonUnavailable`), never retried
//   blindly: an unknown mutation outcome sends the caller to change-token
//   reconciliation.
// - Every call races a per-call deadline (``defaultCallDeadline``, tunable
//   per store). No bare continuation ever waits unbounded (repo rule #1051).
// - The composed atomic operations (`upsertPage`, `deleteResources`,
//   `addSource`) are direct implementations here — never the protocol
//   extension's sequential defaults (plan 2b requirement). Slice 2 wired
//   the ENTIRE remaining manifest-rpc surface (138 operations) across the
//   four family files beside this core (`+SmallSurface`, `+ListSurface`,
//   `+BlobSurface`, `+EventProducerSurface`, with the shared inverse
//   mappings in `+MirrorMapping`); only the 15 deliberately removed
//   requirements still reject typed from
//   `RemoteWikiStore+PendingSurface.swift`.
//
// Event feed (plan 2c client side): the store conforms to
// `WikiDaemonEventSink`, so session wiring (or a test) registers it with the
// daemon's exporter; `deliverEvent` decodes `DaemonStoreEventEnvelope`
// payloads, drops `sequence <=` the epoch's watermark, adopts epoch changes
// (never dedupes across epochs), feeds each batch into `eventBus`, updates
// the cached change tokens, and fires ``onReloadSignal`` once when a token
// advance or a sequence gap needs one reconciliation reload.
//
// Sendable: internal mutable state is NSLock-guarded; the three client
// properties (`eventBus`, registered inputs, renderer types) follow
// `GRDBWikiStore`'s convention — set once by the app wiring during wiki open.

// MARK: - Client-level errors

/// The error surface this client adds on top of the reconstructed store
/// errors. Everything the wire carries as a `WikiStoreError` mirror or a CAS
/// detail reconstructs as the core typed error (associated values intact);
/// these cases carry what only the CLIENT can know: transport reachability,
/// unknown mutation outcomes, epoch/restart detection, and the pending
/// operation witness.
public enum RemoteStoreClientError: Error, Sendable, Equatable,
    LocalizedError {
    /// The daemon is unreachable or the connection died before an answer
    /// (wire `.daemonUnavailable`). Nothing queues locally; no local
    /// fallback exists.
    case daemonUnavailable(String)
    /// A mutation may or may not have committed (wire `.outcomeUnknown`):
    /// post-eviction resolve or daemon restart. Reconcile through change
    /// tokens; never blind-retry.
    case outcomeUnknown(String)
    /// The daemon's epoch moved under a stamped mutation — a restarted
    /// daemon never replays one. `expectedEpoch` is the stamp's value,
    /// `actualEpoch` the daemon's answer. The caller re-reads state,
    /// re-handshakes, and resubmits with a NEW requestID.
    case epochMismatch(expectedEpoch: UInt64, actualEpoch: UInt64?, message: String)
    /// A `WikiStore` requirement this build deliberately does not serve
    /// (the 15 manifest-removed requirements). Carries the operation name.
    case unsupportedRemote(operation: String)
    /// The reply envelope could not be decoded into the store family's
    /// shapes — a contract violation, surfaced typed.
    case malformedReply(String)
    /// The per-call deadline expired before the transport answered.
    case deadlineExceeded(operation: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .daemonUnavailable(let message):
            return "The wiki daemon is unavailable: \(message)"
        case .outcomeUnknown(let message):
            return "Mutation outcome unknown: \(message)"
        case .epochMismatch(let expected, let actual, let message):
            return "Daemon epoch mismatch (expected \(expected), "
                + "actual \(actual.map(String.init(describing:)) ?? "unknown")): "
                + message
        case .unsupportedRemote(let operation):
            return "Operation '\(operation)' is not served by RemoteWikiStore "
                + "in this build (pending slice-2 wiring or deliberately "
                + "removed from the remote surface)"
        case .malformedReply(let message):
            return "Malformed store reply: \(message)"
        case .deadlineExceeded(let operation, let seconds):
            return "Store operation '\(operation)' exceeded its "
                + "\(seconds)s deadline"
        }
    }
}

// MARK: - Transport

/// The connection abstraction under the store: one `.store`-family round
/// trip. The production conformer runs the framed domain socket
/// (``DomainSocketStoreTransport``); tests substitute the in-process
/// executor path where the fixture daemon's sink correlation
/// (`sinkRegistrationID`) is reachable.
public protocol RemoteWikiStoreTransport: Sendable {
    /// Encode-and-send is the caller's job; the transport carries ONE
    /// domain envelope and returns ONE reply. A transport-level failure
    /// (connect, write, read, deadline) throws.
    func send(
        _ request: DaemonDomainRequest,
        sinkRegistrationID: UUID?
    ) async throws -> DaemonDomainReply

    /// The correlation id this transport's connection contributes to staged
    /// uploads. The daemon's `DaemonPayloadStagingStore.dropUploads(
    /// connectionID:)` seam keys uploads to a connection so a disconnect
    /// reaps them early — today the executor's `stagedPayloadReply` passes
    /// no connection id (nil), so nothing is derivable to send yet; when the
    /// server side wires the key, the socket transport reports its identity
    /// here and the store threads it into `payloadBegin`.
    var connectionIdentifier: String? { get }
}

/// The production transport: the CLI's established one-round-trip-per-call
/// domain socket client (``DaemonDomainSocketClient``), which already bounds
/// connect/write/read phases by the deadline. One connection per call, one
/// request per connection.
public struct DomainSocketStoreTransport: RemoteWikiStoreTransport {
    private let client: DaemonDomainSocketClient

    public init(client: DaemonDomainSocketClient) {
        self.client = client
    }

    public var connectionIdentifier: String? { nil }

    public func send(
        _ request: DaemonDomainRequest,
        sinkRegistrationID: UUID? = nil
    ) async throws -> DaemonDomainReply {
        try await client.send(
            family: .store,
            operation: request.operation,
            payload: request.payload,
            version: request.version)
    }
}

// MARK: - The store

public final class RemoteWikiStore: NSObject, WikiStore, WikiDaemonEventSink,
    // swiftlint:disable:next unchecked_sendable
    @unchecked Sendable {
    // Sendable invariant: ALL mutable session state (`state`) sits behind
    // `stateLock`, with every lock acquisition inside synchronous helpers
    // (`beginSessionAttempt`, `lockedApplyHandshake`, `consume`, …) so no
    // async context holds or reaches the lock directly. The three client
    // properties (`eventBus`, `registeredExtractionInputs`,
    // `registeredRendererSourceTypes`) follow `GRDBWikiStore`'s established
    // convention: set once by the app wiring during wiki open, read-only
    // afterwards.

    /// The per-call send deadline (seconds). DaemonWorkloadClient-style:
    /// every call races THIS value against its transport round trip; the
    /// first side to finish wins. Tunable per store at init; this constant
    /// is the default every ordinary session uses.
    public static let defaultCallDeadline: TimeInterval = 30

    /// The wiki every operation scopes to (the store family's envelope
    /// `wikiID`; admission, watermark, and dispatch scope daemon-side).
    public let wikiID: WikiID

    private let transport: any RemoteWikiStoreTransport
    private let callDeadline: TimeInterval

    // MARK: Session state (NSLock-guarded)

    private enum HandshakePhase: Equatable {
        /// No handshake attempted yet this epoch lifecycle.
        case idle
        /// A handshake round trip is in flight; joiners await its result.
        case awaiting
        /// The acknowledged handshake completed; the epoch is cached.
        case live
    }

    private struct SessionState {
        var phase: HandshakePhase = .idle
        /// The daemon epoch cached from the handshake — the value every
        /// mutation stamp carries as `expectedEpoch`.
        var epoch: UInt64?
        /// The in-flight handshake, so concurrent first callers join one
        /// round trip instead of stampeding the daemon.
        var handshakeTask: Task<DaemonSinkHandshakeReply, Error>?
        /// The sink registration id threaded into handshake requests (the
        /// XPC exporter correlates it; the domain-socket transport cannot).
        var sinkRegistrationID: UUID?
        /// Event-watermark state, KEYED BY EPOCH (plan 2c): a daemon
        /// restart's sequence restart must never be read as a duplicate.
        var watermarkEpoch: UInt64?
        /// Per-wiki last-delivered sequence under `watermarkEpoch`.
        var watermarks: [String: UInt64] = [:]
        /// Per-wiki cached change token (the reconciliation anchor).
        var changeTokens: [String: String] = [:]
        /// Events that arrived before the handshake completed (bounded —
        /// the daemon's replay ring is the authoritative bound; this client
        /// buffer caps independently so a stalled handshake cannot grow it
        /// unbounded).
        var preHandshake: [DaemonStoreEvent] = []
    }

    /// Upper bound on the client-side pre-handshake buffer. Overflow drops
    /// the OLDEST entry and flags a gap — the handshake's change token then
    /// drives exactly one reconciliation reload, matching the daemon's own
    /// ring-overflow semantics.
    private static let preHandshakeBufferLimit =
        DaemonStoreLimits.sinkEventBufferCapacity * 4

    private let stateLock = NSLock()
    private var state = SessionState()

    /// Set once (or rarely) by the session wiring: the bus every delivered
    /// store event feeds. See `WikiStore.eventBus`.
    public var eventBus: WikiEventBus?

    /// See `WikiStore.registeredExtractionInputs`. The session wiring sets
    /// this from the 2e bootstrap payload (``applyBootstrap``) or from the
    /// local registry; the store only holds it.
    public var registeredExtractionInputs: RegisteredExtractionInputs = .none

    /// See `WikiStore.registeredRendererSourceTypes`. Settable surface only
    /// in this slice: the wire bootstrap carries the renderer claims as a
    /// presentation SUBSET (`DaemonRendererSourceClaim`) whose full core
    /// claims need the descriptor catalog, so composition stays in the
    /// session wiring (slice 2e).
    public var registeredRendererSourceTypes: RegisteredRendererSourceTypes = .none

    // MARK: Reconnect reconciliation hook

    /// Fired at most once per detection when the daemon's side of the
    /// contract says this client's cached view may be stale: a handshake
    /// change token advanced past the cached anchor, a delivered event's
    /// sequence skipped (bounded-buffer drop), or the epoch changed (daemon
    /// restart). The session wiring slice installs ONE closure — a single
    /// reload signal; the store never fires it per event.
    public var onReloadSignal: (@Sendable () -> Void)?

    /// Task identities already used to fire ``onReloadSignal`` in this epoch
    /// lifecycle (lock-guarded): coalesces bursts into ONE signal.
    private var reloadSignalFired = false

    public init(
        transport: any RemoteWikiStoreTransport,
        wikiID: WikiID,
        callDeadline: TimeInterval = RemoteWikiStore.defaultCallDeadline
    ) {
        self.transport = transport
        self.wikiID = wikiID
        self.callDeadline = callDeadline
        super.init()
    }

    // MARK: - Surface ledger (the SLICE-2 LEDGER contract)

    /// The operation names wired end-to-end across the store family: every
    /// manifest-rpc operation minus two deferred reads (small 35 / list 25 /
    /// blob 39 / event-producer 50; the deferred pair needs a public init
    /// in WikiFSCore - see the pending-surface file) — tmp/store-ops-manifest.md). The implementations live in the
    /// family surface files beside this core (small/list/blob/eventProducer)
    /// plus the slice-1 exemplars here; the ledger test pins the exact set.
    /// The only `WikiStore` requirements that still reject typed are the
    /// 15 ``removedOperations`` in the pending-surface file.
    public static let wiredOperations: Set<String> = [
        // small (37)
        "resolveTitleToID", "hasProcessedMarkdown", "getMetadata",
        "pageHeadVersionID", "setMetadata",
        "activeContentVersion", "activeExtractionProvenance",
        "chatAttachments", "chatTranscriptCheckpoint", "chatUsageSummary",
        "fetchState", "getChat", "getWikiStrategyState", "hasImageSiblings",
        "pageOKFMetadata", "sourceMarkdownOKFMetadata",
        "initialContentVersion", "pageHeadSources",
        "pageOrigin", "pageVersionSources", "rendererInputByteCount",
        "rendererSourcePreference", "rendererSourcePresentation",
        "resolveChatByTitle", "resolveSourceByName", "searchSimilar",
        "searchSimilarChats", "searchSimilarSources",
        "sourceMatchingURLIdentity",
        "sourceOrigin", "sourceVersion", "vacuumActivities", "vacuumBlobs",
        "vacuumPageVersions", "wikiStrategyRevision", "workspacePageVersion",
        "workspaceSummary",
        // list (25)
        "listPages", "listChats", "deletionImpact",
        "chatMessages", "embedDescriptors", "listAllChatsOrderedByID",
        "listBookmarkNodes", "listPersistedChatTurns", "listSources",
        "markedSourceIDs", "pageEditHistory", "pagesCitingSources",
        "pageVersionHistory", "processedMarkdownAgentNames",
        "processedMarkdownAlternatives", "processedMarkdownHistory",
        "readChatTranscriptPage", "recentLogEntries", "siblingImageResolvers",
        "sourceDerivedChains", "sourceEditHistory", "sourceOriginsBySource",
        "sourcesWithPendingFormatJobs", "workspaceConflicts", "workspaceRefs",
        // blob (39)
        "getPage", "upsertPage", "addSource",
        "addSnapshotImage", "appendChatMessages", "appendChatTranscriptItems",
        "appendContentVersion", "appendDerivedMarkdown", "appendFetchMarkdown",
        "appendHostSpeechTranscript", "appendInstalledPackageMarkdown",
        "appendPageVersion", "appendProcessedMarkdown",
        "appendUserProcessedMarkdown", "attachAcquiredBytes",
        "checkpointStreamingMessage", "claimNextPersistedChatTurn",
        "createPage", "enqueuePersistedChatTurn", "finishPersistedChatTurn",
        "getWikiIndex", "getWikiStrategy", "missingChatEmbeddingWork",
        "missingPageEmbeddingWork", "missingSourceEmbeddingWork",
        "pageVersionBody", "processedMarkdownHead", "processedMarkdownVersion",
        "recordMarkdownExtraction", "saveWikiStrategy", "setWorkspaceIndexBody",
        "sourceContent", "storeChatChunks", "storePageChunks",
        "storeSourceChunks", "updatePage", "updateWikiIndex",
        "workspacePageBody", "workspaceWritePage",
        // event producer (50)
        "createChat", "deleteResources",
        "abandonWorkspace", "addBytelessSource", "appendLog",
        "cancelUnclaimedPersistedChatTurn", "correctPageOKFVerification",
        "correctSourceMarkdownOKFVerification", "createBookmarkNode",
        "createWorkspace", "deleteBookmarkNode", "deleteChat",
        "ensureFetchActivity", "finalizeStaleDrafts", "markFetchComplete",
        "markPersistedChatTurnProviderSubmitted", "markSourceIngested",
        "moveBookmarkNode", "reapStaleWorkspaces", "recordPageOKFVerification",
        "recordSourceMarkdownOKFVerification",
        "removeRendererSourcePresentation", "renameBookmarkFolder",
        "renameChat", "renameSource", "repairMIME", "replaceLinks",
        "restorePage", "retargetBookmarkNode", "revertPage",
        "setActiveMarkdown", "setChatAttachments", "setChatTitleIf",
        "setChatTitleIfEmpty", "setPageOKFFreshness", "setPageOKFStatus",
        "setRendererSourcePreference", "setRendererSourcePresentation",
        "setSourceDisplayName", "setSourceMarkdownOKFFreshness",
        "setSourceMarkdownOKFStatus", "updateChatAcpSessionId",
        "updateChatModelAndThinkingSelection", "updateChatModelOverride",
        "updateMessageSummary", "updatePersistedChatTurnUsage",
        "workspaceMerge", "workspaceRefresh", "workspaceResolveConflict",
        "workspaceRetryMerge",
    ]

    /// The 15 `WikiStore` requirements deliberately absent from the remote
    /// surface (tmp/store-ops-manifest.md "removed"): no production consumer
    /// reaches them after the daemon-only cutover, so every one rejects
    /// typed as ``RemoteStoreClientError/unsupportedRemote``. The 2f
    /// exhaustiveness test verifies each is genuinely unreachable.
    public static let removedOperations: Set<String> = [
        "chatTurnUsage", "deletePage", "deleteSource", "editPersistedChatTurn",
        "extractionProvenance", "latestChatTurnUsage",
        "listRendererSourcePreferences", "pageLinkingPages",
        "removePersistedQueuedChatTurn", "rendererSettingsJournalRecords",
        "revertProcessedMarkdown", "setAcquisitionProvenance",
        "sourceLinkingPages", "sourceProvenanceBlockers",
        "sourceReferencingPageVersions",
    ]

    // MARK: - Typed-rejection witness (shared by the pending surface)

    /// The witness rejection every pending/removed operation throws. Private:
    /// only this type's two files produce it, and the 2f test pins the
    /// classification.
    static func unsupportedRemote(_ operation: String) -> Error {
        RemoteStoreClientError.unsupportedRemote(operation: operation)
    }

    // MARK: - Deadline mechanics

    /// Race `operation` against the deadline. The losing side is cancelled;
    /// the winning side's result (or error) is the answer. Never a bare
    /// continuation (repo rule #1051): a hung transport produces a typed
    /// ``RemoteStoreClientError/deadlineExceeded`` instead of a stalled
    /// caller.
    private func withDeadline<T: Sendable>(
        _ operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let seconds = callDeadline
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw RemoteStoreClientError.deadlineExceeded(
                    operation: operation, seconds: seconds)
            }
            guard let first = try await group.next() else {
                throw RemoteStoreClientError.malformedReply(
                    "deadline race produced no result")
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Transport core

    /// Encode one store request, race the send against the deadline, decode
    /// the store reply, and unwrap the result bytes — or reconstruct the
    /// typed error. `operation` names the `DaemonStoreOperation` raw value.
    /// Internal: the slice-2 family extension files share the same send
    /// path (never a second transport seam).
    func sendStore(
        _ operation: DaemonStoreOperation,
        payload: Data? = nil,
        stamp: DaemonMutationStamp? = nil
    ) async throws -> Data {
        let storeRequest = DaemonStoreRequest(
            wikiID: wikiID.rawValue,
            operation: operation.rawValue,
            stamp: stamp,
            payload: payload)
        let domainRequest = DaemonDomainRequest(
            requestID: UUID().uuidString,
            family: .store,
            operation: operation.rawValue,
            payload: try DaemonStoreWire.encode(storeRequest))

        let reply = try await withDeadline(operation.rawValue) { [transport] in
            try await transport.send(domainRequest, sinkRegistrationID: nil)
        }

        // Domain-level rejection (undecodable outer envelope, unknown
        // operation): the established domain-command convention throws.
        if let domainError = reply.error {
            throw RemoteStoreClientError.daemonUnavailable(
                "domain rejection \(domainError.code.rawValue): "
                    + domainError.message)
        }
        guard let payloadData = reply.payload else {
            throw RemoteStoreClientError.malformedReply(
                "\(operation.rawValue) reply carried no payload")
        }
        let storeReply: DaemonStoreReply
        do {
            storeReply = try DaemonStoreWire.decodeReply(payloadData)
        } catch {
            throw RemoteStoreClientError.malformedReply(
                "\(operation.rawValue) reply decode failed: "
                    + String(describing: error))
        }
        if let wireError = storeReply.error {
            let reconstructed = reconstructStoreError(wireError)
            // A stamped mutation whose epoch moved means a daemon restart:
            // clear the cache so the next operation re-handshakes against
            // the fresh daemon (and the next stamp carries its epoch).
            if case .epochMismatch = reconstructed as? RemoteStoreClientError
                ?? .malformedReply("unreachable") {
                handleEpochMismatch()
            }
            throw reconstructed
        }
        guard let result = storeReply.result else {
            throw RemoteStoreClientError.malformedReply(
                "\(operation.rawValue) success reply carried no result")
        }
        return result
    }

    /// Decode one reply DTO's bytes. Internal for the slice-2 family files.
    static func decodeResult<T: Decodable>(
        _ type: T.Type, _ data: Data, _ operation: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteStoreClientError.malformedReply(
                "\(operation) reply result decode failed: "
                    + String(describing: error))
        }
    }

    // MARK: - Error reconstruction (the inverse of the executor's wireError)

    /// Reconstruct the typed error the in-process store would have thrown,
    /// with every associated value intact. The CAS family rebuilds the core
    /// error structs; the transport-level pair and the epoch-mismatch
    /// contract case become ``RemoteStoreClientError`` (typed on the wire —
    /// both ends ship together, so there is no message-parse fallback).
    /// Internal (not static-private) so the reconstruction tests pin every
    /// case's associated values.
    func reconstructStoreError(_ wire: DaemonStoreError) -> Error {
        switch wire {
        case .open(let message):
            return WikiStoreError.open(message)
        case .sqlite(let code, let message):
            return WikiStoreError.sqlite(code: code, message: message)
        case .notFound(let id):
            return WikiStoreError.notFound(PageID(rawValue: id))
        case .chatNotFound(let id):
            return WikiStoreError.chatNotFound(ChatID(rawValue: id))
        case .sourceNotFound(let id):
            return WikiStoreError.sourceNotFound(SourceID(rawValue: id))
        case .sourceVersionNotFound(let id):
            return WikiStoreError.sourceVersionNotFound(
                SourceVersionID(rawValue: id))
        case .sourceMarkdownVersionNotFound(let id):
            return WikiStoreError.sourceMarkdownVersionNotFound(
                SourceMarkdownVersionID(rawValue: id))
        case .noProcessedMarkdown(let id):
            return WikiStoreError.noProcessedMarkdown(SourceID(rawValue: id))
        case .deletionRestricted(let blockers):
            let values = blockers.ordered.map { blocker in
                ProvenanceDeletionBlocker(
                    sourceID: SourceID(rawValue: blocker.sourceID),
                    pageVersionID: PageVersionID(
                        rawValue: blocker.pageVersionID),
                    pageID: PageID(rawValue: blocker.pageID))
            }
            // The daemon never emits an empty blocker set (the typed case
            // only exists when something blocks); a wire violation lands in
            // the unexpected bucket rather than lying with an empty set.
            if let restriction = NonEmptyProvenanceDeletionBlockers(values) {
                return WikiStoreError.deletionRestricted(.provenance(restriction))
            }
            return WikiStoreError.unexpected(
                "deletionRestricted carried no blockers over the wire")
        case .invalidBookmarkRow(let id, let reason):
            return WikiStoreError.invalidBookmarkRow(id: id, reason: reason)
        case .invalidRendererEventID(let raw):
            return WikiStoreError.invalidRendererEventID(raw)
        case .unexpected(let message):
            return WikiStoreError.unexpected(message)
        case .epochMismatch(let expected, let actual):
            // The typed contract case (slice 2): both epochs arrive as
            // associated values — the message parse is gone. The
            // description travels as the message for diagnostics only.
            return RemoteStoreClientError.epochMismatch(
                expectedEpoch: expected, actualEpoch: actual,
                message: wire.errorDescription
                    ?? "daemon epoch mismatch (expected \(expected), "
                        + "actual \(actual))")
        case .duplicateContent(let existing):
            return WikiStoreError.duplicateContent(
                existing: Self.coreSourceSummary(existing))
        case .duplicateURL(let existing):
            return WikiStoreError.duplicateURL(
                existing: Self.coreSourceSummary(existing))
        case .pageConflict(let detail):
            return PageConflictError(
                pageID: PageID(rawValue: detail.pageID),
                expectedVersionID: PageVersionID(
                    rawValue: detail.expectedVersionID),
                actualVersionID: detail.actualVersionID.map {
                    PageVersionID(rawValue: $0)
                })
        case .pageCreateConflict(let detail):
            return PageCreateConflictError(
                pageID: PageID(rawValue: detail.pageID),
                title: detail.title,
                actualVersionID: detail.actualVersionID.map {
                    PageVersionID(rawValue: $0)
                })
        case .pageExpectedTargetMissing(let detail):
            return PageExpectedTargetMissingError(
                pageID: detail.pageID.map { PageID(rawValue: $0) },
                expectedHead: PageVersionID(
                    rawValue: detail.expectedHeadVersionID),
                title: detail.title)
        case .strategyRevisionConflict(let detail):
            // The daemon ships `currentStrategy` as nil today (the executor's
            // mapping), so the reconstruction mirrors exactly what crossed.
            return WikiStrategyConflictError(
                expectedRevision: detail.expectedRevision.map {
                    WikiStrategyRevision(rawValue: $0)
                },
                currentRevision: detail.currentRevision.map {
                    WikiStrategyRevision(rawValue: $0)
                },
                currentStrategy: nil)
        case .sourceMarkdownConflict(let detail):
            return SourceMarkdownConflictError(
                sourceID: SourceID(rawValue: detail.sourceID),
                expectedHead: SourceMarkdownVersionID(
                    rawValue: detail.expectedHead),
                currentHead: detail.currentHead.map {
                    SourceMarkdownVersionID(rawValue: $0)
                })
        case .daemonUnavailable(let message):
            return RemoteStoreClientError.daemonUnavailable(message)
        case .outcomeUnknown(let message):
            return RemoteStoreClientError.outcomeUnknown(message)
        }
    }

    // MARK: - Mutation stamps

    /// The stamp every INITIAL mutation submission carries: a fresh request
    /// ULID + the cached handshake epoch. Reads NEVER call this. Internal
    /// for the slice-2 family files' stamped mutators.
    func mutationStamp() async throws -> DaemonMutationStamp {
        let epoch = try await ensureSession()
        return DaemonMutationStamp(
            requestID: ULID.generate(),
            expectedEpoch: epoch)
    }

    // MARK: - Handshake barrier (readiness + epoch)

    /// Every store operation awaits the acknowledged handshake first: it
    /// caches the daemon epoch (mutators stamp against it), arms the event
    /// watermarks, and replays the client's pre-handshake event buffer.
    /// Concurrent first callers join ONE round trip through the shared
    /// handshake task; the whole barrier races the same per-call deadline.
    ///
    /// After a detected epoch change (``consume``) or an epoch-mismatch
    /// rejection (``handleEpochMismatch``) the cache clears and the next
    /// operation re-handshakes against the restarted daemon.
    ///
    /// Locking discipline: all `stateLock` usage lives in the synchronous
    /// helpers (`beginSessionAttempt`, `abortSessionAttempt`,
    /// `lockedApplyHandshake`) — `NSLock`'s lock/unlock are unavailable from
    /// async contexts, so no async method touches the lock directly.
    /// Internal: every slice-2 family operation awaits this barrier first.
    func ensureSession() async throws -> UInt64 {
        switch beginSessionAttempt() {
        case .have(let epoch):
            return epoch
        case .inFlight(let task):
            do {
                let reply = try await withDeadline("sinkHandshake") {
                    try await task.value
                }
                return try await applyHandshake(reply)
            } catch {
                abortSessionAttempt()
                throw error
            }
        }
    }

    private enum SessionAttempt {
        case have(UInt64)
        case inFlight(Task<DaemonSinkHandshakeReply, Error>)
    }

    /// Synchronous: snapshot the cached epoch, or join/adopt the single
    /// in-flight handshake task (creating it when none exists).
    private func beginSessionAttempt() -> SessionAttempt {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let epoch = state.epoch {
            return .have(epoch)
        }
        if let task = state.handshakeTask {
            return .inFlight(task)
        }
        state.phase = .awaiting
        let transport = self.transport
        let registrationID = state.sinkRegistrationID
        let deadline = callDeadline
        let task = Task<DaemonSinkHandshakeReply, Error> { @Sendable in
            try await RemoteWikiStore.performHandshake(
                transport: transport,
                sinkRegistrationID: registrationID,
                deadline: deadline)
        }
        state.handshakeTask = task
        return .inFlight(task)
    }

    /// Synchronous: release a failed barrier so joiners retry on the next
    /// operation instead of caching a poisoned task forever.
    private func abortSessionAttempt() {
        stateLock.lock()
        state.phase = .idle
        state.handshakeTask = nil
        stateLock.unlock()
    }

    /// One acknowledged handshake round trip (never dispatches a store op):
    /// the reply carries the epoch + one watermark per prepared wiki.
    private static func performHandshake(
        transport: any RemoteWikiStoreTransport,
        sinkRegistrationID: UUID?,
        deadline: TimeInterval
    ) async throws -> DaemonSinkHandshakeReply {
        let storeRequest = DaemonStoreRequest(
            wikiID: "",
            operation: DaemonStoreOperation.sinkHandshake.rawValue,
            payload: try JSONEncoder().encode(DaemonSinkHandshakeRequest()))
        let domainRequest = DaemonDomainRequest(
            requestID: UUID().uuidString,
            family: .store,
            operation: storeRequest.operation,
            payload: try DaemonStoreWire.encode(storeRequest))
        let reply = try await raceDeadline(deadline, operation: "sinkHandshake") {
            try await transport.send(
                domainRequest, sinkRegistrationID: sinkRegistrationID)
        }
        if let domainError = reply.error {
            throw RemoteStoreClientError.daemonUnavailable(
                "domain rejection \(domainError.code.rawValue): "
                    + domainError.message)
        }
        guard let payload = reply.payload else {
            throw RemoteStoreClientError.malformedReply(
                "sinkHandshake reply carried no payload")
        }
        let storeReply = try DaemonStoreWire.decodeReply(payload)
        if let wireError = storeReply.error {
            // The handshake itself never produces store-level CAS errors;
            // surface the typed text.
            throw RemoteStoreClientError.daemonUnavailable(
                wireError.errorDescription ?? String(describing: wireError))
        }
        guard let result = storeReply.result else {
            throw RemoteStoreClientError.malformedReply(
                "sinkHandshake success reply carried no result")
        }
        return try decodeResult(
            DaemonSinkHandshakeReply.self, result, "sinkHandshake")
    }

    /// Deadline race for closures that already capture what they need (the
    /// static handshake path; same mechanics as ``withDeadline``).
    private static func raceDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw RemoteStoreClientError.deadlineExceeded(
                    operation: operation, seconds: seconds)
            }
            guard let first = try await group.next() else {
                throw RemoteStoreClientError.malformedReply(
                    "deadline race produced no result")
            }
            group.cancelAll()
            return first
        }
    }

    /// Apply one handshake reply: cache the epoch, arm the per-wiki
    /// watermarks (locked section), detect token advances (ONE reload
    /// signal), then flush the pre-handshake buffer through the dedupe path.
    private func applyHandshake(
        _ reply: DaemonSinkHandshakeReply
    ) async throws -> UInt64 {
        let (tokenAdvanced, buffered) = lockedApplyHandshake(reply)

        // The daemon replays its ring to live sinks AFTER the reply with
        // `sequence > lastSequence`, so the watermark-armed dedupe accepts
        // exactly the replay.
        for event in buffered {
            consume(event)
        }
        if tokenAdvanced {
            fireReloadSignalOnce()
        }
        return reply.daemonEpoch
    }

    /// Synchronous: the locked half of ``applyHandshake``.
    private func lockedApplyHandshake(
        _ reply: DaemonSinkHandshakeReply
    ) -> (tokenAdvanced: Bool, buffered: [DaemonStoreEvent]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        state.epoch = reply.daemonEpoch
        state.phase = .live
        state.handshakeTask = nil
        var tokenAdvanced = false
        for watermark in reply.perWiki {
            if let cached = state.changeTokens[watermark.wikiID],
               cached != watermark.changeToken {
                tokenAdvanced = true
            }
            state.changeTokens[watermark.wikiID] = watermark.changeToken
            state.watermarks[watermark.wikiID] = watermark.lastSequence
        }
        let buffered = state.preHandshake
        state.preHandshake = []
        return (tokenAdvanced, buffered)
    }

    /// Clear the cached epoch after a detected restart so the next operation
    /// re-handshakes (and the next stamp carries the NEW epoch).
    private func handleEpochMismatch() {
        stateLock.lock()
        state.epoch = nil
        state.phase = .idle
        state.handshakeTask = nil
        stateLock.unlock()
    }

    /// Coalesce every staleness detection in this epoch lifecycle into ONE
    /// reload signal for the session wiring.
    private func fireReloadSignalOnce() {
        stateLock.lock()
        if reloadSignalFired {
            stateLock.unlock()
            return
        }
        reloadSignalFired = true
        let hook = onReloadSignal
        stateLock.unlock()
        hook?()
    }

    /// Reset the one-signal coalescing at a NEW epoch (a fresh daemon is a
    /// fresh staleness story; the wiring legitimately needs one more reload).
    private func armReloadSignalForNewEpoch() {
        stateLock.lock()
        reloadSignalFired = false
        stateLock.unlock()
    }

    // MARK: - Event feed (WikiDaemonEventSink)

    /// The session wiring registers THIS store as the connection's event
    /// sink (`daemon.registerEventSink(store)`) and threads the returned
    /// registration id here, so the handshake correlates with the exporter's
    /// sink table exactly as `WikiDaemon.storeOperation` expects. Safe to
    /// call before or after the first store operation.
    public func registerSink(registrationID: UUID) {
        stateLock.lock()
        state.sinkRegistrationID = registrationID
        stateLock.unlock()
    }

    /// Explicit readiness barrier — the same handshake `ensureSession` runs
    /// lazily. Exposed so the session wiring can force the barrier at open
    /// instead of waiting for the first operation.
    public func warmSession() async throws {
        _ = try await ensureSession()
    }

    /// The cached daemon epoch, or nil before the first handshake completes.
    /// Diagnostics + session wiring introspection; mutation stamping reads
    /// the same value through ``ensureSession``.
    public func sessionEpoch() -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.epoch
    }

    /// One pushed firehose payload. Queue/chat workload envelopes fail the
    /// store-envelope decode and are ignored here (the workload sink in the
    /// app layer consumes those); only `wikid.store-event.v1` payloads flow.
    public func deliverEvent(_ payload: Data) {
        // The decode MISS is the two-way discrimination contract (the
        // envelope grammar is deliberately disjoint from `QueueEventEnvelope`
        // — see DaemonStoreEventsWire.swift): a non-store payload is a
        // no-op, not an error to surface.
        // swiftlint:disable:next silent_try_optional
        guard let envelope = try? JSONDecoder().decode(
            DaemonStoreEventEnvelope.self, from: payload),
            envelope.wire == DaemonStoreEventWire.marker
        else {
            return
        }
        consume(envelope.event)
    }

    /// The client-side store-event flow (plan 2c):
    /// epoch change → new epoch, never dedupe across; drop
    /// `sequence <=` the epoch's watermark; gap or token advance → ONE
    /// reload signal; then feed the batch into the bus + cache the token.
    /// Compute under the lock, emit after it (the bus takes its own lock).
    private func consume(_ event: DaemonStoreEvent) {
        var emissions: [ResourceChangeEvent] = []
        var fireReload = false

        stateLock.lock()
        // The readiness race: the daemon flips the sink live (replaying its
        // ring) the moment its handshake completes, while THIS client's
        // handshake reply can still be in flight — deliveries that arrive
        // before `phase == .live` buffer here (bounded; overflow drops the
        // oldest and the handshake token reconciles with ONE reload).
        if state.phase != .live {
            state.preHandshake.append(event)
            if state.preHandshake.count > Self.preHandshakeBufferLimit {
                state.preHandshake.removeFirst(
                    state.preHandshake.count - Self.preHandshakeBufferLimit)
            }
            stateLock.unlock()
            return
        }

        // Epoch adoption/change: the FIRST event (or handshake) arms the
        // watermark epoch; a DIFFERENT epoch is a daemon restart — reset
        // watermarks, re-cache the epoch (stamps now target the fresh
        // daemon), and signal one reconciliation reload. Never dedupe
        // across epochs.
        if state.watermarkEpoch != event.epoch {
            let wasArmed = state.watermarkEpoch != nil
            state.watermarkEpoch = event.epoch
            state.watermarks = [:]
            if wasArmed || state.epoch == nil {
                state.epoch = event.epoch
            }
            fireReload = wasArmed
            // Re-arm the coalescing window: the new epoch earns ONE signal
            // of its own.
            reloadSignalFired = false
        }

        guard event.wikiID == wikiID.rawValue else {
            // Another wiki's commit: still watermark it (the sink is
            // daemon-scoped and the client hosts one wiki) so the tokens
            // stay fresh for the wiring, but emit nothing into THIS wiki's
            // bus. The bus is per-wiki, so cross-wiki events must not land.
            state.watermarks[event.wikiID] = max(
                state.watermarks[event.wikiID] ?? 0, event.sequence)
            state.changeTokens[event.wikiID] = event.changeToken
            stateLock.unlock()
            if fireReload { fireReloadSignalOnce() }
            return
        }

        let watermark = state.watermarks[event.wikiID] ?? 0
        if event.sequence <= watermark {
            // Idempotent duplicate (replay overlap, double delivery).
            stateLock.unlock()
            if fireReload { fireReloadSignalOnce() }
            return
        }
        if event.sequence > watermark + 1 {
            // Sequence gap: bounded-buffer drop or missed delivery — the
            // change token reconciles it with ONE reload.
            fireReload = true
        }
        state.watermarks[event.wikiID] = event.sequence
        state.changeTokens[event.wikiID] = event.changeToken

        emissions = event.batch.map { mirror in
            ResourceChangeEvent(
                wikiID: WikiID(rawValue: event.wikiID),
                kind: mirror.kind.flatMap(ResourceKind.init(rawValue:)),
                id: mirror.id,
                change: ChangeKind(rawValue: mirror.change) ?? .updated,
                seq: mirror.seq)
        }
        stateLock.unlock()

        if fireReload { fireReloadSignalOnce() }
        let bus = eventBus
        for change in emissions {
            bus?.emit(change)
        }
    }

    // MARK: - Staged payload helpers (infrastructure, not WikiStore ops)

    /// Upload bytes through the staged-payload flow (begin → ordered,
    /// hash-checked chunks → commit) and return the committed handle the
    /// consuming operation references. Chunking honors
    /// ``DaemonStoreLimits/maxChunkBytes``; the executor verifies every
    /// running hash, so a partial upload can never commit. Internal for the
    /// slice-2 blob family.
    func stageUpload(_ bytes: Data) async throws -> DaemonPayloadHandle {
        let sha = Self.sha256Hex(bytes)
        let begin = try await sendStore(
            .payloadBegin,
            payload: JSONEncoder().encode(DaemonPayloadBeginRequest(
                declaredByteCount: bytes.count,
                sha256Hex: sha)))
        let beginReply = try Self.decodeResult(
            DaemonPayloadBeginReply.self, begin, "payloadBegin")

        let chunkLimit = DaemonStoreLimits.maxChunkBytes
        var offset = 0
        var orderIndex = 0
        var sent = Data()
        while offset < bytes.count {
            let end = min(offset + chunkLimit, bytes.count)
            let chunk = bytes.subdata(in: offset..<end)
            sent.append(chunk)
            _ = try await sendStore(
                .payloadChunk,
                payload: JSONEncoder().encode(DaemonPayloadChunkRequest(
                    uploadID: beginReply.uploadID,
                    orderIndex: orderIndex,
                    bytes: chunk,
                    runningSHA256Hex: Self.sha256Hex(sent))))
            offset = end
            orderIndex += 1
        }
        // An EMPTY upload still commits: the begin declaration (0 bytes) is
        // verified without any chunk.
        let commit = try await sendStore(
            .payloadCommit,
            payload: JSONEncoder().encode(DaemonPayloadCommitRequest(
                uploadID: beginReply.uploadID)))
        let commitReply = try Self.decodeResult(
            DaemonPayloadCommitReply.self, commit, "payloadCommit")
        return commitReply.handle
    }

    /// Download a committed handle's bytes one ordered chunk at a time and
    /// verify the reassembly against the handle's SHA-256 + declared size
    /// (the integrity contract). Used by `getPage`'s body download and every
    /// slice-2 blob read. Internal for the slice-2 family files.
    func readHandle(_ handle: DaemonPayloadHandle) async throws -> Data {
        var assembled = Data()
        var chunkIndex = 0
        while true {
            let chunkData = try await sendStore(
                .payloadRead,
                payload: JSONEncoder().encode(DaemonPayloadReadRequest(
                    handleID: handle.id, chunkIndex: chunkIndex)))
            let reply = try Self.decodeResult(
                DaemonPayloadReadReply.self, chunkData, "payloadRead")
            assembled.append(reply.bytes)
            if reply.isFinal { break }
            chunkIndex += 1
        }
        guard assembled.count == handle.declaredByteCount,
              Self.sha256Hex(assembled) == handle.sha256Hex else {
            throw RemoteStoreClientError.malformedReply(
                "payloadRead reassembly failed the handle integrity check "
                    + "(\(assembled.count) bytes, expected "
                    + "\(handle.declaredByteCount))")
        }
        return assembled
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Stamped-mutator outcome guard (slice-2 family files)

    /// Every stamped mutator's reply echoes the mutation outcome. Only a
    /// committed or joined echo resolves the call; anything else means the
    /// outcome is UNKNOWN — reconcile through change tokens, never
    /// blind-retry. Shared by the slice-2 family files so the guard is one
    /// function.
    static func requireCommittedOutcome(
        _ outcome: DaemonMutationOutcome, _ operation: String
    ) throws {
        guard outcome.status == .committed || outcome.status == .joined else {
            throw RemoteStoreClientError.outcomeUnknown(
                "\(operation) echoed \(outcome.status.rawValue)")
        }
    }

    // MARK: - Value mapping (client-side inverse of the daemon's mirrors)

    /// Internal: the slice-2 family files share the small-family mappers.
    static func coreSourceSummary(
        _ value: DaemonSourceSummary
    ) -> SourceSummary {
        SourceSummary(
            id: SourceID(rawValue: value.id),
            filename: value.filename,
            ext: value.ext,
            mimeType: value.mimeType,
            byteSize: value.byteSize,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt,
            version: value.version,
            externalItemKey: value.externalItemKey,
            externalItemTitle: value.externalItemTitle,
            displayName: value.displayName,
            role: SourceRole(rawValue: value.role) ?? .primary)
    }

    /// Internal: the slice-2 family files share the small-family mappers.
    static func corePageSummary(
        _ value: DaemonPageSummary
    ) -> WikiPageSummary {
        WikiPageSummary(
            id: PageID(rawValue: value.id),
            title: value.title,
            updatedAt: value.updatedAt,
            createdAt: value.createdAt)
    }

    /// Internal: the slice-2 family files share the small-family mappers.
    static func coreChatSummary(
        _ value: DaemonChatSummary
    ) -> ChatSummary {
        ChatSummary(
            id: ChatID(rawValue: value.id),
            kind: ChatKind(rawValue: value.kind.rawValue) ?? .edit,
            title: value.title,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt,
            messageCount: value.messageCount,
            acpSessionId: value.acpSessionId.map(AcpSessionID.init(rawValue:)),
            modelProviderId: value.modelProviderId.map(ProviderID.init(rawValue:)),
            modelId: value.modelId.map(ModelID.init(rawValue:)),
            configuredThinkingOptionID: value.configuredThinkingOptionID
                .map(ChatConfigurationValueID.init(rawValue:)),
            effectiveThinkingOptionID: value.effectiveThinkingOptionID
                .map(ChatConfigurationValueID.init(rawValue:)))
    }

    private static func coreDeletionTarget(
        _ value: DaemonResourceDeletionTarget
    ) -> ResourceDeletionTarget {
        switch value {
        case .page(let id):
            return .page(PageID(rawValue: id))
        case .source(let id):
            return .source(SourceID(rawValue: id))
        }
    }

    private static func wireDeletionTarget(
        _ value: ResourceDeletionTarget
    ) -> DaemonResourceDeletionTarget {
        switch value {
        case .page(let id):
            return .page(id: id.rawValue)
        case .source(let id):
            return .source(id: id.rawValue)
        }
    }

    private static func wireLinkPolicy(
        _ value: ResourceDeletionLinkPolicy
    ) -> DaemonResourceDeletionLinkPolicy {
        switch value {
        case .preserve: return .preserve
        case .unlink: return .unlink
        }
    }

    private static func coreProvenanceBlocker(
        _ value: DaemonProvenanceDeletionBlocker
    ) -> ProvenanceDeletionBlocker {
        ProvenanceDeletionBlocker(
            sourceID: SourceID(rawValue: value.sourceID),
            pageVersionID: PageVersionID(rawValue: value.pageVersionID),
            pageID: PageID(rawValue: value.pageID))
    }

    private static func coreHints(
        _ value: DaemonContentTypeDetectionHints
    ) -> ContentTypeDetectionHints {
        ContentTypeDetectionHints(
            declaredMIME: value.declaredMIME.map {
                DeclaredMIME($0.value, origin: DeclaredMIMEOrigin(
                    rawValue: $0.origin.rawValue) ?? .localUTI)
            },
            filenameExtension: value.filenameExtension,
            utiMIME: value.utiMIME)
    }

    /// Internal: the slice-2 blob family shares the detection-hints mapper.
    static func wireHints(
        _ value: ContentTypeDetectionHints
    ) -> DaemonContentTypeDetectionHints {
        DaemonContentTypeDetectionHints(
            declaredMIME: value.declaredMIME.map {
                DaemonDeclaredMIME(
                    value: $0.value,
                    origin: DaemonDeclaredMIMEOrigin(
                        rawValue: $0.origin.rawValue) ?? .localUTI)
            },
            filenameExtension: value.filenameExtension,
            utiMIME: value.utiMIME)
    }

    private static func coreIngestMetadata(
        _ value: DaemonSourceIngestMetadata
    ) -> SourceIngestMetadata {
        SourceIngestMetadata(
            externalItemID: value.externalItemID,
            externalItemTitle: value.externalItemTitle)
    }

    private static func wireIngestMetadata(
        _ value: SourceIngestMetadata?
    ) -> DaemonSourceIngestMetadata? {
        guard let value else { return nil }
        return DaemonSourceIngestMetadata(
            externalItemID: value.externalItemID,
            externalItemTitle: value.externalItemTitle)
    }

    private static func coreProvenance(
        _ value: DaemonSourceProvenance
    ) -> SourceProvenance {
        SourceProvenance(
            agentName: value.agentName,
            agentKind: value.agentKind,
            agentVersion: value.agentVersion,
            activityKind: value.activityKind,
            plan: value.plan,
            externalRef: value.externalRef,
            externalIdentity: value.externalIdentity)
    }

    /// Internal: the slice-2 family files share the provenance mapper.
    static func wireProvenance(
        _ value: SourceProvenance?
    ) -> DaemonSourceProvenance? {
        guard let value else { return nil }
        return DaemonSourceProvenance(
            agentName: value.agentName,
            agentKind: value.agentKind,
            agentVersion: value.agentVersion,
            activityKind: value.activityKind,
            plan: value.plan,
            externalRef: value.externalRef,
            externalIdentity: value.externalIdentity)
    }

    // MARK: - List continuation (the `pageToken` payload key)

    /// Merge the cursor's opaque `pageToken` into the op DTO as an extra
    /// `pageToken` JSON key inside the SAME payload object (the executor
    /// probes the key without touching any DTO shape — see its
    /// `ListContinuationKey`). Internal for the slice-2 list family.
    static func payloadWithPageToken(
        _ dto: Data, pageToken: String?
    ) throws -> Data {
        guard let pageToken else { return dto }
        guard var object = try JSONSerialization.jsonObject(
            with: dto) as? [String: Any] else {
            throw RemoteStoreClientError.malformedReply(
                "list request payload is not a JSON object")
        }
        object["pageToken"] = pageToken
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Bootstrap payload stub (slice 2e seam)

    /// Apply the 2e `sessionBootstrap` payload. Stub surface in this slice:
    /// the extraction-input mirror maps fully (kind raw string + MIME set +
    /// extension set + cleanup claim); the change token anchors
    /// reconciliation; renderer claims need the descriptor catalog, so the
    /// session wiring composes `registeredRendererSourceTypes` itself.
    public func applyBootstrap(_ bootstrap: DaemonStoreSessionBootstrap) {
        let claims: Set<RegisteredExtractionInputs.Claim> = Set(
            bootstrap.registeredExtractionInputs.claims.compactMap { claim in
                guard let kind = ExtractorKind(rawValue: claim.kind) else {
                    return nil
                }
                return RegisteredExtractionInputs.Claim(
                    kind: kind,
                    mimeTypes: claim.mimeTypes,
                    filenameExtensions: claim.filenameExtensions,
                    wantsAgentCleanup: claim.wantsAgentCleanup)
            })
        registeredExtractionInputs = RegisteredExtractionInputs(claims: claims)
        stateLock.lock()
        if state.changeTokens[wikiID.rawValue] != bootstrap.changeToken {
            state.changeTokens[wikiID.rawValue] = bootstrap.changeToken
        }
        stateLock.unlock()
    }

    // MARK: - Wired: small family (reads unstamped; setMetadata stamped)

    public func resolveTitleToID(_ title: String) async throws -> PageID? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .resolveTitleToID,
            payload: JSONEncoder().encode(
                DaemonResolveTitleToIDRequest(title: title)))
        let reply = try Self.decodeResult(
            DaemonResolveTitleToIDReply.self, result, "resolveTitleToID")
        return reply.pageID.map { PageID(rawValue: $0) }
    }

    public func hasProcessedMarkdown(sourceID: SourceID) async throws -> Bool {
        _ = try await ensureSession()
        let result = try await sendStore(
            .hasProcessedMarkdown,
            payload: JSONEncoder().encode(
                DaemonHasProcessedMarkdownRequest(sourceID: sourceID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonHasProcessedMarkdownReply.self, result, "hasProcessedMarkdown")
        return reply.hasAny
    }

    public func getMetadata(_ key: String) async throws -> String? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .getMetadata,
            payload: JSONEncoder().encode(DaemonGetMetadataRequest(key: key)))
        let reply = try Self.decodeResult(
            DaemonGetMetadataReply.self, result, "getMetadata")
        return reply.value
    }

    public func pageHeadVersionID(pageID: PageID) async throws -> PageVersionID? {
        _ = try await ensureSession()
        let result = try await sendStore(
            .pageHeadVersionID,
            payload: JSONEncoder().encode(
                DaemonPageHeadVersionIDRequest(pageID: pageID.rawValue)))
        let reply = try Self.decodeResult(
            DaemonPageHeadVersionIDReply.self, result, "pageHeadVersionID")
        return reply.versionID.map { PageVersionID(rawValue: $0) }
    }

    /// The family's stamped no-emit mutator: the reply echoes the mutation
    /// outcome (exactly-once observable on the reply itself) and never
    /// emits a store event.
    public func setMetadata(_ key: String, value: String) async throws {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .setMetadata,
            payload: JSONEncoder().encode(
                DaemonSetMetadataRequest(key: key, value: value)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonSetMetadataReply.self, result, "setMetadata")
        guard reply.outcome.status == .committed || reply.outcome.status == .joined
        else {
            throw RemoteStoreClientError.outcomeUnknown(
                "setMetadata echoed \(reply.outcome.status.rawValue)")
        }
    }

    // MARK: - Wired: list family (cursor-continuation walks; never stamped)

    public func listPages(sortBy: PageSortOrder) async throws -> [WikiPageSummary] {
        _ = try await ensureSession()
        let order = DaemonPageSortOrder(rawValue: sortBy.rawValue) ?? .lastUpdated
        var token: String?
        var pages: [WikiPageSummary] = []
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonListPagesRequest(sortBy: order))
            let result = try await sendStore(
                .listPages,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonListPagesReply.self, result, "listPages")
            pages += reply.pages.map(Self.corePageSummary)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return pages
    }

    public func listChats() async throws -> [ChatSummary] {
        _ = try await ensureSession()
        var token: String?
        var chats: [ChatSummary] = []
        repeat {
            let dto = try JSONEncoder().encode(DaemonListChatsRequest())
            let result = try await sendStore(
                .listChats,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonListChatsReply.self, result, "listChats")
            chats += reply.chats.map(Self.coreChatSummary)
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        return chats
    }

    public func deletionImpact(
        for targets: Set<ResourceDeletionTarget>
    ) async throws -> DeletionImpact {
        _ = try await ensureSession()
        let orderedTargets = ResourceDeletionTarget.sorted(targets)
            .map(Self.wireDeletionTarget)
        var token: String?
        var impact: DaemonDeletionImpact?
        repeat {
            let dto = try JSONEncoder().encode(
                DaemonDeletionImpactRequest(targets: orderedTargets))
            let result = try await sendStore(
                .deletionImpact,
                payload: try Self.payloadWithPageToken(dto, pageToken: token))
            let reply = try Self.decodeResult(
                DaemonDeletionImpactReply.self, result, "deletionImpact")
            impact = reply.impact
            token = reply.cursor.nextAvailable ? reply.cursor.pageToken : nil
        } while token != nil
        // A deletion impact is ONE deterministic snapshot; multiple pages
        // would mean the snapshot itself is a list, which it is not — the
        // loop exists only to honor the family's uniform cursor shape.
        guard let impact else {
            throw RemoteStoreClientError.malformedReply(
                "deletionImpact reply carried no impact snapshot")
        }
        return DeletionImpact(
            linkingPages: impact.linkingPages.map {
                DeletionLinkingPage(
                    pageID: PageID(rawValue: $0.pageID), title: $0.title)
            },
            bookmarks: impact.bookmarks.map {
                DeletionBookmarkImpact(
                    nodeID: BookmarkID(rawValue: $0.nodeID),
                    folderPath: $0.folderPath)
            },
            provenanceBlockers: impact.provenanceBlockers
                .map(Self.coreProvenanceBlocker),
            incomingLinkCount: impact.incomingLinkCount)
    }

    // MARK: - Wired: blob family

    /// Download-via-handle read: the metadata crosses inline and the body
    /// reassembles through `payloadRead` chunks with the SHA-256 check.
    public func getPage(id: PageID) async throws -> WikiPage {
        _ = try await ensureSession()
        let result = try await sendStore(
            .getPage,
            payload: JSONEncoder().encode(DaemonGetPageRequest(id: id.rawValue)))
        let reply = try Self.decodeResult(
            DaemonGetPageReply.self, result, "getPage")
        let body = try await readHandle(reply.body)
        guard let markdown = String(data: body, encoding: .utf8) else {
            throw RemoteStoreClientError.malformedReply(
                "getPage body was not UTF-8")
        }
        return WikiPage(
            id: PageID(rawValue: reply.page.id),
            title: reply.page.title,
            slug: reply.page.slug,
            bodyMarkdown: markdown,
            createdAt: reply.page.createdAt,
            updatedAt: reply.page.updatedAt,
            version: reply.page.version,
            createdBy: reply.page.createdBy,
            lastEditedBy: reply.page.lastEditedBy)
    }

    /// COMPOSED ATOMIC — direct implementation (never the protocol
    /// extension's sequential default). The raw body stages through the
    /// payload-handle flow (nil handle = empty body), the write executes
    /// under the daemon's one-transaction `upsertPage`, and the reply
    /// echoes the mutation outcome + the committed event (observability
    /// only: the authoritative bus delivery arrives through the sink).
    @discardableResult
    public func upsertPage(
        id: PageID?,
        title: String,
        rawBody: String,
        expectation: PageWriteExpectation,
        author: String?,
        provenance: [PageVersionSourceInput]
    ) async throws -> PageUpsert.Outcome {
        _ = try await ensureSession()
        let bodyBytes = Data(rawBody.utf8)
        let handle = bodyBytes.isEmpty ? nil : try await stageUpload(bodyBytes)
        let wireExpectation: DaemonPageWriteExpectation
        switch expectation {
        case .unrestricted:
            wireExpectation = .unrestricted
        case .expectedHead(let versionID):
            wireExpectation = .expectedHead(versionID: versionID.rawValue)
        case .expectedAbsence:
            wireExpectation = .expectedAbsence
        }
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .upsertPage,
            payload: JSONEncoder().encode(DaemonUpsertPageRequest(
                pageID: id?.rawValue,
                title: title,
                rawBody: handle,
                expectation: wireExpectation,
                author: author,
                provenance: provenance.map {
                    DaemonPageVersionSourceInput(
                        sourceID: $0.sourceID.rawValue,
                        role: DaemonPageVersionSourceRole(
                            rawValue: $0.role.rawValue) ?? .primary)
                })),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonUpsertPageReply.self, result, "upsertPage")
        guard reply.outcome.status == .committed || reply.outcome.status == .joined
        else {
            throw RemoteStoreClientError.outcomeUnknown(
                "upsertPage echoed \(reply.outcome.status.rawValue)")
        }
        return PageUpsert.Outcome(
            id: PageID(rawValue: reply.result.id),
            didCreate: reply.result.didCreate)
    }

    /// COMPOSED ATOMIC — the full ingestion overload, direct (the 2-arg
    /// convenience below forwards here). Source bytes stage through the
    /// payload-handle flow; the daemon materializes + dedupes + writes in
    /// one store entry point.
    @discardableResult
    public func addSource(
        filename: String,
        data: Data,
        detectionHints: ContentTypeDetectionHints,
        ingestMetadata: SourceIngestMetadata?,
        provenance: SourceProvenance?,
        role: SourceRole,
        originalPath: String?,
        activityID: String?,
        resolvedDisplayName: String??
    ) async throws -> SourceSummary {
        _ = try await ensureSession()
        let handle = try await stageUpload(data)
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .addSource,
            payload: JSONEncoder().encode(DaemonAddSourceRequest(
                filename: filename,
                data: handle,
                detectionHints: Self.wireHints(detectionHints),
                ingestMetadata: Self.wireIngestMetadata(ingestMetadata),
                provenance: Self.wireProvenance(provenance),
                role: DaemonSourceRole(rawValue: role.rawValue) ?? .primary,
                originalPath: originalPath,
                activityID: activityID,
                // The wire carries String?; the store's String?? distinguishes
                // "not provided" from "explicitly nil". Today the executor
                // maps the wire value to `.some(…)` either way, so both
                // spellings collapse to the inner value.
                resolvedDisplayName: resolvedDisplayName ?? nil)),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonAddSourceReply.self, result, "addSource")
        guard reply.outcome.status == .committed || reply.outcome.status == .joined
        else {
            throw RemoteStoreClientError.outcomeUnknown(
                "addSource echoed \(reply.outcome.status.rawValue)")
        }
        return Self.coreSourceSummary(reply.source)
    }

    /// The 1-arg forwarder the protocol documents (`createdBy`-omitting
    /// callers); the composed write runs in the full overload.
    @discardableResult
    public func addSource(
        filename: String, data: Data
    ) async throws -> SourceSummary {
        try await addSource(
            filename: filename,
            data: data,
            detectionHints: ContentTypeDetectionHints(),
            ingestMetadata: nil,
            provenance: nil,
            role: .primary,
            originalPath: nil,
            activityID: nil,
            resolvedDisplayName: nil)
    }

    // MARK: - Wired: event-producer family

    public func createChat(
        kind: ChatKind, title: String
    ) async throws -> ChatSummary {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .createChat,
            payload: JSONEncoder().encode(DaemonCreateChatRequest(
                kind: DaemonChatKind(rawValue: kind.rawValue) ?? .edit,
                title: title,
                modelProviderId: nil,
                modelId: nil,
                configuredThinkingOptionID: nil,
                effectiveThinkingOptionID: nil,
                attachments: [])),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCreateChatReply.self, result, "createChat")
        guard reply.outcome.status == .committed || reply.outcome.status == .joined
        else {
            throw RemoteStoreClientError.outcomeUnknown(
                "createChat echoed \(reply.outcome.status.rawValue)")
        }
        return Self.coreChatSummary(reply.chat)
    }

    /// The model-selection overload — same wire op, the DTO carries all
    /// three overloads losslessly (empty attachments).
    public func createChat(
        kind: ChatKind,
        title: String,
        modelProviderId: ProviderID?,
        modelId: ModelID?,
        configuredThinkingOptionID: ChatConfigurationValueID?,
        effectiveThinkingOptionID: ChatConfigurationValueID?
    ) async throws -> ChatSummary {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .createChat,
            payload: JSONEncoder().encode(DaemonCreateChatRequest(
                kind: DaemonChatKind(rawValue: kind.rawValue) ?? .edit,
                title: title,
                modelProviderId: modelProviderId?.rawValue,
                modelId: modelId?.rawValue,
                configuredThinkingOptionID: configuredThinkingOptionID?.rawValue,
                effectiveThinkingOptionID: effectiveThinkingOptionID?.rawValue,
                attachments: [])),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCreateChatReply.self, result, "createChat")
        guard reply.outcome.status == .committed || reply.outcome.status == .joined
        else {
            throw RemoteStoreClientError.outcomeUnknown(
                "createChat echoed \(reply.outcome.status.rawValue)")
        }
        return Self.coreChatSummary(reply.chat)
    }

    /// The attachments overload — ordered chips compose in the same
    /// one-transaction write (empty model fields).
    public func createChat(
        kind: ChatKind,
        title: String,
        attachments: [ChatAttachmentTarget]
    ) async throws -> ChatSummary {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .createChat,
            payload: JSONEncoder().encode(DaemonCreateChatRequest(
                kind: DaemonChatKind(rawValue: kind.rawValue) ?? .edit,
                title: title,
                modelProviderId: nil,
                modelId: nil,
                configuredThinkingOptionID: nil,
                effectiveThinkingOptionID: nil,
                attachments: attachments.map(Self.wireAttachmentTarget))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonCreateChatReply.self, result, "createChat")
        guard reply.outcome.status == .committed || reply.outcome.status == .joined
        else {
            throw RemoteStoreClientError.outcomeUnknown(
                "createChat echoed \(reply.outcome.status.rawValue)")
        }
        return Self.coreChatSummary(reply.chat)
    }

    /// Internal: the slice-2 event-producer family shares the attachment
    /// mapper (the core file's createChat overloads use it too).
    static func wireAttachmentTarget(
        _ value: ChatAttachmentTarget
    ) -> DaemonChatAttachmentTarget {
        switch value {
        case .page(let id): return .page(id: id.rawValue)
        case .source(let id): return .source(id: id.rawValue)
        case .chat(let id): return .chat(id: id.rawValue)
        }
    }

    /// COMPOSED ATOMIC — the single protected-deletion seam, direct.
    /// Impact recheck, provenance gate, optional link rewrites, bookmark
    /// cleanup, and target deletion run in ONE daemon transaction; the
    /// reply carries the post-commit result + the event batch (echo; the
    /// authoritative bus delivery arrives through the sink).
    @discardableResult
    public func deleteResources(
        _ request: ResourceDeletionRequest
    ) async throws -> ResourceDeletionResult {
        _ = try await ensureSession()
        let stamp = try await mutationStamp()
        let result = try await sendStore(
            .deleteResources,
            payload: JSONEncoder().encode(DaemonDeleteResourcesRequest(
                request: DaemonResourceDeletionRequest(
                    targets: ResourceDeletionTarget.sorted(request.targets)
                        .map(Self.wireDeletionTarget),
                    linkPolicy: Self.wireLinkPolicy(request.linkPolicy)))),
            stamp: stamp)
        let reply = try Self.decodeResult(
            DaemonDeleteResourcesReply.self, result, "deleteResources")
        guard reply.outcome.status == .committed || reply.outcome.status == .joined
        else {
            throw RemoteStoreClientError.outcomeUnknown(
                "deleteResources echoed \(reply.outcome.status.rawValue)")
        }
        return ResourceDeletionResult(
            deletedTargets: reply.result.deletedTargets
                .map(Self.coreDeletionTarget),
            rewrittenPageIDs: reply.result.rewrittenPageIDs
                .map { PageID(rawValue: $0) },
            removedBookmarkIDs: reply.result.removedBookmarkIDs
                .map { BookmarkID(rawValue: $0) },
            incomingLinkCount: reply.result.incomingLinkCount)
    }
}
#endif
