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
#endif
