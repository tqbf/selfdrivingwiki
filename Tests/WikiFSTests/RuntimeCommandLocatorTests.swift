import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

/// Unit tests for the login-shell runtime locator with injected account
/// records, shell queries, probes, and diagnostics. Real-shell behavior is
/// covered by `RuntimeCommandLocatorIntegrationTests`.
@Suite("Runtime command locator")
struct RuntimeCommandLocatorTests {
    // MARK: - Test doubles

    /// Records every shell query and answers with a queued result.
    final class ShellQueryRecorder: @unchecked Sendable {
        struct Call {
            let executableURL: URL
            let arguments: [String]
            let environment: [String: String]
            let timeout: Duration
        }

        private let lock = NSLock()
        private var recordedCalls: [Call] = []
        private var result: Result<ShellQueryOutcome, Error>

        init(result: Result<ShellQueryOutcome, Error>) {
            self.result = result
        }

        var calls: [Call] { lock.withLock { recordedCalls } }

        func launch(
            executableURL: URL,
            arguments: [String],
            environmentOverrides: [String: String],
            timeout: Duration
        ) async throws -> ShellQueryOutcome {
            lock.withLock {
                recordedCalls.append(Call(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environmentOverrides,
                    timeout: timeout))
            }
            switch lock.withLock({ result }) {
            case .success(let outcome): return outcome
            case .failure(let error): throw error
            }
        }

        /// The recorded arguments of the first call.
        var firstArguments: [String] { calls.first?.arguments ?? [] }
    }

    /// Captures diagnostic lines in memory.
    final class RecordingDiagnostics: ExtractorDiagnosticsSink, @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func send(_ line: String) {
            lock.withLock { lines.append(line) }
        }

