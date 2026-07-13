import Foundation
import WikiFSCore

/// The mach service name registered with launchd. Must match the `Label` in the
/// launchd plist and the `WikiDaemonConnection.serviceName` in the client.
let WikiDaemonMachServiceName = "com.selfdrivingwiki.wikid"

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

do {
    let containerDirectory = try DatabaseLocation.appGroupContainerDirectory()
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
} catch {
    DebugLog.store("wikid: fatal — could not start: \(error)")
    exit(1)
}
