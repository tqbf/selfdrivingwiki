#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

// MARK: - XPC store transport (slice 2)
//
// The XPC conformer of ``RemoteWikiStoreTransport`` (plans/daemon-only-access.md
// slice 2), beside ``WikiDaemonConnection``: one `.store`-family round trip
// per call through the daemon's `storeOperation` selector
// (`WikiDaemonProtocol.storeOperation(_:request:reply:)`), replying with the
// SAME `DaemonDomainReply` envelope bytes the domain-socket path returns —
// one reply shape for both transports.
//
// Connection discipline mirrors `DaemonWorkloadClient`: the XPC connection
// is vendored once (owned by the app wiring) and every call vends a FRESH
// proxy from it, with a per-call error handler so a mid-flight connection
// death surfaces as a thrown error instead of a dropped reply (the #878
// healthCheck lesson). Every call also races a timeout — neither the XPC
// reply nor the error handler is guaranteed to fire when the mach service
// is wedged (#884), so the timeout is the backstop that always answers.
//
// Connection-identity correlation (the `dropUploads` sweep): the EXPORTER
// keys staged uploads to ITS OWN stable per-connection id
// (`WikiDaemonExporter.connectionID` → `stagedPayloadReply` →
// `DaemonPayloadStagingStore.begin`), and the exporter's invalidation
// handler sweeps that id. The correlation is server-authoritative — this
// transport never invents an id the daemon did not assign, so
// ``connectionIdentifier`` reports nil honestly.
//
// Sendable: `connection` is an immutable reference to a thread-safe
// `WikiDaemonConnection` (same conformance as `DaemonWorkloadClient`); the
// only mutable-adjacent state is the `let` backend enum and the `let`
// timeout — no lock is needed because nothing mutates after init.
// swiftlint:disable:next unchecked_sendable
public final class XPCStoreTransport: RemoteWikiStoreTransport, @unchecked Sendable {

    /// Production bound for one selector round trip (the backstop race).
    /// The store's own per-call deadline races this too; the smaller of the
    /// two answers first, so a wedged mach service produces a typed
    /// ``RemoteStoreClientError/deadlineExceeded`` instead of a stalled
    /// caller.
    public static let defaultTimeout: TimeInterval =
        RemoteWikiStore.defaultCallDeadline

    private enum Backend {
        /// Production app path: the shared `WikiDaemonConnection`; each call
        /// vends a fresh proxy from it.
        case connection(WikiDaemonConnection)
        /// Test/fixture path: the invoker performs the selector call
        /// directly (the in-process exporter round trip).
        case invoker(Invoker)
    }

    /// The selector-call seam: `storeOperation(_ wikiID:request:reply:)`.
    typealias Invoker = @Sendable (
        _ wikiID: String,
        _ request: Data,
        _ reply: @escaping @Sendable (Data) -> Void
    ) -> Void

    private let backend: Backend
    private let timeout: TimeInterval

    /// Create a transport over an existing daemon connection (shares the
    /// same `NSXPCConnection` — no second connection).
    public init(
        connection: WikiDaemonConnection,
        timeout: TimeInterval = XPCStoreTransport.defaultTimeout
    ) {
        self.backend = .connection(connection)
        self.timeout = timeout
    }

    /// The fixture seam: `invoker` performs the selector call (tests pass
    /// the real `WikiDaemonExporter`'s `storeOperation` in-process).
    init(
        invoker: @escaping Invoker,
        timeout: TimeInterval = XPCStoreTransport.defaultTimeout
    ) {
        self.backend = .invoker(invoker)
        self.timeout = timeout
    }

    /// The correlation id this transport's connection contributes to staged
    /// uploads. Nil, honestly: the exporter keys uploads with its own
    /// server-assigned id (see the file header) — a client-invented id
    /// could never match the sweep.
    public var connectionIdentifier: String? { nil }

