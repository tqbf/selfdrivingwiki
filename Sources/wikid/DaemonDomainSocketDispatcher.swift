#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

/// Payload-level dispatch for the daemon's CLI socket — the one socket file
/// from PR #1460 now carries every CLI⇄daemon family, not just search.
///
/// The byte-level transport (`DaemonSearchSocketServer`: framing, flock guard,
/// same-user gate, deadlines) is unchanged; its `Data -> Data` handler is THIS
/// dispatcher instead of `searchData` directly. The handler decodes the
/// versioned domain envelope (`DaemonDomainWire`), version-checks before
/// dispatch, routes by family, and ALWAYS answers with an encoded
/// `DaemonDomainReply` — an unknown family/operation or a malformed payload
/// is a typed `invalidRequest` reply, never a transport failure.
///
/// Connection contexts (plans/agent-sandbox-scoping.md §6): the ordinary
/// socket keeps the exact pre-scoping behavior (v1+v2 envelopes, no
/// credentials); a `.scopedRun` context — handed in by a run-lifetime
/// listener that captured its identity at bind time — passes the scoped
/// validation gate (authorization, operation policy, target scope) before
/// the same family handlers run. Scoped PRODUCTION listeners are not wired
/// in this phase; the core is exercised by tests only.
///
/// Family routing:
/// - `hello`  — `capabilities`: the daemon's protocol version, served
///   families, and build identity (version negotiation for a newer CLI
///   against an older daemon).
/// - `search` — the payload is the unchanged `SearchRPCRequest` JSON; the
///   reply payload is the unchanged `SearchRPCReply` JSON from
///   `WikiDaemon.searchData`. PR #1460's search behavior is untouched.
/// - `queue`  — the payload is the unchanged `QueueRPCEnvelope` JSON pair.
///   Routing reuses `WikiDaemonExporter`'s queue handlers verbatim (the same
///   code the app's XPC surface serves), so the queue error taxonomy and
///   engine-less stubs stay identical on both transports.
/// - `wiki`   — registry + lifecycle: `listWikis`, `createWiki`, `deleteWiki`,
///   `renameWiki`, `resolveWiki`, each routing to the daemon's existing
///   registry methods (Phase 2). Delete inherits the daemon's full eviction.
//
// Sendable invariant: both stored fields are immutable after init and the
// dispatcher holds no mutable state of its own; `WikiDaemon` and
// `WikiDaemonExporter` are internally synchronized (the daemon's queue
// discipline), so concurrent handler calls are safe.
// swiftlint:disable:next unchecked_sendable
final class DaemonDomainSocketDispatcher: @unchecked Sendable {

    private let daemon: WikiDaemon
    /// The XPC-shaped exporter the queue family routes through. It is a thin
    /// `Data`-reply wrapper over `WikiDaemon` — no listener, no sink — so a
    /// second instance here shares nothing mutable with the app's exporter.
    private let exporter: WikiDaemonExporter
    /// The Phase 3 command-family executor: runs the CLI's read-only command
    /// layer against the daemon's prepared services (plans/cli-domain-commands.md).
    private let commands: DaemonDomainCommands
    /// The scoped-run registry (plans/agent-sandbox-scoping.md §5): owner-side
    /// registration (the Phase 2 broker) and the dispatcher's authorization
    /// lookups share this instance. Injected so a host wires ONE registry
    /// across every endpoint; the default gives each dispatcher its own (the
    /// ordinary CLI socket needs none, and tests register against the
    /// instance they hand in).
    private let runRegistry: DaemonRunRegistry
    /// The scoped-request guard: version gate, registry authorization,
    /// operation policy, target scope (§6). Consulted ONLY for scoped
    /// connections — the ordinary path below is byte-identical to the
    /// pre-scoping dispatcher.
    private let scopeGuard: DaemonScopedRequestGuard

