import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

/// Bounded macOS integration tests: each supported shell adapter resolves a
/// real fixture runtime through a temporary shell configuration root, so the
/// answer cannot come from the repository, the developer's real shell
/// configuration, or any tool manager. Fish is optional and runs only when
/// installed.
@Suite("Runtime command locator integration", .serialized, .timeLimit(.minutes(2)))
struct RuntimeCommandLocatorIntegrationTests {
    private static let runtimeName = "wiki-runtime-fixture"

    /// A temporary shell home: `<root>/bin/wiki-runtime-fixture` is a real
    /// executable copy of the managed protocol fixture.
    private struct ShellHome {
        let root: URL
        let bin: URL
        let runtimeURL: URL

        static func make(shellFamily: String) throws -> ShellHome {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "runtime-shell-\(shellFamily)-\(UUID().uuidString)",
                    isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(
                at: bin, withIntermediateDirectories: true)
            let runtimeURL = bin.appendingPathComponent(
                RuntimeCommandLocatorIntegrationTests.runtimeName)
            let bytes = try Data(contentsOf: fixtureExecutable())
            try bytes.write(to: runtimeURL)
            guard chmod(runtimeURL.path, 0o755) == 0 else { throw POSIXError(.EIO) }
            return ShellHome(root: root, bin: bin, runtimeURL: runtimeURL)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func fixtureExecutable() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let candidate = enumerator?.nextObject() as? URL {
            if candidate.lastPathComponent == "ManagedExtractorFixture",
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw IntegrationFailure("ManagedExtractorFixture is missing")
    }

    private struct IntegrationFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func makeLocator(
        shellPath: String,
        environment: [String: String]
    ) -> RuntimeCommandLocator {
        RuntimeCommandLocator(
            accountShell: { AccountShellRecord(shellPath: shellPath) },
            launchShellQuery: RaceFreeShellQuery.launch,
            environmentOverrides: environment,
            probe: RuntimeFileProbe.probe,
            shellStartupTimeout: .seconds(10),
            diagnostics: DebugLogExtractorDiagnosticsSink())
    }

    private func assertResolvedToFixture(
        _ outcome: RuntimeCommandOutcome,
        home: ShellHome
    ) throws -> RuntimeCommandResolution {
        guard case .resolved(let resolution) = outcome else {
            throw IntegrationFailure("expected a resolution, got \(outcome)")
        }
        let expectedCommand = try ExtractorRuntimeName(validating: Self.runtimeName)
        #expect(resolution.command == expectedCommand)
        #expect(resolution.source == .loginShell)
        #expect(resolution.executableURL == home.runtimeURL.standardizedFileURL)
        guard case .identity(let identity) = RuntimeFileProbe.probe(home.runtimeURL) else {
            throw IntegrationFailure("fixture runtime did not probe cleanly")
        }
        #expect(resolution.identity == identity)
        return resolution
    }

    // MARK: - zsh

    /// zsh resolves through its own login + interactive configuration root
    /// (ZDOTDIR), never the developer's real one or the repository.
    @Test func zshResolvesFixtureFromItsOwnConfigurationRoot() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw IntegrationFailure("/bin/zsh is missing")
        }
        let home = try ShellHome.make(shellFamily: "zsh")
        defer { home.cleanup() }
        try Data("export PATH=\"\(home.bin.path):$PATH\"\n".utf8)
            .write(to: home.root.appendingPathComponent(".zshrc"))

        let locator = makeLocator(
            shellPath: "/bin/zsh",
            environment: ["ZDOTDIR": home.root.path])
        let outcome = await locator.locate(
            try ExtractorRuntimeName(validating: Self.runtimeName))
        _ = try assertResolvedToFixture(outcome, home: home)
    }

    // MARK: - bash

