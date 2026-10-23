#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

// Scoped-request validation (plans/agent-sandbox-scoping.md §6).
//
// The dispatcher accepts a trusted CONNECTION CONTEXT — the ordinary CLI
// socket, or one scoped run's endpoint whose run identity the LISTENER
// captured at accept time (never an envelope field). For scoped connections
// the guard runs after the version check and BEFORE family dispatch:
//
//   version (scoped gate) → authorization (registry) → operation policy →
//   target scope → (then, and only then, the family handler)
//
// Every rejection is a typed `DaemonDomainError` REPLY — never a transport
// failure — and every denial message is generic: no other wiki's name, no
// existence leak, no credential echo.

/// The trusted context one dispatcher call carries. The ordinary value is
/// every pre-scoping call site's behavior; the scoped value arrives from a
/// run-lifetime listener (Phase 2) whose identity was captured at bind time.
enum DaemonConnectionContext: Sendable, Equatable {
    /// The ordinary App Group CLI socket: same-user trust, no capability.
    case ordinary
    /// One scoped run's endpoint: the listener's captured run identity.
    case scopedRun(DaemonRunID)
}

/// The exhaustive classification one (family, operation) pair receives for
/// scoped requests. Unknown pairs DENY (fail closed).
enum DaemonScopeDecision: Equatable, Sendable {
    /// Non-data protocol traffic (the `hello` handshake): no wiki target and
    /// no operation class. A CREDENTIALED scoped hello still passes the
    /// authorization step; an UNcredentialed one answers version-only before
    /// authorization.
    case protocolOnly
    /// Allowed, classified into one operation class the lease must carry.
    case allow(DaemonRunOperationClass)
    /// Denied for every scoped run.
    case deny
}

/// The target a request names, extracted BEFORE authorization decides
/// anything about it. Extraction decodes only the target field — never the
/// operation payload.
enum DaemonScopedTarget: Equatable, Sendable {
    /// No wiki target (hello).
    case none
    /// An explicit wiki target that must equal the registered scope.
    case wiki(WikiID)
    /// An item-only queue request: the OWNING wiki is resolved daemon-side
    /// before authorization (knowledge of an item id is not access).
    case queueItem(QueueItemID)
}

// MARK: - Operation policy table

/// THE exhaustive operation-policy table for scoped requests
/// (plans/agent-sandbox-scoping.md §"Initial operation policy" + the §13
/// approved decisions).
///
/// Rules the table encodes:
/// - Every family/operation pair that exists is classified here — allowed
///   (with its operation class), protocol-only (hello), or denied. A pair
///   added to `DaemonDomainOperation` without a row here is denied AND fails
///   `DaemonScopePolicyContractTests`, which parses the operation constants
///   out of the contract source and requires a row for each.
/// - `wikiRead`/`wikiEdit`/`wikiAcquire` are granted per the plan's initial
///   policy; registry mutation, global queue controls, admin maintenance,
///   scoped `source export` (§13.3), and `source refresh` (§13.4) are
///   DENIED outright.
enum DaemonScopedOperationPolicy {