    public func send(
        _ request: DaemonDomainRequest,
        sinkRegistrationID: UUID? = nil
    ) async throws -> DaemonDomainReply {
        // The selector carries the wiki scoping as its first argument (the
        // exporter validates it against the request's own wikiID), so the
        // wiki id decodes from the store request the store already encoded.
        let storeRequest: DaemonStoreRequest
        do {
            storeRequest = try DaemonStoreWire.decodeRequest(
                try Self.requirePayload(request))
        } catch {
            throw RemoteStoreClientError.malformedReply(
                "\(request.operation) request payload was not a decodable "
                    + "store request: " + String(describing: error))
        }

        let replyData = try await invokeSelector(
            wikiID: storeRequest.wikiID, request: request.payload ?? Data(),
            operation: request.operation)

        let domainReply: DaemonDomainReply
        do {
            domainReply = try JSONDecoder().decode(
                DaemonDomainReply.self, from: replyData)
        } catch {
            throw RemoteStoreClientError.malformedReply(
                "\(request.operation) reply envelope decode failed: "
                    + String(describing: error))
        }
        return domainReply
    }

    /// One selector round trip: vend the per-call proxy (with an error
    /// handler so a dead connection fails fast), then race the reply
    /// against the timeout — the first side to finish resumes, the rest
    /// are no-ops (the `ContinuationResumeBox` discipline).
    private func invokeSelector(
        wikiID: String, request: Data, operation: String
    ) async throws -> Data {
        let box = ReplyResumeBox()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            let timeoutTask = Task.detached(priority: .userInitiated) {
                do {
                    try await Task.sleep(for: .seconds(self.timeout))
                    box.resume(
                        .failure(RemoteStoreClientError.deadlineExceeded(
                            operation: operation, seconds: self.timeout)),
                        continuation)
                } catch is CancellationError {
                    // The reply or error handler completed before the
                    // timeout fired.
                } catch {
                    box.resume(
                        .failure(RemoteStoreClientError.daemonUnavailable(
                            "store transport timeout task failed: "
                                + String(describing: error))),
                        continuation)
                }
            }
            @Sendable func finish(_ result: Result<Data, Error>) {
                timeoutTask.cancel()
                box.resume(result, continuation)
            }

            switch self.backend {
            case .invoker(let invoker):
                invoker(wikiID, request) { replyData in
                    finish(.success(replyData))
                }
            case .connection(let connection):
                guard let proxy = connection.daemonProxy(errorHandler: { error in
                    DebugLog.store(
                        "XPCStoreTransport[\(operation)]: XPC failed: \(error)")
                    finish(.failure(RemoteStoreClientError.daemonUnavailable(
                        "the XPC connection failed: " + String(describing: error))))
                }) else {
                    finish(.failure(RemoteStoreClientError.daemonUnavailable(
                        "the XPC connection could not vend the daemon proxy")))
                    return
                }
                proxy.storeOperation(
                    wikiID,
                    request: request,
                    reply: { replyData in
                        finish(.success(replyData))
                    })
            }
        }
    }

    private static func requirePayload(
        _ request: DaemonDomainRequest
    ) throws -> Data {
        guard let payload = request.payload, !payload.isEmpty else {
            throw RemoteStoreClientError.malformedReply(
                "\(request.operation) request carried no payload")
        }
        return payload
    }
}

/// Thread-safe single-resume wrapper (the `WikiDaemonConnection`
/// `ContinuationResumeBox` discipline, file-local): the XPC reply, the XPC
/// error handler, and the timeout can all race — only the first resumes.
// NSLock protects the only mutable field and each continuation resumes at
// most once.
// swiftlint:disable:next unchecked_sendable
private final class ReplyResumeBox: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    func resume(
        _ result: Result<Data, Error>,
        _ continuation: CheckedContinuation<Data, Error>
    ) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        if shouldResume {
            continuation.resume(with: result)
        }
    }
}
#endif
