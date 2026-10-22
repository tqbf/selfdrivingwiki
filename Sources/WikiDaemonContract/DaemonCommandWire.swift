#if os(macOS)
import Foundation

// Phase 3 of plans/cli-domain-commands.md: the read-only command families
// (`page`, `source`, `chat`, `bookmark`, `workspace`) plus the two extensions
// that complete store-freedom (`queue`/`queueWikiItems` for `job list/get`,
// `search`/`resolvedSearch` for the three CLI search commands).
//
// Unlike the queue and wiki families — whose payloads are established wire
// values that ride the envelope unchanged — these payloads are NEW. The shape
// follows one principle: the daemon EXECUTES the CLI's existing command layer
// (`PageCommand.run` and friends) against its prepared services and answers
// with a uniform ``DaemonCommandOutcome``. The same code that produced a
// command's stdout in-process produces it on the daemon, so the byte-stable
// scripting formats cannot drift. Domain types the contract target cannot see
// (WikiFSCore's OKF structs, QueueItem) cross as embedded JSON bytes, exactly
// like the wiki family's descriptor bytes.
//
// Every request struct carries `wikiID` (the resolved wiki ULID). The daemon
// resolves it against the registry BEFORE any store open; an unknown wiki is a
// typed `notFound` with the message `no wiki matching <selector>`.
//
// Frame cap: a command whose encoded reply would exceed the socket's 4 MiB
// frame cap (`SearchSocketWire.maxFrameSize` — reachable for `page get` on a
// huge page and `source cat` of a large source) fails with a typed
// `operationFailed` naming the cap. Replies are never truncated; chunked
// replies are out of scope (see the plan's §"Long-running operations").

/// The uniform reply payload for every Phase 3 command family: what the CLI
/// prints and whether the daemon committed a write (the okf status/freshness/
/// /// verify verbs write; every other served read does not). `text` is the
/// stdout text payload (printed with the usual trailing newline by the CLI's
/// output writer); `bytesBase64` carries binary stdout (`source cat` of raw
/// source bytes) and is mutually exclusive with `text`; `stderr` carries the
/// stderr fragments (head-version diagnostics, zero-results notes).
public struct DaemonCommandOutcome: Codable, Equatable, Sendable {
    public let text: String?
    public let bytesBase64: String?
    public let didCommit: Bool
    public let stderr: String?

    public init(
        text: String? = nil,
        bytesBase64: String? = nil,
        didCommit: Bool = false,
        stderr: String? = nil
    ) {
        self.text = text
        self.bytesBase64 = bytesBase64
        self.didCommit = didCommit
        self.stderr = stderr
    }

    /// Decode-or-reject: a missing or malformed outcome payload is a typed
    /// `invalidRequest`, never a client-side crash.
    public static func decode(_ data: Data?) throws -> DaemonCommandOutcome {
        guard let data else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "command reply carried no outcome payload")
        }
        do {
            return try JSONDecoder().decode(DaemonCommandOutcome.self, from: data)
        } catch {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "command outcome payload could not be decoded")
        }
    }
}

/// A title-or-id selector, shared by the page/source/chat families. Exactly
/// one side is set by the CLI; the daemon treats both-nil as an
/// `invalidRequest`.
public struct DaemonCommandSelector: Codable, Equatable, Sendable {
    public let id: String?
    public let title: String?

    public init(id: String? = nil, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

// MARK: - page family

public struct DaemonPageListRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let json: Bool

    public init(wikiID: String, json: Bool) {
        self.wikiID = wikiID
        self.json = json
    }
}

/// `page get`: the workspace overlay read (`--workspace`) is served
/// daemon-side too — the daemon's store owns the staged versions.
public struct DaemonPageGetRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector
    public let json: Bool
    public let workspace: String?

    public init(
        wikiID: String,
        selector: DaemonCommandSelector,
        json: Bool,
        workspace: String? = nil
    ) {
        self.wikiID = wikiID
        self.selector = selector
        self.json = json
        self.workspace = workspace
    }
}

/// `page history` / `page info` — selector-only reads.
public struct DaemonPageSelectorRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector

    public init(wikiID: String, selector: DaemonCommandSelector) {
        self.wikiID = wikiID
        self.selector = selector
    }
}

public struct DaemonPageOKFInspectRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let json: Bool

    public init(wikiID: String, versionID: String, json: Bool) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.json = json
    }
}

