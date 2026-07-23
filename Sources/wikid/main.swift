import Foundation
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

/// The mach service name registered with launchd. Must match the `Label` in the
/// launchd plist and the `WikiDaemonConnection.serviceName` in the client.
let WikiDaemonMachServiceName = "com.selfdrivingwiki.wikid"

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
        newConnection.resume()
        return true
    }
}

/// Bridges the `@objc WikiDaemonProtocol` (XPC requires @objc) to the pure-Swift
/// `WikiDaemon`. Each method serializes JSON `Data` over XPC.
final class WikiDaemonExporter: NSObject, WikiDaemonProtocol, @unchecked Sendable {
    private let daemon: WikiDaemon

    init(daemon: WikiDaemon) {
        self.daemon = daemon
    }

    func listWikis(reply: @escaping (Data) -> Void) {
        reply(daemon.listWikis())
    }

    func createWiki(name: String, reply: @escaping (Data?) -> Void) {
        reply(daemon.createWiki(name: name))
    }

    func deleteWiki(id: String, reply: @escaping (Bool) -> Void) {
        reply(daemon.deleteWiki(id: id))
    }

    func renameWiki(id: String, name: String, reply: @escaping (Bool) -> Void) {
        reply(daemon.renameWiki(id: id, name: name))
    }

    func resolveWiki(selector: String, reply: @escaping (Data?) -> Void) {
        reply(daemon.resolveWiki(selector: selector))
    }

    func openStore(wikiID: String, reply: @escaping (Bool) -> Void) {
        reply(daemon.openStore(wikiID: wikiID))
    }

    func closeStore(wikiID: String, reply: @escaping () -> Void) {
        daemon.closeStore(wikiID: wikiID)
        reply()
    }

    func changeToken(wikiID: String, reply: @escaping (String) -> Void) {
        reply(daemon.changeToken(wikiID: wikiID))
    }

    // MARK: - Workload: event sink registration (Phase 0)

    func registerEventSink(_ sink: WikiDaemonEventSink) {
        daemon.registerEventSink(sink)
    }

    // MARK: - Workload: queue snapshot (Phase 0 — scaffold)

