#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSTypes

/// Manages the wikid LaunchAgent via `launchctl` (replaces SMAppService).
///
/// The daemon is an unsandboxed binary that reads the app group container
/// directly via filesystem permissions — no entitlements needed. AMFI no
/// longer kills it at launch: the bare Mach-O had no embedded provisioning
/// profile, and `codesign` can't embed profiles in non-bundle binaries, so
/// stripping all entitlements was the fix (an unsandboxed daemon reads
/// `~/Library/Group Containers/...` directly).
///
/// The app generates the LaunchAgent plist at runtime (it knows the correct
/// container + bundle paths), writes it to `~/Library/LaunchAgents/`, and
/// bootstraps it via `launchctl bootstrap`. The daemon survives app quit —
/// launchd manages it independently (KeepAlive + RunAtLoad). Use
/// `restart()` (via the "Restart Daemon" menu item) to pick up a new binary
/// after a rebuild.
final class DaemonLaunchAgentManager {

    /// The launchd label + mach service name. Must match
    /// `WikiDaemonMachServiceName` in `Sources/wikid/main.swift` and
    /// `WikiDaemonConnection.serviceName` in `WikiCtlCore`.
    static let label = "com.selfdrivingwiki.wikid"

    private let containerDirectory: URL

    init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
    }

    // MARK: - Path resolution

    /// The daemon binary in the container directory (dev mode — `make
    /// install-daemon` copies the .build binary here).
    var containerDaemonPath: String {
        containerDirectory.appendingPathComponent("wikid").path
    }

    /// The daemon binary in the app bundle (production —
    /// `Contents/Helpers/wikid`). `nil` when running via `swift run` (no
    /// `.app` bundle), so the shell command falls back to the container path.
    var bundleDaemonPath: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wikid")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// The user's `~/Library/LaunchAgents/` directory.
    var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// The installed plist path (`~/Library/LaunchAgents/com.selfdrivingwiki.wikid.plist`).
    var plistPath: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.label).plist")
    }

    /// The launchd domain target (e.g. `"gui/501"`).
    var domainTarget: String {
        "gui/\(getuid())"
    }

    /// The launchd service target (e.g. `"gui/501/com.selfdrivingwiki.wikid"`).
    var serviceTarget: String {
        "\(domainTarget)/\(Self.label)"
    }

    // MARK: - Plist generation

    /// Build the shell command that finds the daemon binary. Tries the
    /// container path first (dev mode), then the app bundle (production).
    func shellCommand() -> String {
        if let bundlePath = bundleDaemonPath {
            return "exec \"\(containerDaemonPath)\" || exec \"\(bundlePath)\""
        }
        return "exec \"\(containerDaemonPath)\""
    }

    /// Generate the LaunchAgent plist as a dictionary. Pure + testable — no
    /// file I/O or launchctl calls.
    func generatePlistDictionary() -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": ["/bin/zsh", "-c", shellCommand()],
            "MachServices": [Self.label: true],
            "KeepAlive": ["Crashed": true, "SuccessfulExit": false] as [String: Bool],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "EnvironmentVariables": ["WIKI_CONTAINER_DIR": containerDirectory.path]
        ]
    }

    /// Serialize the plist to XML `Data`.
    func generatePlistData() throws -> Data {
        let plist = generatePlistDictionary()
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    // MARK: - launchctl operations

    /// Write the plist to `~/Library/LaunchAgents/` (idempotent — overwrites
    /// any existing plist so the binary paths stay current after a rebuild
    /// or reinstall).
    func installPlist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        let data = try generatePlistData()
        try data.write(to: plistPath, options: .atomic)
    }

    /// Bootstrap the daemon via `launchctl bootstrap`. Idempotent: if the
    /// service is already loaded, `launchctl bootstrap` returns a non-zero
    /// exit code (logged but not fatal — the existing daemon keeps running).
    /// If the plist changed (new binary paths), call `restart()` to pick up
    /// the change.
    func bootstrap() {
        do {
            try installPlist()
        } catch {
            DebugLog.store("wikid: failed to install LaunchAgent plist: \(error)")
        }

        runLaunchctl(["bootstrap", domainTarget, plistPath.path]) { status in
            if status == 0 {
                DebugLog.store("wikid: launchctl bootstrap succeeded")
            } else {
                DebugLog.store("wikid: launchctl bootstrap returned \(status) (already loaded?)")
            }
        }
    }

    /// Restart the daemon via `launchctl kickstart` (kills the running
    /// daemon and starts a fresh one from the installed plist). Used when
    /// the daemon is stale (running an old binary after the app was rebuilt).
    func restart() {
        runLaunchctl(["kickstart", serviceTarget]) { status in
            DebugLog.store("wikid: launchctl kickstart (restart), status=\(status)")
        }
    }

    // MARK: - Private

    private func runLaunchctl(_ arguments: [String], completion: @escaping (Int32) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            completion(process.terminationStatus)
        } catch {
            DebugLog.store("wikid: launchctl \(arguments.first ?? "") failed: \(error)")
        }
    }
}

enum DaemonLaunchAgentError: Error {
    case plistSerializationFailed
}

#endif