    /// The complete table. Keyed by family, then operation constant.
    /// `DaemonScopePolicyContractTests` proves this covers EVERY operation
    /// constant in `DaemonDomainOperation` — adding an operation without a
    /// decision fails the build's test gate.
    static let table: [DaemonDomainFamily: [String: DaemonScopeDecision]] = [
        .hello: [
            DaemonDomainOperation.Hello.capabilities: .protocolOnly,
        ],
        .search: [
            // Wiki-bound search: the payload names the wiki, checked below.
            DaemonDomainOperation.Search.search: .allow(.wikiRead),
        ],
        .queue: [
            // GLOBAL queue snapshot: denied.
            DaemonDomainOperation.Queue.queueSnapshot: .deny,
            // Per-wiki extraction enqueue — the acquire class.
            DaemonDomainOperation.Queue.enqueueItem: .allow(.wikiAcquire),
            // GLOBAL lane controls: denied (§13.4).
            DaemonDomainOperation.Queue.pauseQueue: .deny,
            DaemonDomainOperation.Queue.resumeQueue: .deny,
            DaemonDomainOperation.Queue.haltQueue: .deny,
            // The durable per-wiki job read (`wikictl job list/get`).
            DaemonDomainOperation.Queue.queueWikiItems: .allow(.wikiRead),
            // Item-only state read: ownership resolved before authorization.
            DaemonDomainOperation.Queue.queueItemState: .allow(.wikiRead),
            // The per-wiki speech-enqueue preflight read.
            DaemonDomainOperation.Queue.transcribePreflight: .allow(.wikiRead),
        ],
        .wiki: [
            // Registry enumeration: denied. Scoped resolution goes through
            // `resolveWiki`, which is special-cased to answer ONLY the
            // assigned descriptor.
            DaemonDomainOperation.Wiki.listWikis: .deny,
            // Registry mutation: denied (§13.4).
            DaemonDomainOperation.Wiki.createWiki: .deny,
            DaemonDomainOperation.Wiki.deleteWiki: .deny,
            DaemonDomainOperation.Wiki.renameWiki: .deny,
            // Allowed with restricted execution: resolves ONLY the assigned
            // wiki; anything else is a generic scope denial.
            DaemonDomainOperation.Wiki.resolveWiki: .allow(.wikiRead),
        ],
        .page: [
            DaemonDomainOperation.Page.list: .allow(.wikiRead),
            DaemonDomainOperation.Page.get: .allow(.wikiRead),
            DaemonDomainOperation.Page.history: .allow(.wikiRead),
            DaemonDomainOperation.Page.info: .allow(.wikiRead),
            DaemonDomainOperation.Page.okfInspect: .allow(.wikiRead),
            DaemonDomainOperation.Page.search: .allow(.wikiRead),
            // OKF status/freshness/verify/correct MUTATE the page (statuses,
            // policies, verifications, corrections) — edits, not reads.
            DaemonDomainOperation.Page.okfStatus: .allow(.wikiEdit),
            DaemonDomainOperation.Page.okfFreshness: .allow(.wikiEdit),
            DaemonDomainOperation.Page.okfVerify: .allow(.wikiEdit),
            DaemonDomainOperation.Page.okfCorrect: .allow(.wikiEdit),
            DaemonDomainOperation.Page.add: .allow(.wikiEdit),
            DaemonDomainOperation.Page.delete: .allow(.wikiEdit),
            DaemonDomainOperation.Page.revert: .allow(.wikiEdit),
        ],
        .source: [
            DaemonDomainOperation.Source.list: .allow(.wikiRead),
            // The scoped read path for source bytes (§8: scratch copies ride
            // `source cat`; exports are denied below).
            DaemonDomainOperation.Source.cat: .allow(.wikiRead),
            DaemonDomainOperation.Source.info: .allow(.wikiRead),
            DaemonDomainOperation.Source.search: .allow(.wikiRead),
            DaemonDomainOperation.Source.okfInspect: .allow(.wikiRead),
            // §13.3: scoped `source export` writes caller-selected paths
            // daemon-side (a symlink race the fence cannot see) — DENIED
            // until a bounded download protocol exists.
            DaemonDomainOperation.Source.export: .deny,
            DaemonDomainOperation.Source.addURL: .allow(.wikiAcquire),
            DaemonDomainOperation.Source.addFile: .allow(.wikiAcquire),
            DaemonDomainOperation.Source.editMarkdown: .allow(.wikiEdit),
            DaemonDomainOperation.Source.rename: .allow(.wikiEdit),
            DaemonDomainOperation.Source.setActive: .allow(.wikiEdit),
            // §13.4: source refresh (a server-side re-fetch) is denied in
            // the initial policy.
            DaemonDomainOperation.Source.refresh: .deny,
            DaemonDomainOperation.Source.okfStatus: .allow(.wikiEdit),
            DaemonDomainOperation.Source.okfFreshness: .allow(.wikiEdit),
            DaemonDomainOperation.Source.okfVerify: .allow(.wikiEdit),
            DaemonDomainOperation.Source.okfCorrect: .allow(.wikiEdit),
        ],
        .chat: [
            DaemonDomainOperation.Chat.list: .allow(.wikiRead),
            DaemonDomainOperation.Chat.get: .allow(.wikiRead),
            DaemonDomainOperation.Chat.search: .allow(.wikiRead),
            DaemonDomainOperation.Chat.rename: .allow(.wikiEdit),
        ],
        .bookmark: [
            DaemonDomainOperation.Bookmark.list: .allow(.wikiRead),
            DaemonDomainOperation.Bookmark.createFolder: .allow(.wikiEdit),
            DaemonDomainOperation.Bookmark.addRef: .allow(.wikiEdit),
            DaemonDomainOperation.Bookmark.rename: .allow(.wikiEdit),
            DaemonDomainOperation.Bookmark.delete: .allow(.wikiEdit),
            DaemonDomainOperation.Bookmark.move: .allow(.wikiEdit),
        ],
        .workspace: [
            DaemonDomainOperation.Workspace.status: .allow(.wikiRead),
            DaemonDomainOperation.Workspace.conflicts: .allow(.wikiRead),
            DaemonDomainOperation.Workspace.create: .allow(.wikiEdit),
            DaemonDomainOperation.Workspace.abandon: .allow(.wikiEdit),
            DaemonDomainOperation.Workspace.merge: .allow(.wikiEdit),
            DaemonDomainOperation.Workspace.refresh: .allow(.wikiEdit),
            DaemonDomainOperation.Workspace.resolve: .allow(.wikiEdit),
            DaemonDomainOperation.Workspace.retry: .allow(.wikiEdit),
            DaemonDomainOperation.Workspace.reap: .allow(.wikiEdit),
        ],
        .strategy: [
            DaemonDomainOperation.Strategy.read: .allow(.wikiRead),
            DaemonDomainOperation.Strategy.save: .allow(.wikiEdit),
            DaemonDomainOperation.Strategy.reset: .allow(.wikiEdit),
        ],
        .log: [
            DaemonDomainOperation.Log.logAppend: .allow(.wikiEdit),
            DaemonDomainOperation.Log.indexSet: .allow(.wikiEdit),
        ],
        .admin: [
            // Admin maintenance: denied entirely (§13.4).
            DaemonDomainOperation.Admin.vacuumBlobs: .deny,
            DaemonDomainOperation.Admin.vacuumActivities: .deny,
            DaemonDomainOperation.Admin.vacuumPageVersions: .deny,
            DaemonDomainOperation.Admin.vacuumAll: .deny,
            DaemonDomainOperation.Admin.repairMIME: .deny,
        ],
        .extractor: [
            // Catalog + store read + DURABLE ENQUEUE — the acquire class.
            DaemonDomainOperation.Extractor.sync: .allow(.wikiAcquire),
            DaemonDomainOperation.Extractor.fetch: .allow(.wikiAcquire),
        ],
    ]

