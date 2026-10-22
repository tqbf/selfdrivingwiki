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
/// - `wiki`   — registry + lifecycle (Phase 2); served there, rejected with a
///   typed error until then.
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

    init(daemon: WikiDaemon) {
        self.daemon = daemon
        self.exporter = WikiDaemonExporter(daemon: daemon)
    }

    /// The socket server's `Data -> Data` handler. Never throws: every path
    /// encodes a `DaemonDomainReply`.
    func handle(_ data: Data) async -> Data {
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
            try request.requireCurrentVersion()
            switch request.family {
            case .hello:
                return try helloReply(for: request)
            case .search:
                return try await searchReply(for: request)
            case .queue:
                return try await queueReply(for: request)
            case .wiki:
                return try await wikiReply(for: request)
            }
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
        throw DaemonDomainError(
            code: .unavailable,
            message: "the wiki registry family is not served by this daemon build")
    }

    // MARK: - Shared reply encoding

    /// Encode-or-empty: a `DaemonDomainReply` of these value payloads cannot
    /// fail to encode; if it ever did, an empty body is the honest "no reply"
    /// and the client surfaces it as a malformed reply.
    private static func encodedReply(_ reply: DaemonDomainReply) -> Data {
        do {
            return try DaemonDomainWire.encode(reply)
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
