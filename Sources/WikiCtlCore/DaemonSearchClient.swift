#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

/// One request/reply round trip to the daemon's `search(request:reply:)` XPC
/// endpoint. `reply` fires exactly once — with the daemon's JSON-encoded
/// `SearchRPCReply`, or with a failure when the connection died before any
/// reply (the daemon's own query failures arrive AS replies carrying a
/// `SearchRPCError`). This closure is ``DaemonSearchClient``'s injection seam.
public typealias DaemonSearchTransport = @Sendable (
    _ request: Data,
    _ reply: @escaping @Sendable (Result<Data, any Error>) -> Void
) -> Void

/// Resume-once carrier for one daemon search reply (#1428 pattern, same as
/// `DaemonXPCReplyBox` behind `DaemonWorkloadClient`): the reply, a timeout,
/// or a cancellation settles the box exactly once; stragglers are absorbed.
// NSLock protects the only mutable field and each continuation resumes at most once.
// swiftlint:disable:next unchecked_sendable
private final class SearchReplyBox: @unchecked Sendable {

    private enum Payload {
        case idle
        case waiting(CheckedContinuation<Data, Error>)
        case settled(Result<Data, Error>)
    }

    private let lock = NSLock()
    private var payload: Payload = .idle

    func fulfill(_ data: Data) {
        settle(.success(data))
    }

    func fail(_ error: Error) {
        settle(.failure(error))
    }

    /// Every settle path ends in `.settled` — the terminal state — so a
    /// duplicate reply can never reinstall a live payload or double-resume.
    private func settle(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation: CheckedContinuation<Data, Error>?
        switch payload {
        case .idle:
            payload = .settled(result)
            continuation = nil
        case .waiting(let waiting):
            payload = .settled(result)
            continuation = waiting
        case .settled:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(with: result)
    }

    /// Wait for the reply. Task cancellation releases the box with
    /// `CancellationError` so the timeout group always finishes.
    func wait() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                lock.lock()
                switch payload {
                case .idle:
                    payload = .waiting(continuation)
                    lock.unlock()
                case .settled(let result):
                    lock.unlock()
                    continuation.resume(with: result)
                case .waiting:
                    // One box serves one reply and one waiter; a second
                    // waiter is a caller bug — fail it, never double-resume.
                    lock.unlock()
                    continuation.resume(throwing: DaemonXPCError.unexpectedReply)
                }
            }
        } onCancel: {
            fail(CancellationError())
        }
    }
}

/// Async client for the daemon's unified search + autocomplete endpoint
/// (`WikiDaemonProtocol.search(request:reply:)`). The daemon is the sole
/// index owner; every search/autocomplete is one timed XPC round trip.
///
/// Callers pass a `WikiID`, a query, optional `TantivyDocumentKind` filters,
/// and a limit, and get `[TantivyShadowSearchResult]` — or a thrown error:
/// ``DaemonXPCError/timeout`` (no reply in time), ``DaemonXPCError/failure(_:)``
/// (the daemon answered with a `SearchRPCError`, formatted `"<code>: <message>"`),
/// or ``DaemonXPCError/unexpectedReply`` (malformed reply, wrong version, or a
/// hit naming an unknown kind). Transport failures rethrow as-is.
//
// The backend and timeout are immutable Sendable values.
public final class DaemonSearchClient: Sendable {

    /// Production bound for one search round trip — matches
    /// `DaemonWorkloadClient.defaultTimeout` so every daemon call shares one
    /// documented worst case.
    public static let defaultTimeout: TimeInterval = 30

    private enum Backend: Sendable {
        /// Production: the connection is retained here so it lives as long as
        /// the client; each call vends a fresh error-handler proxy from it.
        case connection(WikiDaemonConnection)
        /// Injected transport (tests, alternate hosts).
        case transport(DaemonSearchTransport)
    }

    private let backend: Backend
    private let timeout: TimeInterval

    /// Create a client over an injected transport. Tests inject a fake here so
    /// fault-injection scenarios never touch XPC.
    ///
    /// - Parameter timeout: per-call reply bound in seconds; tests inject a
    ///   short value, production callers use ``defaultTimeout``.
    public convenience init(transport: @escaping DaemonSearchTransport, timeout: TimeInterval = DaemonSearchClient.defaultTimeout) {
        self.init(backend: .transport(transport), timeout: timeout)
    }

    /// Create a client from an existing daemon connection (shares the same
    /// `NSXPCConnection` — no second connection). Retains the connection so
    /// async round trips outlive any single call scope.
    public convenience init(
        connection: WikiDaemonConnection,
        timeout: TimeInterval = DaemonSearchClient.defaultTimeout
    ) {
        self.init(backend: .connection(connection), timeout: timeout)
    }

    private init(backend: Backend, timeout: TimeInterval) {
        self.backend = backend
        self.timeout = timeout
    }

    // MARK: - Public API

    /// Search the daemon's index for one wiki. `kinds` filters the hit kinds
    /// (empty = all kinds). Hits arrive best-first in the daemon's rank order.
    public func search(
        wikiID: WikiID,
        query: String,
        kinds: [TantivyDocumentKind] = [],
        limit: Int = 20
    ) async throws -> [TantivyShadowSearchResult] {
        let kindNames = kinds.map(\.rawValue)
        let request = SearchRPCRequest(
            wikiID: wikiID.rawValue,
            operation: .search(
                query: query,
                kinds: kindNames.isEmpty ? nil : kindNames,
                limit: limit))
        return try decodeHits(try await send(request))
    }