    func queueSnapshot(reply: @escaping (Data) -> Void) {
        // XPC reply closures are called exactly once and are safe from any
        // thread. Wrap in a @unchecked Sendable box so the Task closure
        // satisfies Swift 6's sending requirement.
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.queueSnapshotData()
            sendableReply.reply(data)
        }
    }

    // MARK: - Workload: queue engine (Phase A+B)

    #if canImport(WikiFSEngine)
    func enqueueItem(request: Data, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            do {
                let engine = try await daemon.ensureQueueEngine()
                let req = try JSONDecoder().decode(QueueItemRequest.self, from: request)
                let id = try await engine.enqueue(req)
                let envelope: [String: String?] = ["id": id, "error": nil]
                let data = (try? JSONEncoder().encode(envelope)) ?? Data()
                sendableReply.reply(data)
            } catch {
                let envelope: [String: String?] = ["id": nil, "error": error.localizedDescription]
                let data = (try? JSONEncoder().encode(envelope)) ?? Data()
                sendableReply.reply(data)
            }
        }
    }

    func cancelItem(id: String, reply: @escaping () -> Void) {
        let sendableReply = SendableVoidReply(reply: reply)
        Task { [daemon] in
            if let engine = try? await daemon.ensureQueueEngine() {
                await engine.cancelItem(id)
            }
            sendableReply.reply()
        }
    }

    func cancelAllInFlight(reply: @escaping (Int) -> Void) {
        let sendableReply = SendableIntReply(reply: reply)
        Task { [daemon] in
            if let engine = try? await daemon.ensureQueueEngine() {
                let count = await engine.cancelAllInFlight()
                sendableReply.reply(count)
            } else {
                sendableReply.reply(0)
            }
        }
    }

    func retryItem(id: String, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            do {
                let engine = try await daemon.ensureQueueEngine()
                try await engine.retryItem(id)
                let envelope: [String: String?] = ["error": nil]
                let data = (try? JSONEncoder().encode(envelope)) ?? Data()
                sendableReply.reply(data)
            } catch {
                let envelope: [String: String?] = ["error": error.localizedDescription]
                let data = (try? JSONEncoder().encode(envelope)) ?? Data()
                sendableReply.reply(data)
            }
        }
    }

    func pauseQueue(queue: String, reply: @escaping () -> Void) {
        let sendableReply = SendableVoidReply(reply: reply)
        Task { [daemon] in
            if let engine = try? await daemon.ensureQueueEngine(),
               let queueKind = QueueKind(rawValue: queue) {
                await engine.pause(queueKind)
            }
            sendableReply.reply()
        }
    }

    func resumeQueue(queue: String, reply: @escaping () -> Void) {
        let sendableReply = SendableVoidReply(reply: reply)
        Task { [daemon] in
            if let engine = try? await daemon.ensureQueueEngine(),
               let queueKind = QueueKind(rawValue: queue) {
                await engine.resume(queueKind)
            }
            sendableReply.reply()
        }
    }

    func haltQueue(queue: String, reply: @escaping () -> Void) {
        let sendableReply = SendableVoidReply(reply: reply)
        Task { [daemon] in
            if let engine = try? await daemon.ensureQueueEngine(),
               let queueKind = QueueKind(rawValue: queue) {
                await engine.halt(queueKind)
            }
            sendableReply.reply()
        }
    }

    func reorderItem(id: String, beforeItemID: String?, reply: @escaping () -> Void) {
        let sendableReply = SendableVoidReply(reply: reply)
        Task { [daemon] in
            if let engine = try? await daemon.ensureQueueEngine() {
                await engine.reorderItem(id: id, beforeItemID: beforeItemID)
            }
            sendableReply.reply()
        }
    }

    func hasActiveWork(wikiID: String, reply: @escaping (Bool) -> Void) {
        let sendableReply = SendableBoolReply(reply: reply)
        Task { [daemon] in
            if let engine = try? await daemon.ensureQueueEngine() {
                let result = await engine.hasActiveWork(for: wikiID)
                sendableReply.reply(result)
            } else {
                sendableReply.reply(false)
            }
        }
    }

    func waitForCompletion(id: String, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            guard let engine = try? await daemon.ensureQueueEngine() else {
                let envelope: [String: Any] = ["success": false,
                                               "error": "daemon queue engine unavailable"]
                let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
                sendableReply.reply(data)
                return
            }
            let result = await engine.waitForCompletion(of: id)
            switch result {
            case .success:
                let envelope: [String: Any] = ["success": true]
                let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
                sendableReply.reply(data)
            case .failure(let error):
                let envelope: [String: Any] = ["success": false,
                                               "error": error.localizedDescription]
                let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
                sendableReply.reply(data)
            }
        }
    }

    func loadTranscript(itemID: String, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            if let engine = try? await daemon.ensureQueueEngine() {
                let events = await engine.loadTranscript(for: itemID)
                let data = (try? JSONEncoder().encode(events)) ?? Data()
                sendableReply.reply(data)
            } else {
                sendableReply.reply(Data())
            }
        }
    }

    func loadAllActivitySnapshots(reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            if let engine = try? await daemon.ensureQueueEngine() {
                let snapshots = await engine.loadAllActivitySnapshots()
                var data: [String: QueueEngine.ActivitySnapshotData] = [:]
                for (id, snapshot) in snapshots {
                    data[id] = QueueEngine.ActivitySnapshotData(from: snapshot)
                }
                let result = (try? JSONEncoder().encode(data)) ?? Data()
                sendableReply.reply(result)
            } else {
                sendableReply.reply(Data())
            }
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
            await daemon.stopChat(chatID: chatID)
            sendableReply.reply()
        }
    }

    func chatSessionState(chatID: String, reply: @escaping (Data) -> Void) {
        let sendableReply = SendableDataReply(reply: reply)
        Task { [daemon] in
            let data = await daemon.chatSessionStateData(chatID: chatID)
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
    // Linux stubs — WikiFSEngine is unavailable. Reply with safe defaults.
    func enqueueItem(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["id": nil, "error": "queue engine unavailable on Linux"]
        let data = (try? JSONEncoder().encode(envelope)) ?? Data()
        reply(data)
    }

    func cancelItem(id: String, reply: @escaping () -> Void) { reply() }
    func cancelAllInFlight(reply: @escaping (Int) -> Void) { reply(0) }

    func retryItem(id: String, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["error": "queue engine unavailable on Linux"]
        let data = (try? JSONEncoder().encode(envelope)) ?? Data()
        reply(data)
    }

    func pauseQueue(queue: String, reply: @escaping () -> Void) { reply() }
    func resumeQueue(queue: String, reply: @escaping () -> Void) { reply() }
    func haltQueue(queue: String, reply: @escaping () -> Void) { reply() }
    func reorderItem(id: String, beforeItemID: String?, reply: @escaping () -> Void) { reply() }
    func hasActiveWork(wikiID: String, reply: @escaping (Bool) -> Void) { reply(false) }

    func waitForCompletion(id: String, reply: @escaping (Data) -> Void) {
        let envelope: [String: Any] = ["success": false, "error": "queue engine unavailable on Linux"]
        let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        reply(data)
    }

    func loadTranscript(itemID: String, reply: @escaping (Data) -> Void) { reply(Data()) }
    func loadAllActivitySnapshots(reply: @escaping (Data) -> Void) { reply(Data()) }

    // Chat stubs (Phase C — chat is macOS-only via WikiFSEngine).
    func startChat(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["chatID": nil, "error": "chat unavailable on Linux"]
        reply((try? JSONEncoder().encode(envelope)) ?? Data())
    }
    func continueChat(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["error": "chat unavailable on Linux"]
        reply((try? JSONEncoder().encode(envelope)) ?? Data())
    }
    func sendChatMessage(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["error": "chat unavailable on Linux"]
        reply((try? JSONEncoder().encode(envelope)) ?? Data())
    }
    func stopChat(chatID: String, reply: @escaping () -> Void) { reply() }
    func chatSessionState(chatID: String, reply: @escaping (Data) -> Void) { reply(Data()) }
    func resolveChatPermission(request: Data, reply: @escaping () -> Void) { reply() }
    func setChatConfigOption(request: Data, reply: @escaping (Data) -> Void) {
        let envelope: [String: String?] = ["error": "chat unavailable on Linux"]
        reply((try? JSONEncoder().encode(envelope)) ?? Data())
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

// Resolve the App Group container path WITHOUT calling
// DatabaseLocation.appGroupContainerDirectory() directly — that function
// builds the literal path ~/Library/Group Containers/<id>/ and accessing it
// from a launchd-started daemon triggers kTCCServiceSystemPolicyAppData
// ("wikid would like to access data from other apps") on every rebuild
// (the code signature hash changes per build, resetting TCC trust).
//
// Instead: accept the container path from (1) a --container arg, or (2) the
// WIKI_CONTAINER_DIR env var (set by the launchd plist). If neither is
// present, fall back to DatabaseLocation (the prompt will appear once, then
// the user approves and it sticks in TCC).
let containerDirectory: URL
if let argPath = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
   FileManager.default.fileExists(atPath: argPath) {
    containerDirectory = URL(fileURLWithPath: argPath, isDirectory: true)
} else if let envPath = ProcessInfo.processInfo.environment["WIKI_CONTAINER_DIR"],
          FileManager.default.fileExists(atPath: envPath) {
    containerDirectory = URL(fileURLWithPath: envPath, isDirectory: true)
} else {
    containerDirectory = try DatabaseLocation.appGroupContainerDirectory()
}

let daemon = WikiDaemon(containerDirectory: containerDirectory)

let delegate = WikiDaemonListenerDelegate(daemon: daemon)

// The daemon is always launched via launchd (the `MachServices` key in the
// plist registers the mach service name). `NSXPCListener(machServiceName:)`
// registers with launchd so clients connecting via
// `NSXPCConnection(machServiceName:)` reach this listener.
//
// Direct-run without launchd does NOT work: the mach service isn't
// registered, and `NSXPCListenerEndpoint` can't be serialized to a file
// (it must pass through an existing XPC connection — a chicken-and-egg
// problem). Use `make install-daemon` for both development and production.
let listener = NSXPCListener(machServiceName: WikiDaemonMachServiceName)
listener.delegate = delegate
listener.resume()

DebugLog.store("wikid: daemon started, serving on \(WikiDaemonMachServiceName)")

// Keep the process alive until launchd stops it (IdleTimeout) or a signal arrives.
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
    try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
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
    let parsed: [String: Any]? = line.data(using: .utf8).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    let id = parsed?["id"]
    guard let req = parsed,
          let method = req["method"] as? String
    else {
        // Reconstruct the response with the id if we have one, else -1.
        let resp: [String: Any] = ["id": id ?? -1, "error": "invalid request"]
        if let data = try? JSONSerialization.data(withJSONObject: resp),
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
        result = daemon.deleteWiki(id: idStr)
    case "renameWiki":
        let idStr = params["id"] as? String ?? ""
        let name = params["name"] as? String ?? ""
        result = daemon.renameWiki(id: idStr, name: name)
    case "resolveWiki":
        let selector = params["selector"] as? String ?? ""
        if let data = daemon.resolveWiki(selector: selector) {
            result = String(data: data, encoding: .utf8)
        } else {
            result = nil
        }
    case "openStore":
        let wikiID = params["wikiID"] as? String ?? ""
        result = daemon.openStore(wikiID: wikiID)
    case "closeStore":
        let wikiID = params["wikiID"] as? String ?? ""
        daemon.closeStore(wikiID: wikiID)
        result = nil
    case "changeToken":
        let wikiID = params["wikiID"] as? String ?? ""
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

    if let data = try? JSONSerialization.data(withJSONObject: resp),
       let str = String(data: data, encoding: .utf8) {
        writeResponse(str)
    }
}

#endif
