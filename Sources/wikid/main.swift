import Foundation
import WikiDaemonContract
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

/// The XPC service name — must match the bundle identifier in the wikid.xpc
/// Info.plist and `WikiDaemonConnection.serviceName` in the client. The system
/// resolves this to `Contents/XPCServices/wikid.xpc` in the app bundle and
/// launches the service on-demand when a client connects via
/// `NSXPCConnection(serviceName:)`.
///
/// Per-developer, resolved from the same sidecar/Info.plist the app reads, so
/// all three agree without anything per-user in committed source. See
/// ``WikiIdentifiers/daemonServiceID``.
let WikiDaemonServiceName = WikiIdentifiers.daemonServiceID

#if os(macOS)

// MARK: - XPC listener delegate

final class WikiDaemonListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let daemon: WikiDaemon

    init(daemon: WikiDaemon) {
        self.daemon = daemon
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Build the daemon-side interface with the event-sink parameter
        // declared as an interface proxy (not a serialized object). This is
        // required for bidirectional XPC: when the app calls
        // `registerEventSink(sink)`, XPC creates a proxy for `sink` on the
        // daemon side so the daemon can call `deliverEvent(_:)` back on it.
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.exportedInterface = daemonInterface

        let exporter = WikiDaemonExporter(daemon: daemon)
        newConnection.exportedObject = exporter

        // #622: Use the connection's invalidation handler to unregister the
        // sink when the app disconnects. This replaces the problematic weak-ref
        // approach and ensures the strong sink proxy is cleaned up.
        newConnection.invalidationHandler = { [weak exporter] in
            exporter?.unregisterSink()
        }

        newConnection.resume()
        return true
    }
}

/// Bridges the `@objc WikiDaemonProtocol` (XPC requires @objc) to the pure-Swift
/// `WikiDaemon`. Each method serializes JSON `Data` over XPC.
final class WikiDaemonExporter: NSObject, WikiDaemonProtocol, @unchecked Sendable {
    private let daemon: WikiDaemon
    private let lock = NSLock()
    private var sinkID: UUID?

    init(daemon: WikiDaemon) {
        self.daemon = daemon
    }

    /// Unregister the sink associated with this connection. Called by the
    /// invalidation handler.
    func unregisterSink() {
        let id = lock.withLock { sinkID }
        if let id {
            daemon.unregisterEventSink(id: id)
        }
    }

    func listWikis(reply: @escaping (Data) -> Void) {
        reply(daemon.listWikis())
    }

    func createWiki(name: String, reply: @escaping (Data?) -> Void) {
        reply(daemon.createWiki(name: name))
    }

    func deleteWiki(id: String, reply: @escaping (Bool) -> Void) {
        reply(daemon.deleteWiki(id: WikiID(rawValue: id)))
    }

    func renameWiki(id: String, name: String, reply: @escaping (Bool) -> Void) {
        reply(daemon.renameWiki(id: WikiID(rawValue: id), name: name))
    }

    func resolveWiki(selector: String, reply: @escaping (Data?) -> Void) {
        reply(daemon.resolveWiki(selector: selector))
    }

    func openStore(wikiID: String, reply: @escaping (Bool) -> Void) {
        reply(daemon.openStore(wikiID: WikiID(rawValue: wikiID)))
    }

    func closeStore(wikiID: String, reply: @escaping () -> Void) {
        daemon.closeStore(wikiID: WikiID(rawValue: wikiID))
        reply()
    }

    func changeToken(wikiID: String, reply: @escaping (String) -> Void) {
        reply(daemon.changeToken(wikiID: WikiID(rawValue: wikiID)))
    }

    // MARK: - Workload: event sink registration (Phase 0)

    func registerEventSink(_ sink: WikiDaemonEventSink) {
        // Hold the lock across registration so that if the connection's
        // invalidation handler fires concurrently, unregisterSink blocks
        // until sinkID is set — preventing an orphaned strong sink ref.
        lock.lock()
        defer { lock.unlock() }
        sinkID = daemon.registerEventSink(sink)
    }

