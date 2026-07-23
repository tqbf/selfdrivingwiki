#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

/// Tests for `DaemonLaunchAgentManager` — the launchctl-based replacement
/// for SMAppService. Tests the plist generation + path construction (the
/// launchctl execution itself is best-effort and not testable in CI).
struct DaemonLaunchAgentManagerTests {

    private let containerDir = URL(fileURLWithPath: "/tmp/test-container", isDirectory: true)

    private func makeManager(container: URL = URL(fileURLWithPath: "/tmp/test-container", isDirectory: true)) -> DaemonLaunchAgentManager {
        DaemonLaunchAgentManager(containerDirectory: container)
    }

    // MARK: - Plist dictionary structure

    @Test func plistHasCorrectLabel() {
        let dict = makeManager().generatePlistDictionary()
        #expect(dict["Label"] as? String == "com.selfdrivingwiki.wikid")
    }

    @Test func plistHasMachServices() {
        let dict = makeManager().generatePlistDictionary()
        let machServices = dict["MachServices"] as? [String: Bool]
        #expect(machServices?["com.selfdrivingwiki.wikid"] == true)
    }

    @Test func plistHasRunAtLoad() {
        let dict = makeManager().generatePlistDictionary()
        #expect(dict["RunAtLoad"] as? Bool == true)
    }

    @Test func plistHasProcessTypeBackground() {
        let dict = makeManager().generatePlistDictionary()
        #expect(dict["ProcessType"] as? String == "Background")
    }

    @Test func plistHasKeepAlive() {
        let dict = makeManager().generatePlistDictionary()
        let keepAlive = dict["KeepAlive"] as? [String: Bool]
        #expect(keepAlive?["Crashed"] == true)
        #expect(keepAlive?["SuccessfulExit"] == false)
    }

    // MARK: - ProgramArguments (shell wrapper to find the daemon binary)

    @Test func programArgumentsContainsZshShell() {
        let dict = makeManager().generatePlistDictionary()
        let args = dict["ProgramArguments"] as? [String]
        #expect(args?.count == 3)
        #expect(args?[0] == "/bin/zsh")
        #expect(args?[1] == "-c")
    }

    @Test func shellCommandContainsContainerPath() {
        let manager = makeManager()
        let cmd = manager.shellCommand()
        #expect(cmd.contains("/tmp/test-container/wikid"))
        #expect(cmd.hasPrefix("exec "))
    }

    @Test func shellCommandFallsBackToBundlePathWhenAvailable() {
        // In the test environment, Bundle.main is the test runner (not the
        // app bundle), so bundleDaemonPath is typically nil → the command
        // only contains the container path. But if it IS non-nil (running in
        // an .app context), it should contain the "||" fallback.
        let manager = makeManager()
        let cmd = manager.shellCommand()
        if manager.bundleDaemonPath != nil {
            #expect(cmd.contains(" || "))
            #expect(cmd.contains("Contents/Helpers/wikid"))
        } else {
            #expect(!cmd.contains(" || "))
        }
    }

    // MARK: - EnvironmentVariables

    @Test func plistHasWikiContainerDir() {
        let dict = makeManager().generatePlistDictionary()
        let env = dict["EnvironmentVariables"] as? [String: String]
        #expect(env?["WIKI_CONTAINER_DIR"] == "/tmp/test-container")
    }

    // MARK: - Plist serialization

    @Test func plistSerializesToXMLData() throws {
        let manager = makeManager()
        let data = try manager.generatePlistData()
        #expect(!data.isEmpty)

        // Deserialize back to verify it's valid plist XML
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try #require(parsed as? [String: Any])
        #expect(dict["Label"] as? String == "com.selfdrivingwiki.wikid")
        #expect(dict["RunAtLoad"] as? Bool == true)
    }

    // MARK: - Path construction

    @Test func plistPathIsInLaunchAgentsDirectory() {
        let manager = makeManager()
        let path = manager.plistPath.path
        #expect(path.contains("Library/LaunchAgents"))
        #expect(path.hasSuffix("com.selfdrivingwiki.wikid.plist"))
    }

    @Test func domainTargetContainsUID() {
        let manager = makeManager()
        let target = manager.domainTarget
        #expect(target.hasPrefix("gui/"))
        // The UID should be a positive integer
        let uid = Int(target.replacingOccurrences(of: "gui/", with: ""))
        #expect(uid != nil)
        #expect(uid! > 0)
    }

    @Test func serviceTargetContainsLabel() {
        let manager = makeManager()
        let target = manager.serviceTarget
        #expect(target.hasPrefix("gui/"))
        #expect(target.hasSuffix("/com.selfdrivingwiki.wikid"))
    }

    @Test func containerDaemonPathIncludesWikid() {
        let manager = makeManager(container: URL(fileURLWithPath: "/custom/path", isDirectory: true))
        #expect(manager.containerDaemonPath == "/custom/path/wikid")
    }

    // MARK: - Plist install (file I/O)

    @Test func installPlistWritesValidPlistToDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Use a temporary home directory so we don't pollute the real one
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempDir.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
        }

        let manager = makeManager()
        try manager.installPlist()

        // Verify the file exists at the expected path
        let plistPath = manager.plistPath
        #expect(FileManager.default.fileExists(atPath: plistPath.path))

        // Verify it's a valid plist
        let data = try Data(contentsOf: plistPath)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try #require(parsed as? [String: Any])
        #expect(dict["Label"] as? String == "com.selfdrivingwiki.wikid")
    }

    // MARK: - Bootstrap/restart are best-effort (no crash on failure)

    @Test func bootstrapDoesNotCrashInTestEnvironment() {
        // bootstrap() runs launchctl which may fail in CI (no launchd domain
        // for the test runner). It should not crash — errors are logged.
        let manager = makeManager()
        manager.bootstrap()
    }

    @Test func restartDoesNotCrashInTestEnvironment() {
        // restart() runs launchctl kickstart which will fail in CI (the
        // service isn't bootstrapped). It should not crash.
        let manager = makeManager()
        manager.restart()
    }

    @Test func bootoutAndBootstrapDoesNotCrashInTestEnvironment() {
        // bootoutAndBootstrap() runs launchctl bootout + bootstrap which will
        // fail in CI (no launchd domain for the test runner, and the service
        // isn't loaded). It should not crash — errors are logged and ignored.
        let manager = makeManager()
        manager.bootoutAndBootstrap()
    }
}
#endif