    init(daemon: WikiDaemon, runRegistry: DaemonRunRegistry = DaemonRunRegistry()) {
        self.daemon = daemon
        self.exporter = WikiDaemonExporter(daemon: daemon)
        self.commands = DaemonDomainCommands(daemon: daemon)
        self.runRegistry = runRegistry
        self.scopeGuard = DaemonScopedRequestGuard(
            registry: runRegistry,
            // The run's OWN descriptor — resolved by its registered ULID,
            // never a foreign selector (§6: do not resolve another wiki
            // globally before denying it). Gives the guard the assigned
            // display name so scoped requests may name their own wiki by
            // name as well as id.
            assignedWiki: { [daemon] wikiID in
                guard let data = daemon.resolveWiki(selector: wikiID.rawValue) else {
                    return nil
                }
                do {
                    return try JSONDecoder().decode(WikiDescriptor.self, from: data)
                } catch {
                    DebugLog.store(
                        "wikid: assigned wiki descriptor decode failed: \(error)")
                    return nil
                }
            },
            queueItemOwningWiki: { [daemon] itemID in
                try await daemon.queueItemOwningWiki(itemID: itemID)
            })
    }

    /// The socket server's `Data -> Data` handler. Never throws: every path
    /// encodes a `DaemonDomainReply`. The connection CONTEXT is the trusted
    /// listener's identity for the connection — `.ordinary` (the App Group
    /// CLI socket) or `.scopedRun` (a run-lifetime listener that captured its
    /// run identity at bind time; Phase 2 wires those listeners). The default
    /// keeps every pre-scoping call site unchanged.
    func handle(
        _ data: Data,
        context: DaemonConnectionContext = .ordinary
    ) async -> Data {
        let request: DaemonDomainRequest
        do {
            request = try DaemonDomainWire.decodeRequest(data)
        } catch let error as DaemonDomainError {
            // The envelope itself was unreadable: no requestID/family to echo.
            return Self.encodedReply(.failure(
                requestID: "", family: nil, operation: "", error))
        } catch {
            return Self.encodedReply(.failure(
                requestID: "", family: nil, operation: "",
                DaemonDomainError(code: .invalidRequest, message: String(describing: error))))
        }
        do {
            switch context {
            case .ordinary:
                // Version check BEFORE dispatch; v1 stays served through the
                // compatibility window (plans/agent-sandbox-scoping.md §9).
                try request.requireCurrentVersion()
            case .scopedRun(let listenerRunID):
                // Validation (scoped version gate + authorization + policy +
                // target scope) runs after decode and BEFORE family dispatch
                // (§6 insertion point). The scoped hello without credentials
                // answers version-only inside.
                return try await handleScoped(request, listenerRunID: listenerRunID)
            }
            return try await dispatchFamilies(request)
        } catch let error as DaemonDomainError {
            return Self.encodedReply(.failure(
                requestID: request.requestID,
                family: request.family,
                operation: request.operation,
                error))
        } catch {
            return Self.encodedReply(.failure(
                requestID: request.requestID,
                family: request.family,
                operation: request.operation,
                DaemonDomainError(code: .operationFailed, message: String(describing: error))))
        }
    }

    // MARK: - Scoped connections

    /// The scoped path: authorization first, then the SAME family handlers —
    /// except `wiki resolveWiki`, which is special-cased to resolve ONLY the
    /// run's assigned wiki (§6).
    private func handleScoped(
        _ request: DaemonDomainRequest,
        listenerRunID: DaemonRunID
    ) async throws -> Data {
        // §9: an uncredentialed scoped hello reports the required protocol
        // version ONLY — no families, no build identity, no wiki data.
        if request.family == .hello, request.authorization == nil {
            let payload = DaemonHelloPayload.versionOnly(
                protocolVersion: DaemonDomainVersion.current)
            return Self.encodedReply(.success(
                requestID: request.requestID,
                family: .hello,
                operation: request.operation,
                payload: try JSONEncoder().encode(payload)))
        }
        let grant: DaemonRunGrant
        do {
            grant = try await scopeGuard.evaluate(
                request, listenerRunID: listenerRunID)
        } catch let error as DaemonDomainError {
            // Diagnostics name the code and the listener's run — NEVER the
            // presented capability and never a wiki name.
            DebugLog.store(
                "wikid: scoped request denied (\(error.code.rawValue), "
                    + "run \(listenerRunID))")
            throw error
        }
        if request.family == .wiki,
            request.operation == DaemonDomainOperation.Wiki.resolveWiki
        {
            return try await scopedResolveWikiReply(for: request, grant: grant)
        }
        return try await dispatchFamilies(request)
    }