    /// The classification for one pair. ANY pair missing from the table (an
    /// unknown operation, a future family) denies for scoped requests —
    /// fail closed by construction, not by list.
    static func decision(
        family: DaemonDomainFamily,
        operation: String
    ) -> DaemonScopeDecision {
        table[family]?[operation] ?? .deny
    }
}

// MARK: - Target extraction

enum DaemonScopedTargetExtractionError: Error {
    /// The payload needed a target and none could be read: the scoped path
    /// refuses to authorize what it cannot see (the ordinary path answers
    /// the same operation `invalidRequest` at decode time).
    case unreadableTarget
}

enum DaemonScopedTargetExtractor {

    /// Extract the target from a request's payload WITHOUT decoding the
    /// operation. Every wiki-scoped payload in the contract carries
    /// `wikiID` (command families, the search RPC pair, and the queue
    /// enqueue request all name the field identically), so one minimal
    /// decode covers them; `queueItemState` is the one item-only shape.
    /// Batch and nested members (bookmark refs, source id lists inside an
    /// enqueue) live inside the TARGET wiki's namespace — they resolve
    /// within the assigned store only, after the wiki target has matched.
    static func extract(
        family: DaemonDomainFamily,
        operation: String,
        payload: Data?
    ) throws -> DaemonScopedTarget {
        switch family {
        case .hello:
            return .none
        case .wiki where operation == DaemonDomainOperation.Wiki.resolveWiki:
            // The resolve payload names a SELECTOR, not a wiki id; the
            // dispatcher's scoped special-case restricts resolution to the
            // assigned wiki (the generic denial covers everything else).
            return .none
        case .queue where operation == DaemonDomainOperation.Queue.queueItemState:
            struct ItemID: Decodable { let itemID: String }
            let decoded = try decode(ItemID.self, payload, operation: operation)
            return .queueItem(QueueItemID(rawValue: decoded.itemID))
        default:
            struct EnvelopeWikiID: Decodable { let wikiID: String }
            let decoded = try decode(EnvelopeWikiID.self, payload, operation: operation)
            return .wiki(WikiID(rawValue: decoded.wikiID))
        }
    }