/// `page okf status`: `status == nil` is the `--clear` form (an UNSET write —
/// the okf status/freshness/verify verbs are sanctioned Phase 3 scope and the
/// daemon executes their writes; `didCommit` is true so the CLI posts the
/// Darwin notification exactly as the in-process path did).
public struct DaemonPageOKFStatusRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let status: String?

    public init(wikiID: String, versionID: String, status: String?) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.status = status
    }
}

/// `page okf freshness`: the parsed freshness policy as embedded JSON
/// (`OKFFreshnessPolicy` — the contract target cannot name WikiFSCore types).
/// `nil` policyJSON is the `--clear` form.
public struct DaemonPageOKFFreshnessRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let policyJSON: Data?

    public init(wikiID: String, versionID: String, policyJSON: Data?) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.policyJSON = policyJSON
    }
}

/// `page okf verify`: the parsed verifier identity, verification basis, and
/// optional freshness policy as embedded JSON (WikiFSCore Codable structs).
/// `ttlSeconds` is the `--ttl` freshness anchor (`recordedVerification`) the
/// CLI parses into ``OKFFreshnessInput``.
public struct DaemonPageOKFVerifyRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let verifierJSON: Data
    public let verifiedAt: Date
    public let basisJSON: Data
    public let ttlSeconds: Int64?

    public init(
        wikiID: String,
        versionID: String,
        verifierJSON: Data,
        verifiedAt: Date,
        basisJSON: Data,
        ttlSeconds: Int64?
    ) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.verifierJSON = verifierJSON
        self.verifiedAt = verifiedAt
        self.basisJSON = basisJSON
        self.ttlSeconds = ttlSeconds
    }
}

// MARK: - source family

public struct DaemonSourceListRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let json: Bool

    public init(wikiID: String, json: Bool) {
        self.wikiID = wikiID
        self.json = json
    }
}

/// `source cat` (and the shared selector reads): `markdown` selects the
/// processed-markdown HEAD with the raw-bytes fallback (#553).
public struct DaemonSourceReadRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector
    public let markdown: Bool

    public init(wikiID: String, selector: DaemonCommandSelector, markdown: Bool) {
        self.wikiID = wikiID
        self.selector = selector
        self.markdown = markdown
    }
}

/// `source export`: `cwd` is the CLI process's working directory — the
/// default output path (`<cwd>/<file-<id>.<ext>`) is built and the file is
/// WRITTEN there, daemon-side, because the daemon is the process that runs
/// the command layer. Same user, same machine: the path is exactly what the
/// in-process path printed.
public struct DaemonSourceExportRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector
    public let out: String?
    public let markdown: Bool
    public let cwd: String

    public init(
        wikiID: String,
        selector: DaemonCommandSelector,
        out: String?,
        markdown: Bool,
        cwd: String
    ) {
        self.wikiID = wikiID
        self.selector = selector
        self.out = out
        self.markdown = markdown
        self.cwd = cwd
    }
}

public struct DaemonSourceInfoRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector

    public init(wikiID: String, selector: DaemonCommandSelector) {
        self.wikiID = wikiID
        self.selector = selector
    }
}

// MARK: - chat family

public struct DaemonChatListRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let json: Bool

    public init(wikiID: String, json: Bool) {
        self.wikiID = wikiID
        self.json = json
    }
}

public struct DaemonChatGetRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector

    public init(wikiID: String, selector: DaemonCommandSelector) {
        self.wikiID = wikiID
        self.selector = selector
    }
}

// MARK: - bookmark family

public struct DaemonBookmarkListRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let json: Bool

    public init(wikiID: String, json: Bool) {
        self.wikiID = wikiID
        self.json = json
    }
}

// MARK: - workspace family

public struct DaemonWorkspaceRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let id: String

    public init(wikiID: String, id: String) {
        self.wikiID = wikiID
        self.id = id
    }
}

// MARK: - search commands (server-side resolution)

/// The request for `page search` / `source search` / `chat search` — the FULL
/// command runs on the daemon: the daemon resolves the BM25 leg with its own
/// per-wiki Tantivy runtime, resolves hits against the store catalog, fuses
/// with the semantic cosine leg via the store's `searchSimilar`, and returns
/// the byte-stable rendered output + zero-results note. The CLI does no
/// catalog work at all.
public struct DaemonSearchCommandRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let query: String
    public let limit: Int

    public init(wikiID: String, query: String, limit: Int) {
        self.wikiID = wikiID
        self.query = query
        self.limit = limit
    }
}