    /// bash resolves through a temporary login profile (HOME).
    @Test func bashResolvesFixtureFromItsOwnConfigurationRoot() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/bash") else {
            throw IntegrationFailure("/bin/bash is missing")
        }
        let home = try ShellHome.make(shellFamily: "bash")
        defer { home.cleanup() }
        try Data("export PATH=\"\(home.bin.path):$PATH\"\n".utf8)
            .write(to: home.root.appendingPathComponent(".bash_profile"))

        let locator = makeLocator(
            shellPath: "/bin/bash",
            environment: ["HOME": home.root.path])
        let outcome = await locator.locate(
            try ExtractorRuntimeName(validating: Self.runtimeName))
        _ = try assertResolvedToFixture(outcome, home: home)
    }

    // MARK: - fish (optional)

    private static var fishShellPath: String? {
        for candidate in ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    @Test(
        .disabled(
            if: RuntimeCommandLocatorIntegrationTests.fishShellPath == nil,
            "fish is not installed; exact fish syntax stays covered by unit tests")
    )
    func fishResolvesFixtureFromItsOwnConfigurationRoot() async throws {
        let fishPath = try #require(Self.fishShellPath)
        let home = try ShellHome.make(shellFamily: "fish")
        defer { home.cleanup() }
        let configHome = home.root.appendingPathComponent("config", isDirectory: true)
        let fishConfig = configHome.appendingPathComponent("fish", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fishConfig, withIntermediateDirectories: true)
        try Data("set -gx PATH \"\(home.bin.path)\" $PATH\n".utf8)
            .write(to: fishConfig.appendingPathComponent("config.fish"))

        let locator = makeLocator(
            shellPath: fishPath,
            environment: [
                "HOME": home.root.path,
                "XDG_CONFIG_HOME": configHome.path,
            ])
        let outcome = await locator.locate(
            try ExtractorRuntimeName(validating: Self.runtimeName))
        _ = try assertResolvedToFixture(outcome, home: home)
    }

    // MARK: - AC.10: launch outside the repository

    /// A resolved fixture runtime launches a full managed extraction from an
    /// operation directory outside the repository, with no tool-manager
    /// configuration and no inherited PATH.
    @Test func launchesFixtureOutsideRepositoryConfiguration() async throws {
        let home = try ShellHome.make(shellFamily: "launch")
        defer { home.cleanup() }
        try Data("export PATH=\"\(home.bin.path):$PATH\"\n".utf8)
            .write(to: home.root.appendingPathComponent(".zshrc"))

        let locator = makeLocator(
            shellPath: "/bin/zsh",
            environment: ["ZDOTDIR": home.root.path])
        let resolution = try assertResolvedToFixture(
            await locator.locate(
                try ExtractorRuntimeName(validating: Self.runtimeName)),
            home: home)

        // Build a managed runtime-launch operation rooted OUTSIDE the
        // repository; the executor runs the child with the operation root as
        // its working directory and the retained absolute URL.
        let operationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "runtime-launch-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = operationRoot.appendingPathComponent("package", isDirectory: true)
        let homeRoot = operationRoot.appendingPathComponent("home", isDirectory: true)
        let temporaryRoot = operationRoot.appendingPathComponent("tmp", isDirectory: true)
        let cacheRoot = operationRoot.appendingPathComponent("cache", isDirectory: true)
        let inputURL = operationRoot.appendingPathComponent("input/source.bin")
        let outputURL = operationRoot.appendingPathComponent("output/result.md")
        for directory in [
            packageRoot.appendingPathComponent("bin", isDirectory: true),
            homeRoot, temporaryRoot, cacheRoot,
            inputURL.deletingLastPathComponent(),
            outputURL.deletingLastPathComponent(),
        ] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        try Data("success".utf8).write(to: inputURL)
        let entryBytes = try Data(contentsOf: Self.fixtureExecutable())
        let entryPath = try ExtractorRelativePath(validating: "bin/fixture")
        let entryURL = packageRoot.appendingPathComponent(entryPath.rawValue)
        try entryBytes.write(to: entryURL)
        // A runtime entry point needs no execute permission.
        guard chmod(entryURL.path, 0o400) == 0 else { throw POSIXError(.EIO) }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(operationRoot.standardizedFileURL.path
            .hasPrefix(repositoryRoot.standardizedFileURL.path) == false)

        let manifest = try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.runtime-launch"),
            version: ExtractorPackageVersion(validating: "1.0.0"),
            displayName: "Runtime Launch Fixture",
            protocolRevision: .v1,
            entryPoint: entryPath,
            launch: .runtime(
                command: resolution.command,
                arguments: []),
            registrations: [ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "pdf"),
                displayName: "PDF",
                kinds: [.pdf],
                mimeTypes: [ExtractorMIMEType(validating: "application/pdf")])],
            capabilities: [],
            files: [ExtractorPackageFile(
                path: entryPath,
                digest: ExtractorSHA256.digest(entryBytes))],
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 16 * 1_024,
                maximumDurationMilliseconds: 10_000,
                maximumProgressEventCount: 8))
        let revision = ExtractorPackageRevisionID(
            packageID: manifest.packageID,
            version: manifest.version,
            digest: try manifest.packageDigest())
        let request = try ExtractorProtocolRequest(
            requestID: ExtractorRequestID(),
            protocolRevision: .v1,
            kind: .pdf,
            mimeType: ExtractorMIMEType(validating: "application/pdf"),
            originalFilename: "source.pdf",
            inputPath: ExtractorRelativePath(validating: "input/source.bin"),
            outputPath: ExtractorRelativePath(validating: "output/result.md"),
            deadlineMillisecondsSince1970: Int64(Date().timeIntervalSince1970 * 1_000) + 10_000)
        let operation = ManagedExtractorProcessRequest(
            revision: revision,
            manifest: manifest,
            protocolRequest: request,
            paths: ManagedExtractorProcessPaths(
                operationRoot: operationRoot,
                packageRoot: packageRoot,
                homeRoot: homeRoot,
                temporaryRoot: temporaryRoot,
                privateCacheRoot: cacheRoot),
            runtimeResolution: resolution,
            cancellationGracePeriod: .milliseconds(50))

        let result = try await ManagedExtractorProcessExecutor().execute(operation)

        #expect(result.terminationCause == .exited(code: 0))
        #expect(result.executableURL == resolution.executableURL)
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "# Fixture\n")
    }

    // MARK: - Startup timeout reaps the shell process group

    /// A shell that hangs during startup times out typed, and its process
    /// group is terminated and reaped.
    @Test func startupTimeoutTerminatesAndReapsShellProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-hang-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("shell.pid")
        let zshrc = root.appendingPathComponent(".zshrc")
        try Data("echo $$ > \"\(pidFile.path)\"\nwhile true; do sleep 1; done\n".utf8)
            .write(to: zshrc)

        let locator = RuntimeCommandLocator(
            accountShell: { AccountShellRecord(shellPath: "/bin/zsh") },
            launchShellQuery: RaceFreeShellQuery.launch,
            environmentOverrides: ["ZDOTDIR": root.path],
            probe: RuntimeFileProbe.probe,
            shellStartupTimeout: .seconds(2),
            diagnostics: DebugLogExtractorDiagnosticsSink())

        let outcome = await locator.locate(
            try ExtractorRuntimeName(validating: Self.runtimeName))
        guard case .failed(.loginShellStartupTimeout) = outcome else {
            throw IntegrationFailure("expected loginShellStartupTimeout, got \(outcome)")
        }

        // The shell process group is gone after the timeout.
        let pid = try await waitForPIDFile(pidFile)
        #expect(await shellIsGone(pid))
    }

    private func waitForPIDFile(_ url: URL) async throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if let data = try? Data(contentsOf: url),
               let pid = Int32(String(decoding: data, as: UTF8.self)
                   .trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw IntegrationFailure("shell never wrote its pid file")
    }

    private func shellIsGone(_ rawPID: Int32) async -> Bool {
        guard let pid = ProcessSignalSafety.PositivePID(rawValue: rawPID) else {
            return true
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if ProcessIdentityObservation.observe(processID: pid) == nil { return true }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
        }
        return ProcessIdentityObservation.observe(processID: pid) == nil
    }
}