    private static func decode<Type: Decodable>(
        _ type: Type.Type,
        _ payload: Data?,
        operation: String
    ) throws -> Type {
        guard let payload else {
            throw DaemonScopedTargetExtractionError.unreadableTarget
        }
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw DaemonScopedTargetExtractionError.unreadableTarget
        }
    }
}

// MARK: - The guard

/// Evaluates one scoped request: scoped version gate, registry
/// authorization, operation policy, and target-scope match. The dispatcher
/// calls this (only for `.scopedRun` connections) after decode and before
/// family dispatch; the returned grant is the authority the family handler
/// runs under.
///
/// Injected lookups keep the guard unit-testable without a daemon:
/// `assignedWiki` resolves the run's OWN wiki descriptor (never a foreign
/// selector — §6 forbids resolving another wiki globally before denying),
/// and `queueItemOwningWiki` resolves a queue item's owning wiki through the
/// daemon's read-only queue store.
struct DaemonScopedRequestGuard: Sendable {

    private let registry: DaemonRunRegistry
    private let assignedWiki: @Sendable (WikiID) -> WikiDescriptor?
    private let queueItemOwningWiki: @Sendable (QueueItemID) async throws -> WikiID?

    init(
        registry: DaemonRunRegistry,
        assignedWiki: @escaping @Sendable (WikiID) -> WikiDescriptor?,
        queueItemOwningWiki: @escaping @Sendable (QueueItemID) async throws -> WikiID?
    ) {
        self.registry = registry
        self.assignedWiki = assignedWiki
        self.queueItemOwningWiki = queueItemOwningWiki
    }

    /// Run the full scoped validation. Throws typed authorization errors.
    func evaluate(
        _ request: DaemonDomainRequest,
        listenerRunID: DaemonRunID
    ) async throws -> DaemonRunGrant {
        // 1. VERSION — scoped listeners serve the CURRENT version only; a v1
        // envelope cannot carry authorization, so it must not ride past the
        // gate.
        try request.requireScopedCurrentVersion()

        // 2. AUTHORIZATION — the capability is mandatory; absence is never
        // unrestricted access. The listener's captured run identity is
        // authoritative: a capability that authorizes a DIFFERENT run is
        // invalid on this endpoint (cross-run capability, matrix row 7).
        guard let authorization = request.authorization else {
            throw DaemonDomainError(
                code: .authorizationRequired,
                message: DaemonDomainError.genericAuthorizationMessage)
        }
        guard let capability = DaemonRunCapability(printable: authorization.capability) else {
            throw DaemonDomainError(
                code: .authorizationInvalid,
                message: DaemonDomainError.genericAuthorizationMessage)
        }
        let grant = try await registry.authorize(capability: capability)
        guard grant.runID == listenerRunID else {
            throw DaemonDomainError(
                code: .authorizationInvalid,
                message: DaemonDomainError.genericAuthorizationMessage)
        }

        // 3. OPERATION POLICY — the exhaustive table; unknown pairs deny.
        let decision = DaemonScopedOperationPolicy.decision(
            family: request.family, operation: request.operation)
        switch decision {
        case .deny:
            throw Self.scopeDenied()
        case .protocolOnly:
            return grant
        case .allow(let operationClass):
            guard grant.operationClasses.contains(operationClass) else {
                throw Self.scopeDenied()
            }
        }

        // 4. TARGET SCOPE — the target must be the registered wiki; queue
        // item-only requests resolve the OWNING wiki first (knowledge of an
        // item id is not access; an unknown item denies identically).
        let target = try DaemonScopedTargetExtractor.extract(
            family: request.family,
            operation: request.operation,
            payload: request.payload)
        switch target {
        case .none:
            break
        case .wiki(let requested):
            // Resolve names ONLY within the assigned wiki: match the id or
            // the assigned wiki's own display name; never a global resolve.
            let assigned = assignedWiki(grant.scope.wikiID)
            let matches = requested == grant.scope.wikiID
                || (assigned.map { requested.rawValue == $0.displayName } ?? false)
            guard matches else {
                throw Self.scopeDenied()
            }
        case .queueItem(let itemID):
            let owner = try await queueItemOwningWiki(itemID)
            guard owner == grant.scope.wikiID else {
                throw Self.scopeDenied()
            }
        }
        return grant
    }

    /// The fixed generic scope-denial reply: no wiki names, no existence
    /// leak, no credential echo.
    static func scopeDenied() -> DaemonDomainError {
        DaemonDomainError(
            code: .scopeDenied,
            message: "the request is outside the scope of this run")
    }
}
#endif