    // MARK: - Workload: queue engine

    #if canImport(WikiFSEngine)
    func queueSnapshot(reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let result = try await daemon.performQueueOperation { engine in
                let snapshot = await engine.snapshot()
                return try JSONEncoder().encode(snapshot)
            }
            return result.map { QueueDataPayload(data: $0) }
        }
    }

    func enqueueItem(request: Data, reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let decoded: QueueItemRequest
            do {
                decoded = try JSONDecoder().decode(QueueItemRequest.self, from: request)
            } catch {
                throw QueueRPCError(code: .invalidRequest, message: "Queue request could not be decoded")
            }
            let result = try await daemon.performQueueOperation { engine in
                try await engine.enqueue(decoded)
            }
            return result.map { QueueItemIDPayload(itemID: $0.rawValue) }
        }
    }

    func cancelItem(id: String, reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let result = try await daemon.performQueueOperation { engine in
                await engine.cancelItem(QueueItemID(rawValue: id))
            }
            return result.map { QueueVoidPayload() }
        }
    }

    func cancelAllInFlight(reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let result = try await daemon.performQueueOperation { engine in
                await engine.cancelAllInFlight()
            }
            return result.map { QueueCountPayload(count: $0) }
        }
    }

    func retryItem(id: String, reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let result = try await daemon.performQueueOperation { engine in
                try await engine.retryItem(QueueItemID(rawValue: id))
            }
            return result.map { QueueVoidPayload() }
        }
    }

    func pauseQueue(queue: String, reply: @escaping (Data) -> Void) {
        queueControlReply(queue: queue, reply: reply) { engine, queueKind in
            await engine.pause(queueKind)
        }
    }

    func resumeQueue(queue: String, reply: @escaping (Data) -> Void) {
        queueControlReply(queue: queue, reply: reply) { engine, queueKind in
            try await engine.resume(queueKind)
        }
    }

    func haltQueue(queue: String, reply: @escaping (Data) -> Void) {
        queueControlReply(queue: queue, reply: reply) { engine, queueKind in
            await engine.halt(queueKind)
        }
    }

    func reorderItem(id: String, beforeItemID: String?, reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let result = try await daemon.performQueueOperation { engine in
                await engine.reorderItem(
                    id: QueueItemID(rawValue: id),
                    beforeItemID: beforeItemID.map(QueueItemID.init(rawValue:)))
            }
            return result.map { QueueVoidPayload() }
        }
    }

    func hasActiveWork(wikiID: String, reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let result = try await daemon.performQueueOperation { engine in
                await engine.hasActiveWork(for: WikiID(rawValue: wikiID))
            }
            return result.map { QueueBoolPayload(value: $0) }
        }
    }

    func waitForCompletion(id: String, reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let result = try await daemon.performQueueOperation { engine in
                await engine.waitForCompletion(of: QueueItemID(rawValue: id))
            }
            return result.map { completion in
                switch completion {
                case .success:
                    QueueCompletionPayload(completed: true)
                case .failure(let error):
                    QueueCompletionPayload(completed: false, errorMessage: error.localizedDescription)
                }
            }
        }
    }

    func loadTranscript(itemID: String, reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let result = try await daemon.performQueueOperation { engine in
                let items = await engine.loadTranscript(for: QueueItemID(rawValue: itemID))
                return try JSONEncoder().encode(items)
            }
            return result.map { QueueDataPayload(data: $0) }
        }
    }

    func loadAllActivitySnapshots(reply: @escaping (Data) -> Void) {
        queueReply(reply) { [daemon] in
            let result = try await daemon.performQueueOperation { engine in
                let snapshots = await engine.loadAllActivitySnapshots()
                var payload: [String: QueueEngine.ActivitySnapshotData] = [:]
                for (id, snapshot) in snapshots {
                    payload[id.rawValue] = QueueEngine.ActivitySnapshotData(from: snapshot)
                }
                return try JSONEncoder().encode(payload)
            }
            return result.map { QueueDataPayload(data: $0) }
        }
    }

    func queueOwnershipStatus(reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let status = await daemon.queueHostStatus()
            let payload = QueueOwnershipStatusPayload(
                epoch: status.epoch,
                hostState: status.hostState)
            sendableReply.reply(Self.encodeQueueEnvelope(
                .success(payload, epoch: status.epoch, hostState: status.hostState)))
        }
    }

    func relinquishQueue(request: Data, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            do {
                let envelope = try QueueRPCWire.decode(
                    QueueRelinquishmentRequest.self,
                    from: request)
                let decoded = try envelope.requirePayload()
                guard envelope.ownershipEpoch == decoded.expectedEpoch else {
                    throw QueueRPCError(
                        code: .invalidEnvelope,
                        message: "Queue relinquishment request epoch mismatch")
                }
                let success = try await daemon.relinquishQueue(expectedEpoch: decoded.expectedEpoch)
                sendableReply.reply(Self.encodeQueueEnvelope(
                    .success(success, epoch: success.completedEpoch, hostState: .relinquished)))
            } catch {
                let status = await daemon.queueHostStatus()
                let envelope = QueueRPCEnvelope<QueueRelinquishmentSuccess>.failure(
                    Self.queueRPCError(from: error),
                    epoch: status.epoch,
                    hostState: status.hostState)
                sendableReply.reply(Self.encodeQueueEnvelope(envelope))
            }
        }
    }

    private func queueControlReply(
        queue: String,
        reply: @escaping (Data) -> Void,
        operation: @escaping @Sendable (QueueEngine, QueueKind) async throws -> Void
    ) {
        queueReply(reply) { [daemon] in
            guard let queueKind = QueueKind(rawValue: queue)?.canonical else {
                throw QueueRPCError(code: .invalidRequest, message: "Unknown queue kind: \(queue)")
            }
            let result = try await daemon.performQueueOperation { engine in
                try await operation(engine, queueKind)
            }
            return result.map { QueueVoidPayload() }
        }
    }

    private func queueReply<Payload: Codable & Sendable>(
        _ reply: @escaping (Data) -> Void,
        operation: @escaping @Sendable () async throws -> DaemonQueueOperationResult<Payload>
    ) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            do {
                let result = try await operation()
                sendableReply.reply(Self.encodeQueueEnvelope(
                    .success(result.value, epoch: result.epoch, hostState: result.hostState)))
            } catch {
                let status = await daemon.queueHostStatus()
                let envelope = QueueRPCEnvelope<Payload>.failure(
                    Self.queueRPCError(from: error),
                    epoch: status.epoch,
                    hostState: status.hostState)
                sendableReply.reply(Self.encodeQueueEnvelope(envelope))
            }
        }
    }

    private static func queueRPCError(from error: Error) -> QueueRPCError {
        if let queueError = error as? QueueRPCError { return queueError }
        return QueueRPCError(code: .operationFailed, message: error.localizedDescription)
    }

    private static func encodeQueueEnvelope<Payload: Codable & Sendable>(
        _ envelope: QueueRPCEnvelope<Payload>
    ) -> Data {
        do {
            return try QueueRPCWire.encode(envelope)
        } catch {
            DebugLog.store("wikid: queue reply encoding failed: \(error)")
            return Data("{\"version\":1,\"ownershipEpoch\":{\"rawValue\":0},\"hostState\":\"shutdownBlocked\",\"error\":{\"code\":\"invalidEnvelope\",\"message\":\"Queue reply encoding failed\"}}".utf8)
        }
    }

    // MARK: - Workload: chat (Phase C)

    func startChat(request: Data, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.startChatData(request: request)
            sendableReply.reply(data)
        }
    }

    func submitChatTurn(request: Data, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.submitChatTurnData(request: request)
            sendableReply.reply(data)
        }
    }

    func continueChat(request: Data, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.continueChatData(request: request)
            sendableReply.reply(data)
        }
    }

    func sendChatMessage(request: Data, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.sendChatMessageData(request: request)
            sendableReply.reply(data)
        }
    }

    func stopChat(chatID: String, reply: @escaping () -> Void) {
        let sendableReply = SendableVoidReply(reply: reply)
        Task { [daemon] in
            await daemon.stopChat(chatID: ChatID(rawValue: chatID))
            sendableReply.reply()
        }
    }

    func chatSessionState(chatID: String, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.chatSessionStateData(chatID: ChatID(rawValue: chatID))
            sendableReply.reply(data)
        }
    }

    func chatDiagnosticSnapshot(request: Data, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.chatDiagnosticSnapshotData(request: request)
            sendableReply.reply(data)
        }
    }

    func resetChatDiagnostics(request: Data, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.resetChatDiagnosticsData(request: request)
            sendableReply.reply(data)
        }
    }

    func resolveChatPermission(request: Data, reply: @escaping () -> Void) {
        let sendableReply = SendableVoidReply(reply: reply)
        Task { [daemon] in
            await daemon.resolveChatPermissionData(request: request)
            sendableReply.reply()
        }
    }

    func setChatConfigOption(request: Data, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.setChatConfigOptionData(request: request)
            sendableReply.reply(data)
        }
    }
    #else
    // Engine-less macOS stubs. Every selector still returns a typed envelope.
    private func unavailableQueueReply<Payload: Codable & Sendable>(
        _ payload: Payload.Type
    ) -> Data {
        let epoch = QueueOwnershipEpoch(rawValue: 0)
        let envelope = QueueRPCEnvelope<Payload>.failure(
            QueueRPCError(code: .unavailable, message: "Queue engine is unavailable"),
            epoch: epoch,
            hostState: .shutdownBlocked)
        return (DebugLog.trying("QueueRPCWire.encode", operation: {
            try QueueRPCWire.encode(envelope)
        })) ?? Data()
    }

    func queueSnapshot(reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueDataPayload.self))
    }
    func enqueueItem(request: Data, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueItemIDPayload.self))
    }
    func cancelItem(id: String, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueVoidPayload.self))
    }
    func cancelAllInFlight(reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueCountPayload.self))
    }
    func retryItem(id: String, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueVoidPayload.self))
    }
    func pauseQueue(queue: String, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueVoidPayload.self))
    }
    func resumeQueue(queue: String, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueVoidPayload.self))
    }
    func haltQueue(queue: String, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueVoidPayload.self))
    }
    func reorderItem(id: String, beforeItemID: String?, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueVoidPayload.self))
    }
    func hasActiveWork(wikiID: String, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueBoolPayload.self))
    }
    func waitForCompletion(id: String, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueCompletionPayload.self))
    }
    func loadTranscript(itemID: String, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueDataPayload.self))
    }
    func loadAllActivitySnapshots(reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueDataPayload.self))
    }
    func queueOwnershipStatus(reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueOwnershipStatusPayload.self))
    }
    func relinquishQueue(request: Data, reply: @escaping (Data) -> Void) {
        reply(unavailableQueueReply(QueueRelinquishmentSuccess.self))
    }

    // Chat stubs (Phase C — chat is macOS-only via WikiFSEngine).
    func startChat(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["chatID": nil, "error": "chat unavailable on Linux"]
        reply((DebugLog.trying("JSONEncoder.encode", operation: { try JSONEncoder().encode(envelope) })) ?? Data())
    }
    func submitChatTurn(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["chatID": nil, "error": "chat unavailable on Linux"]
        reply((DebugLog.trying("JSONEncoder.encode", operation: { try JSONEncoder().encode(envelope) })) ?? Data())
    }
    func continueChat(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["error": "chat unavailable on Linux"]
        reply((DebugLog.trying("JSONEncoder.encode", operation: { try JSONEncoder().encode(envelope) })) ?? Data())
    }
    func sendChatMessage(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["error": "chat unavailable on Linux"]
        reply((DebugLog.trying("JSONEncoder.encode", operation: { try JSONEncoder().encode(envelope) })) ?? Data())
    }
    func stopChat(chatID: String, reply: @escaping () -> Void) { reply() }
    func chatSessionState(chatID: String, reply: @escaping (Data) -> Void) { reply(Data()) }
    func chatDiagnosticSnapshot(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func resetChatDiagnostics(request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func resolveChatPermission(request: Data, reply: @escaping () -> Void) { reply() }
    func setChatConfigOption(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["error": "chat unavailable on Linux"]
        reply((DebugLog.trying("JSONEncoder.encode", operation: { try JSONEncoder().encode(envelope) })) ?? Data())
    }
    #endif
}

/// Wraps an XPC `@escaping (Data) -> Void` reply in a `@unchecked Sendable`
/// box. XPC reply closures are designed to be called once from any thread —
/// this satisfies Swift 6 strict-concurrency without changing semantics.
private struct SendableDataReply: @unchecked Sendable {
    let reply: (Data) -> Void
}

/// Wraps an XPC `@escaping () -> Void` reply (same rationale as
/// ``SendableDataReply``).
private struct SendableVoidReply: @unchecked Sendable {
    let reply: () -> Void
}

/// Wraps an XPC `@escaping (Int) -> Void` reply.
private struct SendableIntReply: @unchecked Sendable {
    let reply: (Int) -> Void
}

/// Wraps an XPC `@escaping (Bool) -> Void` reply.
private struct SendableBoolReply: @unchecked Sendable {
    let reply: (Bool) -> Void
}

// MARK: - Main

// Resolve the App Group container path. The daemon reaches the SHARED group
// container through the security API —
// `containerURL(forSecurityApplicationGroupIdentifier:)`, via
// `DatabaseLocation.extensionContainerDirectory()` — which the
// `application-groups` entitlement maps to the real
// `~/Library/Group Containers/<id>/` the app writes to. This is robust whether
// or not the daemon is sandboxed.
//
// History (#887): the XPC migration briefly sandboxed the daemon AND resolved
// the container via `appGroupContainerDirectory()`, whose LITERAL
// `homeDirectoryForCurrentUser/Library/Group Containers/<id>` path resolves to
// the SANDBOX home inside a sandbox — an empty sandbox-local dir with no
// `wikis.json` → every ingest failed "No store for wikiID". The daemon is now
// un-sandboxed (it must spawn arbitrary agent CLIs), but the security-API
// resolution is kept as the explicit, correct way to reach the shared container.
//
// Precedence: (1) a `--container` arg or (2) `WIKI_CONTAINER_DIR` env (dev, set
// by `make install-daemon`), then (3) the security-API shared container, then
// (4) the literal path as a last resort (dev build with no app-group entitlement).
let containerDirectory: URL
if let argPath = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
   FileManager.default.fileExists(atPath: argPath) {
    containerDirectory = URL(fileURLWithPath: argPath, isDirectory: true)
} else if let envPath = ProcessInfo.processInfo.environment["WIKI_CONTAINER_DIR"],
          FileManager.default.fileExists(atPath: envPath) {
    containerDirectory = URL(fileURLWithPath: envPath, isDirectory: true)
} else if let shared = DatabaseLocation.extensionContainerDirectory() {
    containerDirectory = shared
} else {
    containerDirectory = try DatabaseLocation.appGroupContainerDirectory()
}

// Diagnostic: log the RESOLVED App Group id, WHERE it came from, and the
// container the daemon will use. The group id comes from
// `WikiIdentifiers.appGroupID` (read from the id sidecar bundled in the
// daemon's own Contents/Resources). If that sidecar is missing, resolution has
// no configured source left — `appGroupContainerDirectory()` now refuses rather
// than manufacturing a `group.org.sockpuppet.wiki` container with NO wikis, so
// the daemon fails above instead of reaching this line. `source=` records which
// leg won, which is the fastest way to spot a container that resolves but
// resolves WRONG. (#887.)
DebugLog.store("""
wikid: resolved appGroup=\(WikiIdentifiers.appGroupID) \
source=\(WikiIdentifiers.appGroupIDSource.rawValue) \
container=\(containerDirectory.path)
""")

let daemon = WikiDaemon(containerDirectory: containerDirectory)
let processLifetime = DaemonProcessLifetimeCoordinator(
    shutdown: {
        await daemon.shutdown()
    },
    didShutdown: {
        Darwin.exit(EXIT_SUCCESS)
    })
processLifetime.installSignalHandlers()

let delegate = WikiDaemonListenerDelegate(daemon: daemon)

// The daemon is a bundled XPC service (Contents/XPCServices/wikid.xpc). The
// system creates the listener and passes connections to it. We obtain the
// singleton service listener via `NSXPCListener.service()`, set our delegate,
// and resume. For a service listener, `resume()` never returns — it hands
// control to the system's run loop, which is ideal for the XPC service's
// main() function. No `RunLoop.current.run()` needed.
//
// Clients connect via `NSXPCConnection(serviceName: WikiDaemonServiceName)`.
// The system auto-launches the service on the first connection and terminates
// it after idle (no LaunchAgent plist, no launchctl, no stale-daemon races).
let listener = NSXPCListener.service()
listener.delegate = delegate

// Emit the startup log + start the #878 liveness heartbeat BEFORE resume() —
// `resume()` on a service listener never returns (it hands control to the
// system's run loop), so anything after it is unreachable in production. The
// "XPC service started" log line in particular is the first thing an operator
// greps for to confirm the service launched.
DebugLog.store("wikid: XPC service started, serving on \(WikiDaemonServiceName)")

// #878: start the liveness heartbeat (logs every 60 s so an operator can
// confirm the daemon is alive + see its current load in Console.app).
daemon.startHeartbeat()

listener.resume()

// Unreachable in production — `listener.resume()` above never returns. Kept as
// a fallback for non-XPC execution contexts (tests, direct invocation for
// debugging), where `service()` returns a listener whose `resume()` does not
// block.
RunLoop.current.run()

#else // Linux

// MARK: - Linux stdio JSON-RPC transport

// On Linux there is no XPC / launchd. The daemon reads line-delimited JSON-RPC
// requests from stdin and writes line-delimited JSON-RPC responses to stdout.
// This is the MVP transport for issue #754: "starts, opens a DB, serves — even
// if feature-incomplete." A richer transport (Unix domain socket, gRPC) is a
// follow-up.

// Resolve the container directory: (1) --container arg, (2) WIKI_CONTAINER_DIR
// env var, (3) ~/.local/share/selfdrivingwiki as a last-resort default.
let containerDirectory: URL
if let argPath = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
   FileManager.default.fileExists(atPath: argPath) {
    containerDirectory = URL(fileURLWithPath: argPath, isDirectory: true)
} else if let envPath = ProcessInfo.processInfo.environment["WIKI_CONTAINER_DIR"],
          FileManager.default.fileExists(atPath: envPath) {
    containerDirectory = URL(fileURLWithPath: envPath, isDirectory: true)
} else {
    // Linux default — a conventional XDG-style data directory.
    let home = FileManager.default.homeDirectoryForCurrentUser
    let defaultDir = home.appendingPathComponent(".local/share/selfdrivingwiki", isDirectory: true)
    // createDirectory(withIntermediateDirectories:) succeeds when the dir
    // already exists, so a real failure here means permissions/disk — log it
    // rather than swallow silently (house rule: never bare try?).
    do {
        try FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
    } catch {
        DebugLog.store("wikid: failed to create default data directory \(defaultDir.path): \(error)")
    }
    containerDirectory = defaultDir
}

let daemon = WikiDaemon(containerDirectory: containerDirectory)

DebugLog.store("wikid: daemon started (Linux stdio transport), container=\(containerDirectory.path)")

// Simple line-delimited JSON-RPC loop.
// Request:  {"method": "listWikis", "id": 1, "params": {}}
// Response: {"id": 1, "result": <data>}   or   {"id": 1, "error": "..."}
//
// On Linux, FileHandle.standardOutput is the Sendable-accessible way to
// write to stdout — the raw `stdout` global is shared mutable state,
// which Swift 6 strict concurrency flags as unsafe (#754).
let standardOutput = FileHandle.standardOutput
func writeResponse(_ string: String) {
    if let data = string.data(using: .utf8) {
        standardOutput.write(data)
    }
}

while let line = readLine() {
    let parsed: [String: Any]? = line.data(using: .utf8).flatMap { data in
        DebugLog.trying("JSONSerialization.jsonObject", operation: {
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        })
    }
    let id = parsed?["id"]
    guard let req = parsed,
          let method = req["method"] as? String
    else {
        // Reconstruct the response with the id if we have one, else -1.
        let resp: [String: Any] = ["id": id ?? -1, "error": "invalid request"]
        if let data = DebugLog.trying("JSONSerialization.data", operation: { try JSONSerialization.data(withJSONObject: resp) }),
           let str = String(data: data, encoding: .utf8) {
            writeResponse(str)
        }
        continue
    }

    let params = req["params"] as? [String: Any] ?? [:]
    var result: Any? = nil
    var error: String? = nil

    switch method {
    case "listWikis":
        result = String(data: daemon.listWikis(), encoding: .utf8) ?? "[]"
    case "createWiki":
        let name = params["name"] as? String ?? ""
        if let data = daemon.createWiki(name: name) {
            result = String(data: data, encoding: .utf8)
        } else {
            error = "createWiki failed"
        }
    case "deleteWiki":
        let idStr = params["id"] as? String ?? ""
        result = daemon.deleteWiki(id: WikiID(rawValue: idStr))
    case "renameWiki":
        let idStr = params["id"] as? String ?? ""
        let name = params["name"] as? String ?? ""
        result = daemon.renameWiki(id: WikiID(rawValue: idStr), name: name)
    case "resolveWiki":
        let selector = params["selector"] as? String ?? ""
        if let data = daemon.resolveWiki(selector: selector) {
            result = String(data: data, encoding: .utf8)
        } else {
            result = nil
        }
    case "openStore":
        let wikiID = WikiID(rawValue: params["wikiID"] as? String ?? "")
        result = daemon.openStore(wikiID: wikiID)
    case "closeStore":
        let wikiID = WikiID(rawValue: params["wikiID"] as? String ?? "")
        daemon.closeStore(wikiID: wikiID)
        result = nil
    case "changeToken":
        let wikiID = WikiID(rawValue: params["wikiID"] as? String ?? "")
        result = daemon.changeToken(wikiID: wikiID)
    case "queueSnapshot":
        // Phase 0 scaffold: returns an empty JSON snapshot (no WikiFSEngine
        // on Linux — workload host is compiled out).
        result = "{}"
    case "registerEventSink":
        // No-op on Linux (no XPC event-sink transport). Logged for visibility.
        DebugLog.store("wikid: registerEventSink is a no-op on Linux")
        result = nil
    default:
        error = "unknown method: \(method)"
    }

    var resp: [String: Any] = ["id": id as Any]
    if let error {
        resp["error"] = error
    } else {
        resp["result"] = result as Any
    }

    if let data = DebugLog.trying("JSONSerialization.data", operation: { try JSONSerialization.data(withJSONObject: resp) }),
       let str = String(data: data, encoding: .utf8) {
        writeResponse(str)
    }
}

#endif