    /// Autocomplete against the daemon's index for one wiki. `distance` is the
    /// fuzzy edit distance. Mirrors the `SearchServices.autocomplete` shape.
    public func autocomplete(
        wikiID: WikiID,
        partial: String,
        kinds: Set<TantivyDocumentKind> = [],
        distance: Int = 2,
        limit: Int = 8
    ) async throws -> [TantivyShadowSearchResult] {
        // Sorted so the encoded request is deterministic for a given input.
        let kindNames = kinds.map(\.rawValue).sorted()
        let request = SearchRPCRequest(
            wikiID: wikiID.rawValue,
            operation: .autocomplete(
                partial: partial,
                kinds: kindNames.isEmpty ? nil : kindNames,
                distance: distance,
                limit: limit))
        return try decodeHits(try await send(request))
    }

    // MARK: - Round trip

    /// Encode, send through the backend, await the reply under the timeout.
    private func send(_ request: SearchRPCRequest) async throws -> Data {
        let requestData = try SearchRPCWire.encode(request)
        let box = SearchReplyBox()
        switch backend {
        case .connection(let connection):
            // Per-call error-handler proxy (same pattern as
            // `WikiDaemonConnection.healthCheck`): a dead connection fires the
            // handler instead of leaving the reply to the timeout.
            if let proxy = connection.daemonProxy(errorHandler: { box.fail($0) }) {
                proxy.search(request: requestData) { box.fulfill($0) }
            } else {
                box.fail(WikiDaemonError.connectionFailed)
            }
        case .transport(let transport):
            transport(requestData) { result in
                switch result {
                case .success(let data): box.fulfill(data)
                case .failure(let error): box.fail(error)
                }
            }
        }
        return try await withTimeout {
            try await box.wait()
        }
    }

    /// Race the reply wait against the timeout (same shape as
    /// `DaemonWorkloadClient.withTimeout`).
    private func withTimeout<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = timeout
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw DaemonXPCError.timeout
            }
            guard let result = try await group.next() else {
                throw DaemonXPCError.unexpectedReply
            }
            group.cancelAll()
            return result
        }
    }

    /// Decode the reply envelope and map hits to typed results. A reply with
    /// neither hits nor error is malformed, not an empty success.
    private func decodeHits(_ data: Data) throws -> [TantivyShadowSearchResult] {
        let reply: SearchRPCReply
        do {
            reply = try JSONDecoder().decode(SearchRPCReply.self, from: data)
        } catch {
            DebugLog.store("DaemonSearchClient: malformed search reply: \(error)")
            throw DaemonXPCError.unexpectedReply
        }
        guard reply.version == SearchRPCVersion.current else {
            throw DaemonXPCError.unexpectedReply
        }
        if let error = reply.error {
            throw DaemonXPCError.failure("daemon search \(error.code.rawValue): \(error.message)")
        }
        guard let hits = reply.hits else {
            DebugLog.store("DaemonSearchClient: success reply carried neither hits nor error")
            throw DaemonXPCError.unexpectedReply
        }
        return try hits.map { hit in
            guard let kind = TantivyDocumentKind(rawValue: hit.kind) else {
                throw DaemonXPCError.unexpectedReply
            }
            return TantivyShadowSearchResult(
                documentID: hit.documentID,
                kind: kind,
                title: hit.title,
                score: Float(hit.score))
        }
    }
}

/// `SearchServices` backed by the daemon's per-wiki index. The daemon is the
/// sole index owner; this adapter binds one wiki id at construction so the
/// wiki-less `SearchServices` seam can be injected at session boot
/// (`bootWikiSession(searchServices:)` in the app factory). Tests inject a
/// ``DaemonSearchClient`` over a fake transport — no daemon required.
public struct DaemonSearchServices: SearchServices {
    private let wikiID: WikiID
    private let client: DaemonSearchClient

    /// Injected client — the seam tests and alternate factories use.
    public init(wikiID: WikiID, client: DaemonSearchClient) {
        self.wikiID = wikiID
        self.client = client
    }

    /// Production adapter over an existing daemon connection (the app's
    /// shared connection). Never fails — proxy vending and connection health
    /// are checked per call, so a dead connection surfaces as a thrown error
    /// from `search`/`autocomplete` instead of at construction.
    public init(
        wikiID: WikiID,
        connection: WikiDaemonConnection,
        timeout: TimeInterval = DaemonSearchClient.defaultTimeout
    ) {
        self.wikiID = wikiID
        self.client = DaemonSearchClient(connection: connection, timeout: timeout)
    }

    /// Adapter that connects its own embedded XPC service connection.
    /// Convenience for standalone hosts; the app should pass its existing
    /// connection via ``init(wikiID:connection:timeout:)`` instead. Throws if
    /// the XPC connection cannot be created.
    public init(
        wikiID: WikiID,
        timeout: TimeInterval = DaemonSearchClient.defaultTimeout
    ) throws {
        self.init(wikiID: wikiID, connection: try WikiDaemonConnection.connect(), timeout: timeout)
    }

    public func search(
        query: String,
        kinds: [TantivyDocumentKind],
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        try await client.search(wikiID: wikiID, query: query, kinds: kinds, limit: limit)
    }

    public func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8,
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        try await client.autocomplete(
            wikiID: wikiID,
            partial: partial,
            kinds: kinds,
            distance: Int(distance),
            limit: limit)
    }
}
#endif