    /// Scoped `wiki resolveWiki`: the assigned descriptor or a GENERIC scope
    /// denial. The selector must name the run's own wiki (id or display
    /// name); any other selector — including one that matches a different
    /// live wiki — gets the fixed denial text, which names no wiki and leaks
    /// no existence.
    private func scopedResolveWikiReply(
        for request: DaemonDomainRequest,
        grant: DaemonRunGrant
    ) async throws -> Data {
        let selector = try wikiPayload(DaemonWikiResolveRequest.self, request)
        guard let descriptorData = daemon.resolveWiki(selector: grant.scope.wikiID.rawValue) else {
            // The run's own wiki vanished from the registry: nothing this
            // run asks resolves.
            throw DaemonScopedRequestGuard.scopeDenied()
        }
        let descriptor: WikiDescriptor
        do {
            descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: descriptorData)
        } catch {
            throw DaemonDomainError(
                code: .operationFailed,
                message: "wiki descriptor could not be decoded")
        }
        guard selector.selector == descriptor.id.rawValue
            || selector.selector == descriptor.displayName
        else {
            throw DaemonScopedRequestGuard.scopeDenied()
        }
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .wiki,
            operation: request.operation,
            payload: descriptorData))
    }

    // MARK: - Family dispatch (ordinary + authorized scoped requests)

    /// The family switch shared by both connection contexts. Callers have
    /// already passed the version gate (and, for scoped connections, the
    /// full authorization/policy/target validation).
    private func dispatchFamilies(_ request: DaemonDomainRequest) async throws -> Data {
        switch request.family {
        case .hello:
            return try helloReply(for: request)
        case .search:
            return try await searchReply(for: request)
        case .queue:
            return try await queueReply(for: request)
        case .wiki:
            return try await wikiReply(for: request)
        case .page, .source, .chat, .bookmark, .workspace,
             .strategy, .log, .admin, .extractor:
            // Phase 3+4 command families: the daemon executes the CLI's
            // command layer (reads and writes) against its prepared
            // services; typed CAS codes ride back inside the envelope.
            return try await commands.reply(for: request)
        }
    }

    // MARK: - hello

    private func helloReply(for request: DaemonDomainRequest) throws -> Data {
        guard request.operation == DaemonDomainOperation.Hello.capabilities else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown hello operation: \(request.operation)")
        }
        let payload = DaemonHelloPayload(
            protocolVersion: DaemonDomainVersion.current,
            families: DaemonDomainFamily.allCases.map(\.rawValue).sorted(),
            appVersion: GeneratedVersion.appVersion,
            buildVersion: GeneratedVersion.buildVersion)
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .hello,
            operation: request.operation,
            payload: try JSONEncoder().encode(payload)))
    }

    // MARK: - search

    private func searchReply(for request: DaemonDomainRequest) async throws -> Data {
        guard request.operation == DaemonDomainOperation.Search.search else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown search operation: \(request.operation)")
        }
        guard let payload = request.payload else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "search request carries no payload")
        }
        // The unchanged PR #1460 search wire values, wrapped by the envelope.
        let searchReplyData = await daemon.searchData(request: payload)
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .search,
            operation: request.operation,
            payload: searchReplyData))
    }

    // MARK: - queue

    private func queueReply(for request: DaemonDomainRequest) async throws -> Data {
        // Each verb routes through the SAME exporter handler the app's XPC
        // surface serves, so the daemon-side queue logic — error envelopes,
        // ownership epoch stamps, engine-less stubs — is identical on both
        // transports. The exporter always invokes the reply closure exactly
        // once; its bytes are the envelope payload unchanged.
        let replyData: Data
        switch request.operation {
        case DaemonDomainOperation.Queue.queueSnapshot:
            replyData = await awaitExporterReply { reply in
                self.exporter.queueSnapshot(reply: reply)
            }
        case DaemonDomainOperation.Queue.enqueueItem:
            guard let payload = request.payload else {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "enqueueItem carries no payload")
            }
            replyData = await awaitExporterReply { reply in
                self.exporter.enqueueItem(request: payload, reply: reply)
            }
        case DaemonDomainOperation.Queue.pauseQueue, DaemonDomainOperation.Queue.resumeQueue,
            DaemonDomainOperation.Queue.haltQueue:
            guard let payload = request.payload else {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "\(request.operation) carries no payload")
            }
            let control: DaemonQueueControlRequest
            do {
                control = try JSONDecoder().decode(DaemonQueueControlRequest.self, from: payload)
            } catch {
                throw DaemonDomainError(
                    code: .invalidRequest,
                    message: "\(request.operation) payload could not be decoded")
            }
            let queue = control.queue
            switch request.operation {
            case DaemonDomainOperation.Queue.pauseQueue:
                replyData = await awaitExporterReply { reply in
                    self.exporter.pauseQueue(queue: queue, reply: reply)
                }
            case DaemonDomainOperation.Queue.resumeQueue:
                replyData = await awaitExporterReply { reply in
                    self.exporter.resumeQueue(queue: queue, reply: reply)
                }
            default:
                replyData = await awaitExporterReply { reply in
                    self.exporter.haltQueue(queue: queue, reply: reply)
                }
            }
        case DaemonDomainOperation.Queue.queueWikiItems:
            // Phase 3: the durable per-wiki read behind `wikictl job list/get`
            // — full terminal history + the extraction-completed wiki leg.
            replyData = try await commands.queueWikiItemsReply(for: request)
        case DaemonDomainOperation.Queue.queueItemState:
            // Phase 5: the one-item state snapshot the transcribe completion
            // wait polls — one short read per round trip.
            replyData = try await commands.queueItemStateReply(for: request)
        case DaemonDomainOperation.Queue.transcribePreflight:
            // Phase 5: the speech enqueue preflight — the YouTube-scope check
            // through the daemon's prepared store.
            replyData = try await commands.transcribePreflightReply(for: request)
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown queue operation: \(request.operation)")
        }
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .queue,
            operation: request.operation,
            payload: replyData))
    }

    /// Bridges the exporter's XPC-shaped `(Data) -> Void` reply closure into
    /// async. The closure fires exactly once on every exporter path (success
    /// and typed-failure envelopes alike); the resume-once box absorbs a
    /// straggler rather than double-resuming, which would trap.
    private func awaitExporterReply(
        _ send: @escaping @Sendable (_ reply: @escaping @Sendable (Data) -> Void) -> Void
    ) async -> Data {
        let box = ExporterReplyBox()
        send { box.fulfill($0) }
        return await box.wait()
    }

    // MARK: - wiki (Phase 2)

    private func wikiReply(for request: DaemonDomainRequest) async throws -> Data {
        // Each verb routes to the daemon's EXISTING registry methods — the
        // same code the app's XPC surface serves. Reads adopt the on-disk
        // registry (the app is the primary writer); delete inherits the
        // daemon's full eviction (search runtime shutdown, child profile
        // removal, registry row, database artifacts), closing the CLI's
        // degraded-delete race. Descriptor payloads are the daemon's own
        // JSON bytes.
        let payload: Data?
        switch request.operation {
        case DaemonDomainOperation.Wiki.listWikis:
            payload = daemon.listWikis()
        case DaemonDomainOperation.Wiki.resolveWiki:
            let selector = try wikiPayload(DaemonWikiResolveRequest.self, request)
            guard let descriptorData = daemon.resolveWiki(selector: selector.selector) else {
                throw DaemonDomainError(
                    code: .notFound,
                    message: "no wiki matching \(selector.selector)")
            }
            payload = descriptorData
        case DaemonDomainOperation.Wiki.createWiki:
            let create = try wikiPayload(DaemonWikiCreateRequest.self, request)
            guard let descriptorData = await daemon.createWikiOverSocket(name: create.name) else {
                throw DaemonDomainError(
                    code: .operationFailed,
                    message: "wiki creation failed on the daemon")
            }
            payload = descriptorData
        case DaemonDomainOperation.Wiki.deleteWiki:
            let delete = try wikiPayload(DaemonWikiDeleteRequest.self, request)
            // Resolve FIRST so an unknown id is a typed notFound (the CLI's
            // byte-stable "no wiki matching <id>" failure) instead of a
            // generic delete failure.
            guard daemon.resolveWiki(selector: delete.id) != nil else {
                throw DaemonDomainError(
                    code: .notFound,
                    message: "no wiki matching \(delete.id)")
            }
            guard await daemon.deleteWikiOverSocket(id: WikiID(rawValue: delete.id)) else {
                throw DaemonDomainError(
                    code: .operationFailed,
                    message: "wiki delete failed on the daemon")
            }
            payload = nil
        case DaemonDomainOperation.Wiki.renameWiki:
            let rename = try wikiPayload(DaemonWikiRenameRequest.self, request)
            // Same resolve-first notFound contract as delete.
            guard daemon.resolveWiki(selector: rename.id) != nil else {
                throw DaemonDomainError(
                    code: .notFound,
                    message: "no wiki matching \(rename.id)")
            }
            guard daemon.renameWiki(id: WikiID(rawValue: rename.id), name: rename.name) else {
                throw DaemonDomainError(
                    code: .operationFailed,
                    message: "wiki rename failed on the daemon (empty name, deleted wiki, or unreadable registry)")
            }
            payload = nil
        default:
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "unknown wiki operation: \(request.operation)")
        }
        return Self.encodedReply(.success(
            requestID: request.requestID,
            family: .wiki,
            operation: request.operation,
            payload: payload))
    }

    /// Decodes a wiki-family request payload; a missing or malformed one is a
    /// typed `invalidRequest`.
    private func wikiPayload<Payload: Decodable>(
        _ type: Payload.Type,
        _ request: DaemonDomainRequest
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

    // MARK: - Shared reply encoding

    /// Encode-or-empty: a `DaemonDomainReply` of these value payloads cannot
    /// fail to encode; if it ever did, an empty body is the honest "no reply"
    /// and the client surfaces it as a malformed reply. An encoded reply that
    /// would exceed the socket's 4 MiB frame cap is replaced by a TYPED
    /// `operationFailed` failure envelope instead — never a truncation and
    /// never a client-side transport fault (the client refuses oversized
    /// announced lengths before buffering).
    private static func encodedReply(_ reply: DaemonDomainReply) -> Data {
        do {
            let encoded = try DaemonDomainWire.encode(reply)
            if encoded.count > Int(SearchSocketWire.maxFrameSize) {
                return try DaemonDomainWire.encode(.failure(
                    requestID: reply.requestID,
                    family: reply.family,
                    operation: reply.operation,
                    DaemonDomainError(
                        code: .operationFailed,
                        message: "reply payload (\(encoded.count) bytes) exceeds the socket "
                            + "frame cap (\(SearchSocketWire.maxFrameSize) bytes) — use a "
                            + "narrower read (for example `source export --out <file>`); "
                            + "nothing was truncated")))
            }
            return encoded
        } catch {
            DebugLog.store("wikid: domain reply encoding failed: \(error)")
            return Data()
        }
    }
}