// MARK: - queue family: queueWikiItems (job list/get)

/// The durable per-wiki queue read behind `wikictl job list/get`. Unlike
/// `queueSnapshot` (a bounded active+recent window for UI bootstrap), this
/// reads the queue store the way `QueueStore.loadItems(wikiID:)` does — every
/// item for one wiki including terminal history, newest first. `itemID` narrows
/// the read to one item (the `job get` shape); nil returns the wiki's items.
public struct DaemonQueueWikiItemsRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let itemID: String?

    public init(wikiID: String, itemID: String?) {
        self.wikiID = wikiID
        self.itemID = itemID
    }
}

/// Reply payload: the selected `[QueueItem]` as embedded JSON (the same bytes
/// `QueueItem`'s Codable conformance produces — the contract target cannot
/// name the type) plus the wiki leg the CLI used to open the store for:
/// every source id among the selected items that already has a processed-
/// markdown HEAD ("extraction completed" for the job renderer).
public struct DaemonQueueWikiItemsReply: Codable, Equatable, Sendable {
    public let itemsJSON: Data
    public let completedSourceIDs: [String]

    public init(itemsJSON: Data, completedSourceIDs: [String]) {
        self.itemsJSON = itemsJSON
        self.completedSourceIDs = completedSourceIDs
    }
}

// MARK: - queue family: queueItemState (transcribe completion wait, Phase 5)

/// The one-item state snapshot behind the transcribe completion wait. The CLI
/// loops on this operation with a sleep BETWEEN calls, so no single socket
/// connection stays open for the (possibly hours-long) speech job and the
/// standard per-call deadlines bound every round trip.
public struct DaemonQueueItemStateRequest: Codable, Equatable, Sendable {
    public let itemID: String

    public init(itemID: String) {
        self.itemID = itemID
    }
}

/// Reply payload: the item's lifecycle state as its `QueueItemState` raw
/// string, plus the recorded failure text when the state is terminal-with-
/// error (`failed`). The contract target cannot name `QueueItemState`, so the
/// raw value crosses and the CLI compares against the raw strings — the same
/// encoded-JSON convention `queueWikiItems` uses for `[QueueItem]`.
public struct DaemonQueueItemStateReply: Codable, Equatable, Sendable {
    public let state: String
    public let error: String?

    public init(state: String, error: String?) {
        self.state = state
        self.error = error
    }
}

// MARK: - Phase 4 write payloads (plans/cli-domain-commands.md)
//
// Same principle as the Phase 3 payloads: the daemon EXECUTES the CLI's
// command layer, so the payload carries the PARSED action's parameters only.
// Two rules distinguish the writes:
//
// 1. Bodies cross RESOLVED. `BodySource.file("-")` reads the EXECUTING
//    process's stdin, and the daemon has no caller stdin — so the CLI resolves
//    every body/stdin/file reference to its final String (or raw bytes, for
//    `source addFile`) before encoding. The daemon hands the command layer an
//    `.inline` body, byte-identical to what the in-process path resolved.
// 2. CAS expectations ride the request (`expectHead`, `createOnly`,
//    strategy `expect`); the daemon evaluates them inside the store write —
//    never as a separate pre-check round trip — and a failure comes back as a
//    typed CAS code with a `DaemonConflictDetail`.

/// `page add`. `body` is the resolved markdown (inline). `expectHead` nil =
/// unrestricted write; `createOnly` pins absence (`--create-only`); the parser
/// rejects both together. `provenance` is the CLI's ALREADY-ENV-MERGED
/// provenance (`PageCommand.mergedAgentIngestProvenance` ran CLI-side — the
/// daemon's environment is not the caller's).
public struct DaemonPageAddRequest: Codable, Equatable, Sendable {
    public struct ProvenanceInput: Codable, Equatable, Sendable {
        public let sourceID: String
        public let role: String

        public init(sourceID: String, role: String) {
            self.sourceID = sourceID
            self.role = role
        }
    }

    public let wikiID: String
    public let id: String?
    public let title: String
    public let body: String
    public let expectHead: String?
    public let createOnly: Bool
    public let workspace: String?
    public let author: String?
    public let provenance: [ProvenanceInput]