        var recordedLines: [String] { lock.withLock { lines } }
    }

    private func makeLocator(
        shell: String? = "/bin/zsh",
        queryResult: Result<ShellQueryOutcome, Error> = .success(ShellQueryOutcome(
            terminationCause: .exited(code: 0),
            stdout: Data("/usr/local/bin/bun\n".utf8),
            stderr: Data())),
        probe: @escaping @Sendable (URL) -> RuntimeExecutableProbeOutcome = { _ in
            .identity(RuntimeExecutableIdentity(
                device: 1, inode: 2, mode: 0o100755, size: 3))
        },
        environment: [String: String] = [:],
        timeout: Duration = RuntimeResolutionLimits.shellStartupTimeout,
        diagnostics: RecordingDiagnostics = RecordingDiagnostics()
    ) -> (RuntimeCommandLocator, ShellQueryRecorder, RecordingDiagnostics) {
        let recorder = ShellQueryRecorder(result: queryResult)
        let locator = RuntimeCommandLocator(
            accountShell: {
                shell.map { AccountShellRecord(shellPath: $0) }
            },
            launchShellQuery: recorder.launch,
            environmentOverrides: environment,
            probe: probe,
            shellStartupTimeout: timeout,
            diagnostics: diagnostics)
        return (locator, recorder, diagnostics)
    }

    private static let bun = try! ExtractorRuntimeName(validating: "bun")

    // MARK: - Success

    /// AC.1: the configured login shell's single absolute answer becomes the
    /// retained resolution, with pinned identity and safe description.
    @Test func resolvesConfiguredLoginShellAbsoluteExecutable() async throws {
        let diagnostics = RecordingDiagnostics()
        let probeIdentity = RuntimeExecutableIdentity(
            device: 17, inode: 34, mode: 0o100755, size: 128)
        let (locator, recorder, sink) = makeLocator(
            probe: { _ in .identity(probeIdentity) },
            diagnostics: diagnostics)

        let outcome = await locator.locate(Self.bun)

        guard case .resolved(let resolution) = outcome else {
            Issue.record("expected a resolved outcome, got \(outcome)")
            return
        }
        #expect(resolution.command == Self.bun)
        #expect(resolution.source == .loginShell)
        #expect(resolution.executableURL == URL(fileURLWithPath: "/usr/local/bin/bun"))
        #expect(resolution.identity == probeIdentity)
        #expect(resolution.description.basename == "bun")
        // The shell was launched as the account's login shell.
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.executableURL == URL(fileURLWithPath: "/bin/zsh"))
        // One safe resolution event with command, source, path, identity.
        #expect(sink.recordedLines.count == 1)
        #expect(sink.recordedLines[0].hasPrefix("runtime resolved: command=bun source=login-shell path="))
        #expect(sink.recordedLines[0].contains("identity=dev:17-ino:34"))
    }

    /// The shell path is launched exactly; the query inherits the host
    /// environment plus the locator's overrides.
    @Test func shellQueryReceivesEnvironmentOverridesAndTimeout() async throws {
        let (locator, recorder, _) = makeLocator(
            shell: "/bin/bash",
            environment: ["ZDOTDIR": "/tmp/fixture-zdotdir"],
            timeout: .seconds(3))

        _ = await locator.locate(Self.bun)

        let call = try #require(recorder.calls.first)
        #expect(call.environment["ZDOTDIR"] == "/tmp/fixture-zdotdir")
        #expect(call.timeout == .seconds(3))
    }

    // MARK: - Account record and shell family

    @Test func missingAccountRecordFailsTyped() async throws {
        let (locator, _, sink) = makeLocator(shell: nil)
        let outcome = await locator.locate(Self.bun)
        guard case .failed(.accountShellUnavailable) = outcome else {
            Issue.record("expected accountShellUnavailable, got \(outcome)")
            return
        }
        #expect(sink.recordedLines == ["runtime resolution failed: command=bun category=account-shell detail=no usable account shell record"])
    }

    @Test func nonAbsoluteAccountShellFailsTyped() async throws {
        let (locator, _, _) = makeLocator(shell: "zsh")
        let outcome = await locator.locate(Self.bun)
        guard case .failed(.accountShellUnavailable) = outcome else {
            Issue.record("expected accountShellUnavailable, got \(outcome)")
            return
        }
    }

    @Test func unsupportedShellFamilyFailsTyped() async throws {
        let (locator, _, sink) = makeLocator(shell: "/usr/bin/tcsh")
        let outcome = await locator.locate(Self.bun)
        guard case .failed(.unsupportedShellFamily(shellName: "tcsh")) = outcome else {
            Issue.record("expected unsupportedShellFamily, got \(outcome)")
            return
        }
        #expect(sink.recordedLines[0].contains("category=unsupported-shell"))
        #expect(sink.recordedLines[0].contains("tcsh"))
    }

    // MARK: - Shell process outcomes

    @Test func commandAbsenceMapsToTypedFailure() async throws {
        for exitCode: Int32 in [1, 127] {
            let (locator, _, sink) = makeLocator(queryResult: .success(ShellQueryOutcome(
                terminationCause: .exited(code: exitCode),
                stdout: Data(),
                stderr: Data("zsh: no job control in this shell\n".utf8))))
            let outcome = await locator.locate(Self.bun)
            guard case .failed(.commandAbsent) = outcome else {
                Issue.record("expected commandAbsent for exit \(exitCode), got \(outcome)")
                continue
            }
            #expect(sink.recordedLines[0].contains("category=absent"))
        }
    }

    @Test func realShellErrorMapsToNonzeroExitWithBoundedTail() async throws {
        let longStderr = String(repeating: "explosion\n", count: 500)
        let (locator, _, sink) = makeLocator(queryResult: .success(ShellQueryOutcome(
            terminationCause: .exited(code: 3),
            stdout: Data(),
            stderr: Data(longStderr.utf8))))
        let outcome = await locator.locate(Self.bun)
        guard case .failed(.loginShellNonzeroExit(exitCode: 3, let stderrTail)) = outcome else {
            Issue.record("expected loginShellNonzeroExit, got \(outcome)")
            return
        }
        #expect(stderrTail.count <= RuntimeResolutionLimits.maximumStderrTailLength)
        #expect(stderrTail.contains("\n") == false)
        #expect(sink.recordedLines[0].contains("category=exit"))
    }

    @Test func shellLaunchFailureMapsTyped() async throws {
        let (locator, _, sink) = makeLocator(queryResult: .failure(
            RaceFreeProcessGroupError.spawnFailure(13)))
        let outcome = await locator.locate(Self.bun)
        guard case .failed(.loginShellLaunchFailure) = outcome else {
            Issue.record("expected loginShellLaunchFailure, got \(outcome)")
            return
        }
        #expect(sink.recordedLines[0].contains("category=launch"))
    }

    @Test func shellStartupTimeoutMapsTyped() async throws {
        let (locator, _, sink) = makeLocator(queryResult: .failure(
            RaceFreeProcessGroupError.timedOut))
        let outcome = await locator.locate(Self.bun)
        guard case .failed(.loginShellStartupTimeout) = outcome else {
            Issue.record("expected loginShellStartupTimeout, got \(outcome)")
            return
        }
        #expect(sink.recordedLines[0].contains("category=timeout"))
    }

    // MARK: - Shell stdout classification

    @Test func invalidShellOutputVariantsAreTyped() async throws {
        let cases: [(Data, RuntimeCommandResolutionFailure.ShellOutputInvalidity)] = [
            (Data(), .emptyOutput),
            (Data("\n".utf8), .emptyOutput),
            (Data("   \n".utf8), .emptyOutput),
            (Data("/a/b\n/c/d\n".utf8), .multipleLines(lineCount: 2)),
            (Data("/a/b\0c\n".utf8), .notAPath),
            (Data("relative/path\n".utf8), .relativePath),
            (Data("bun: aliased to /usr/local/bin/bun\n".utf8), .relativePath),
            (Data("welcome to the shell\n".utf8), .notAPath),
        ]
        for (stdout, expected) in cases {
            let (locator, _, sink) = makeLocator(queryResult: .success(ShellQueryOutcome(
                terminationCause: .exited(code: 0),
                stdout: stdout,
                stderr: Data())))
            let outcome = await locator.locate(Self.bun)
            guard case .failed(.invalidShellOutput(let invalidity)) = outcome, invalidity == expected else {
                Issue.record("expected invalidShellOutput(\(expected)) for \(String(decoding: stdout, as: UTF8.self)), got \(outcome)")
                continue
            }
            #expect(sink.recordedLines[0].contains("category=invalid-output"))
            #expect(sink.recordedLines[0].contains("unexpected shell startup output"))
        }
    }

    // MARK: - Executable target

    @Test func unusableExecutableVariantsAreTyped() async throws {
        let reasons: [RuntimeCommandResolutionFailure.UnusableExecutableReason] = [
            .probeFailed, .notRegularFile, .multipleLinks, .notExecutable,
        ]
        for reason in reasons {
            let (locator, _, sink) = makeLocator(probe: { _ in .unusable(reason) })
            let outcome = await locator.locate(Self.bun)
            guard case .failed(.unusableExecutable(reason)) = outcome else {
                Issue.record("expected unusableExecutable(\(reason)), got \(outcome)")
                continue
            }
            #expect(sink.recordedLines[0].contains("category=unusable-executable"))
        }
    }

    /// The real file probe follows a symlink to a regular host tool: a
    /// tool-manager shim is a link, and the launch URL stays the link path.
    @Test func realProbeFollowsSymlinkToRegularHostTool() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let realTool = root.appendingPathComponent("real-bun")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: realTool)
        guard chmod(realTool.path, 0o755) == 0 else { throw POSIXError(.EIO) }
        let shim = root.appendingPathComponent("bun")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: realTool)

        let (locator, _, _) = makeLocator(
            queryResult: .success(ShellQueryOutcome(
                terminationCause: .exited(code: 0),
                stdout: Data(shim.path.utf8 + Data("\n".utf8)),
                stderr: Data())),
            probe: RuntimeFileProbe.probe)

        let outcome = await locator.locate(Self.bun)
        guard case .resolved(let resolution) = outcome else {
            Issue.record("expected a resolved symlink target, got \(outcome)")
            return
        }
        // The launch URL is the shim path exactly as the shell reported it.
        #expect(resolution.executableURL == shim.standardizedFileURL)
        guard case .identity(let directIdentity) = RuntimeFileProbe.probe(realTool) else {
            Issue.record("expected the real tool to probe as an identity")
            return
        }
        #expect(resolution.identity == directIdentity)
    }

    /// The real file probe rejects a hard-linked host tool (single-link rule).
    @Test func realProbeRejectsHardLinkedTool() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = root.appendingPathComponent("bun")
        let hardLink = root.appendingPathComponent("bun-link")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        guard chmod(tool.path, 0o755) == 0,
              link(tool.path, hardLink.path) == 0 else { throw POSIXError(.EIO) }

        #expect(RuntimeFileProbe.probe(tool) == .unusable(.multipleLinks))
    }

    // MARK: - Adapter argument vectors

    /// Plan step 33: every adapter's exact argument vector and positional
    /// convention, including runtime names with every manifest-allowed
    /// punctuation character. The name is always a positional argument and
    /// never part of the shell command source.
    @Test func adapterArgumentVectorsArePinned() async throws {
        let punctuation = try ExtractorRuntimeName(validating: "tool-v1.2_beta+3")
        let expectations: [(shell: String, arguments: [String])] = [
            ("/bin/zsh", [
                "-lic",
                #"whence -p -- "$1""#,
                LoginShellFamily.positionalPlaceholder,
                punctuation.rawValue]),
            ("/bin/bash", [
                "-lic",
                #"type -P -- "$1""#,
                LoginShellFamily.positionalPlaceholder,
                punctuation.rawValue]),
            ("/opt/homebrew/bin/fish", [
                "-lic",
                "command -v $argv[1]",
                punctuation.rawValue]),
        ]
        for (shellPath, expected) in expectations {
            let (locator, recorder, _) = makeLocator(shell: shellPath)
            _ = await locator.locate(punctuation)
            let arguments = recorder.firstArguments
            #expect(arguments == expected, "unexpected arguments for \(shellPath): \(arguments)")
            // The runtime name is never inside the command source.
            let commandSource = try #require(arguments.dropFirst().first)
            #expect(commandSource.contains(punctuation.rawValue) == false)
            #expect(arguments.last == punctuation.rawValue)
        }
    }

    /// A versioned zsh basename still selects the zsh adapter.
    @Test func versionedShellBasenameSelectsFamily() throws {
        #expect(LoginShellFamily(shellPath: "/usr/local/bin/zsh-5.9") == .zsh)
        #expect(LoginShellFamily(shellPath: "/bin/bash") == .bash)
        #expect(LoginShellFamily(shellPath: "/opt/homebrew/bin/fish") == .fish)
        #expect(LoginShellFamily(shellPath: "/bin/sh") == nil)
    }

    // MARK: - Single-output-line classification

    @Test func singleOutputLineClassification() {
        typealias Invalidity = RuntimeCommandResolutionFailure.ShellOutputInvalidity
        let cases: [(String, Invalidity?)] = [
            ("/usr/local/bin/bun\n", nil),
            ("/usr/local/bin/bun", nil),
            ("", .emptyOutput),
            ("two\nlines", .multipleLines(lineCount: 2)),
        ]
        for (raw, expected) in cases {
            let result = RuntimeCommandLocator.singleOutputLine(Data(raw.utf8))
            switch (result, expected) {
            case (.success(let line), .none):
                #expect(line.hasPrefix("/") && line.contains("\n") == false)
            case (.failure(let invalidity), .some(let expected)):
                #expect(invalidity == expected, "expected \(expected) for \(raw.debugDescription)")
            default:
                Issue.record("unexpected classification for \(raw.debugDescription)")
            }
        }
    }
}
