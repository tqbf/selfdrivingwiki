import Foundation
import WikiFSCore

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
        newConnection.exportedInterface = NSXPCInterface(with: WikiDaemonProtocol.self)

        // Wrap the daemon in an XPC-serving adapter so the @objc protocol
        // methods can call into the Swift daemon.
        let exporter = WikiDaemonExporter(daemon: daemon)
        newConnection.exportedObject = exporter
        newConnection.resume()
        return true
    }
}

/// Bridges the `@objc WikiDaemonProtocol` (XPC requires @objc) to the pure-Swift
/// `WikiDaemon`. Each method serializes JSON `Data` over XPC.
final class WikiDaemonExporter: NSObject, WikiDaemonProtocol {
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