/// Resume-once carrier for one exporter queue reply: the exporter's reply
/// closure fulfils the box exactly once; a second invocation is absorbed
/// instead of double-resuming the continuation (which traps). The NSLock is
/// the Sendable invariant for the single mutable field.
// swiftlint:disable:next unchecked_sendable
private final class ExporterReplyBox: @unchecked Sendable {

    private enum Payload {
        case idle
        case waiting(CheckedContinuation<Data, Never>)
        case settled(Data)
    }

    private let lock = NSLock()
    private var payload: Payload = .idle

    func fulfill(_ data: Data) {
        lock.lock()
        let continuation: CheckedContinuation<Data, Never>?
        switch payload {
        case .idle:
            payload = .settled(data)
            continuation = nil
        case .waiting(let waiting):
            payload = .settled(data)
            continuation = waiting
        case .settled:
            // Resume-once: a straggling second reply is discarded.
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: data)
    }

    func wait() async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            lock.lock()
            switch payload {
            case .idle:
                payload = .waiting(continuation)
                lock.unlock()
            case .settled(let data):
                lock.unlock()
                continuation.resume(returning: data)
            case .waiting:
                // One box serves one reply and one waiter; a second waiter is
                // a caller bug — fail it with empty data, never double-resume.
                lock.unlock()
                continuation.resume(returning: Data())
            }
        }
    }
}
#endif