    public init(
        wikiID: String,
        id: String?,
        title: String,
        body: String,
        expectHead: String?,
        createOnly: Bool,
        workspace: String?,
        author: String?,
        provenance: [ProvenanceInput]
    ) {
        self.wikiID = wikiID
        self.id = id
        self.title = title
        self.body = body
        self.expectHead = expectHead
        self.createOnly = createOnly
        self.workspace = workspace
        self.author = author
        self.provenance = provenance
    }
}

/// `page delete`.
public struct DaemonPageDeleteRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let id: String
    public let unlinkIncoming: Bool

    public init(wikiID: String, id: String, unlinkIncoming: Bool) {
        self.wikiID = wikiID
        self.id = id
        self.unlinkIncoming = unlinkIncoming
    }
}

/// `page revert`.
public struct DaemonPageRevertRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector
    public let versionID: String

    public init(
        wikiID: String, selector: DaemonCommandSelector, versionID: String
    ) {
        self.wikiID = wikiID
        self.selector = selector
        self.versionID = versionID
    }
}

/// `page okf correct` — Phase 4 completes the page writes (the okf
/// status/freshness/verify verbs are Phase 3 scope). The correction input
/// crosses as embedded JSON (`OKFCorrectionInput` — the contract target
/// cannot name WikiFSCore types), exactly like the verify payload.
public struct DaemonPageOKFCorrectRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let inputJSON: Data

    public init(wikiID: String, versionID: String, inputJSON: Data) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.inputJSON = inputJSON
    }
}

/// `source add --url`. The URL identity/duplicate check and the network
/// materialization happen SERVER-side (the daemon owns the fetcher wiring);
/// the CLI sends parameters only.
public struct DaemonSourceAddURLRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let url: String
    public let allowDuplicateURL: Bool

    public init(wikiID: String, url: String, allowDuplicateURL: Bool) {
        self.wikiID = wikiID
        self.url = url
        self.allowDuplicateURL = allowDuplicateURL
    }
}

/// `source add` of raw bytes. `path` rides along ONLY for the command layer's
/// default-filename behavior (`--name` overrides); `contentBase64` is the
/// resolved file/stdin bytes. A body over the 4 MiB frame cap fails on the
/// CLIENT before connecting (`frameTooLarge`) — same ceiling family as
/// `source cat` replies.
public struct DaemonSourceAddFileRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let path: String
    public let name: String?
    public let contentBase64: String

    public init(
        wikiID: String, path: String, name: String?, contentBase64: String
    ) {
        self.wikiID = wikiID
        self.path = path
        self.name = name
        self.contentBase64 = contentBase64
    }
}

/// `source edit-markdown` — `expectedHead` is REQUIRED (the CLI parser
/// rejects a blind rewrite). A stale head comes back as typed `casConflict`
/// (kind `sourceMarkdown`).
public struct DaemonSourceEditMarkdownRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector
    public let content: String
    public let expectedHead: String

    public init(
        wikiID: String,
        selector: DaemonCommandSelector,
        content: String,
        expectedHead: String
    ) {
        self.wikiID = wikiID
        self.selector = selector
        self.content = content
        self.expectedHead = expectedHead
    }
}

/// `source rename`.
public struct DaemonSourceRenameRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector
    public let to: String

    public init(wikiID: String, selector: DaemonCommandSelector, to: String) {
        self.wikiID = wikiID
        self.selector = selector
        self.to = to
    }
}

/// `source set-active`.
public struct DaemonSourceSetActiveRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector
    public let versionID: String

    public init(
        wikiID: String, selector: DaemonCommandSelector, versionID: String
    ) {
        self.wikiID = wikiID
        self.selector = selector
        self.versionID = versionID
    }
}

/// `source refresh` — re-fetches the origin SERVER-side (the daemon's fetcher
/// wiring), then persists through the store's own append seams.
public struct DaemonSourceRefreshRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector

    public init(wikiID: String, selector: DaemonCommandSelector) {
        self.wikiID = wikiID
        self.selector = selector
    }
}

/// The source okf family (Phase 4 — mirrors the page family's Phase 3 okf
/// payloads, with `SourceMarkdownVersionID` targets). The verify/correct
/// inputs and freshness policy cross as embedded JSON (WikiFSCore Codable
/// types the contract target cannot name).
public struct DaemonSourceOKFInspectRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let json: Bool

    public init(wikiID: String, versionID: String, json: Bool) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.json = json
    }
}

public struct DaemonSourceOKFStatusRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let status: String?

    public init(wikiID: String, versionID: String, status: String?) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.status = status
    }
}

public struct DaemonSourceOKFFreshnessRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let policyJSON: Data?

    public init(wikiID: String, versionID: String, policyJSON: Data?) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.policyJSON = policyJSON
    }
}

public struct DaemonSourceOKFVerifyRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let verifierJSON: Data
    public let verifiedAt: Date
    public let basisJSON: Data
    public let ttlSeconds: Int64?

    public init(
        wikiID: String,
        versionID: String,
        verifierJSON: Data,
        verifiedAt: Date,
        basisJSON: Data,
        ttlSeconds: Int64?
    ) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.verifierJSON = verifierJSON
        self.verifiedAt = verifiedAt
        self.basisJSON = basisJSON
        self.ttlSeconds = ttlSeconds
    }
}

public struct DaemonSourceOKFCorrectRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let versionID: String
    public let inputJSON: Data

    public init(wikiID: String, versionID: String, inputJSON: Data) {
        self.wikiID = wikiID
        self.versionID = versionID
        self.inputJSON = inputJSON
    }
}

/// `chat rename`.
public struct DaemonChatRenameRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let selector: DaemonCommandSelector
    public let to: String

    public init(wikiID: String, selector: DaemonCommandSelector, to: String) {
        self.wikiID = wikiID
        self.selector = selector
        self.to = to
    }
}

/// `bookmark create-folder`.
public struct DaemonBookmarkCreateFolderRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let parentID: String?
    public let name: String

    public init(wikiID: String, parentID: String?, name: String) {
        self.wikiID = wikiID
        self.parentID = parentID
        self.name = name
    }
}

/// The wire form of a `BookmarkNode.Content` reference (the contract target
/// cannot name the type). Exactly one of page/source/chat is set.
public struct DaemonBookmarkRef: Codable, Equatable, Sendable {
    public let pageID: String?
    public let sourceID: String?
    public let chatID: String?

    public init(
        pageID: String? = nil, sourceID: String? = nil, chatID: String? = nil
    ) {
        self.pageID = pageID
        self.sourceID = sourceID
        self.chatID = chatID
    }
}

/// `bookmark add-ref`.
public struct DaemonBookmarkAddRefRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let parentID: String?
    public let ref: DaemonBookmarkRef

    public init(wikiID: String, parentID: String?, ref: DaemonBookmarkRef) {
        self.wikiID = wikiID
        self.parentID = parentID
        self.ref = ref
    }
}

/// `bookmark rename`.
public struct DaemonBookmarkRenameRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let id: String
    public let to: String

    public init(wikiID: String, id: String, to: String) {
        self.wikiID = wikiID
        self.id = id
        self.to = to
    }
}

/// `bookmark delete`.
public struct DaemonBookmarkDeleteRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let id: String

    public init(wikiID: String, id: String) {
        self.wikiID = wikiID
        self.id = id
    }
}

/// `bookmark move`.
public struct DaemonBookmarkMoveRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let id: String
    public let toParentID: String?
    public let position: Int

    public init(
        wikiID: String, id: String, toParentID: String?, position: Int
    ) {
        self.wikiID = wikiID
        self.id = id
        self.toParentID = toParentID
        self.position = position
    }
}

/// `workspace create`.
public struct DaemonWorkspaceCreateRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let name: String?

    public init(wikiID: String, name: String?) {
        self.wikiID = wikiID
        self.name = name
    }
}

/// `workspace abandon/merge/refresh/retry` — id-only writes. `merge` and
/// `reap` run under the long-running handler budget.
public struct DaemonWorkspaceIDRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let id: String

    public init(wikiID: String, id: String) {
        self.wikiID = wikiID
        self.id = id
    }
}

/// `workspace resolve` — `content` is the RESOLVED three-way-merge body (the
/// CLI read the body file/stdin before sending; the daemon has no caller
/// stdin).
public struct DaemonWorkspaceResolveRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let id: String
    public let pageID: String
    public let content: String

    public init(
        wikiID: String, id: String, pageID: String, content: String
    ) {
        self.wikiID = wikiID
        self.id = id
        self.pageID = pageID
        self.content = content
    }
}

/// `workspace reap` — the TTL rides as whole seconds.
public struct DaemonWorkspaceReapRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let ttlSeconds: Int64

    public init(wikiID: String, ttlSeconds: Int64) {
        self.wikiID = wikiID
        self.ttlSeconds = ttlSeconds
    }
}

/// The strategy family's CAS expectation: `.absent` (no strategy row ever
/// written) or a pinned revision. Both-nil is an `invalidRequest`.
public struct DaemonStrategyExpectation: Codable, Equatable, Sendable {
    /// True = the `.absent` expectation (store expectation nil).
    public let absent: Bool
    /// The pinned revision when `absent` is false.
    public let revision: Int64?

    public static func absent() -> Self {
        self.init(absent: true, revision: nil)
    }

    public static func revision(_ value: Int64) -> Self {
        self.init(absent: false, revision: value)
    }

    public init(absent: Bool, revision: Int64?) {
        self.absent = absent
        self.revision = revision
    }
}

/// `strategy read`.
public struct DaemonStrategyReadRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let json: Bool

    public init(wikiID: String, json: Bool) {
        self.wikiID = wikiID
        self.json = json
    }
}

/// `strategy save` — `content` is the resolved instructions body; a stale
/// expectation comes back as typed `strategyRevisionConflict`.
public struct DaemonStrategySaveRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let name: String?
    public let content: String
    public let expect: DaemonStrategyExpectation
    public let json: Bool

    public init(
        wikiID: String,
        name: String?,
        content: String,
        expect: DaemonStrategyExpectation,
        json: Bool
    ) {
        self.wikiID = wikiID
        self.name = name
        self.content = content
        self.expect = expect
        self.json = json
    }
}

/// `strategy reset` (keeps the revision; tombstones the row).
public struct DaemonStrategyResetRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let expect: DaemonStrategyExpectation
    public let json: Bool

    public init(
        wikiID: String, expect: DaemonStrategyExpectation, json: Bool
    ) {
        self.wikiID = wikiID
        self.expect = expect
        self.json = json
    }
}

/// `log append`. `kind` is a `LogEntry.Kind` raw value; `author` is the
/// CLI-resolved author string (nil → the command layer's legacy-import
/// default, exactly as `PageAuthor.init(rawValue:)` treats it). The daemon
/// maps both and an unknown kind is a typed `invalidRequest`.
public struct DaemonLogAppendRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let kind: String
    public let title: String
    public let note: String?
    public let source: String?
    public let author: String?

    public init(
        wikiID: String,
        kind: String,
        title: String,
        note: String?,
        source: String?,
        author: String?
    ) {
        self.wikiID = wikiID
        self.kind = kind
        self.title = title
        self.note = note
        self.source = source
        self.author = author
    }
}

/// `index set` — `body` is the resolved index document (file/stdin read
/// CLI-side).
public struct DaemonIndexSetRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let body: String
    public let workspace: String?

    public init(wikiID: String, body: String, workspace: String?) {
        self.wikiID = wikiID
        self.body = body
        self.workspace = workspace
    }
}

/// Every admin-family operation (vacuums, MIME repair): the shared
/// dry-run/`--json` shape. All admin operations run under the long-running
/// handler budget (`DaemonDomainBudgets`).
public struct DaemonAdminRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let dryRun: Bool
    public let json: Bool

    public init(wikiID: String, dryRun: Bool, json: Bool) {
        self.wikiID = wikiID
        self.dryRun = dryRun
        self.json = json
    }
}

/// `extractor sync` — the ENTIRE command runs daemon-side: catalog discovery
/// from the daemon's container, store reads, and the durable enqueue through
/// the daemon's queue engine (the `enqueueItem` machinery). The CLI sends
/// parameters only and never opens `queue.sqlite`.
public struct DaemonExtractorSyncRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let packageName: String
    public let force: Bool

    public init(wikiID: String, packageName: String, force: Bool) {
        self.wikiID = wikiID
        self.packageName = packageName
        self.force = force
    }
}

/// `extractor fetch` — same server-side shape as sync, with the item key.
public struct DaemonExtractorFetchRequest: Codable, Equatable, Sendable {
    public let wikiID: String
    public let packageName: String
    public let itemKey: String
    public let force: Bool

    public init(
        wikiID: String, packageName: String, itemKey: String, force: Bool
    ) {
        self.wikiID = wikiID
        self.packageName = packageName
        self.itemKey = itemKey
        self.force = force
    }
}
#endif
