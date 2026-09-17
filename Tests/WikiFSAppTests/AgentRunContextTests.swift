#if os(macOS)
import Testing
import Foundation
import WikiFSCore
@testable import WikiFSEngine

/// Deterministic tests for the typed per-run capability context
/// (`AgentRunContext`) and its wiring (`plans/sandbox-agent.md` §run-context):
/// PATH assembly, scratch-derived temp roots, protected environment merge
/// order, shell-safe prompt rendering, and the session-cwd preference. All
/// pure — no subprocess, no provider, no real login shell.
@Suite(.timeLimit(.minutes(2)))
struct AgentRunContextTests {

    private func makeContext(
        scratch: URL,
        wikiID: WikiID = WikiID(rawValue: "01WIKI"),
        wikictlDirectory: String = "/Applications/Self Driving Wiki.app/Contents/Helpers",
        userPATH: String = "/usr/local/bin:/usr/bin:/bin",
        stateFilePath: String? = nil,
        stagedSourcePaths: [String] = []
    ) -> AgentRunContext {
        AgentRunContext(
            scratchDirectory: scratch,
            wikiID: wikiID,
            wikictlDirectory: wikictlDirectory,
            userPATH: userPATH,
            stateFilePath: stateFilePath,
            stagedSourcePaths: stagedSourcePaths)
    }

    // MARK: - PATH assembly

    @Test func pathAssemblyIsDeterministicDeduplicatedHelperFirst() {
        let path = AgentRunContext.assemblePATH(
            helperDirectory: "/helpers",
            userPath: "/usr/local/bin:/usr/bin:/helpers:/opt/homebrew/bin:/usr/bin")
        // Helper dir FIRST, first-hit order preserved, duplicates dropped —
        // and no hard-coded zsh shell path anywhere.
        #expect(path == "/helpers:/usr/local/bin:/usr/bin:/opt/homebrew/bin")
    }

    @Test func pathAssemblyDropsEmptySegments() {
        let path = AgentRunContext.assemblePATH(
            helperDirectory: "/helpers", userPath: "::/usr/bin::")
        #expect(path == "/helpers:/usr/bin")
    }

    @Test func effectivePATHPrependsHelperDirectory() {
        let context = makeContext(
            scratch: URL(fileURLWithPath: "/tmp/run"),
            wikictlDirectory: "/app/Helpers",
            userPATH: "/usr/bin:/bin")
        #expect(context.effectivePATH == "/app/Helpers:/usr/bin:/bin")
    }

    // MARK: - Scratch-derived paths

    @Test func tempRootsAreDerivedFromCanonicalScratch() {
        let scratch = URL(fileURLWithPath: "/cache/wiki/runs/2026-01-01T00:00:00.000Z")
        let context = makeContext(scratch: scratch)
        #expect(context.tempDirectory.path == scratch.appendingPathComponent(".tmp").path)
        #expect(
            context.zshTempPrefix.path
                == scratch.appendingPathComponent(".tmp/zsh").path)
        // TMPPREFIX is set defensively for zsh compatibility ONLY — the value
        // lives under scratch; nothing requires or selects zsh.
        #expect(context.protectedEnvironment["TMPPREFIX"]!.hasSuffix(".tmp/zsh"))
    }

    @Test func scratchAndTempEnvironmentValuesAreAbsolute() {
        let context = makeContext(scratch: URL(fileURLWithPath: "/cache/run"))
        let env = context.protectedEnvironment
        #expect(env["WIKI_SCRATCH"] == "/cache/run")
        #expect(env["TMPDIR"] == "/cache/run/.tmp")
        #expect(env["WIKI_DB"] == "01WIKI")
        #expect(env["WIKICTL"] == "/Applications/Self Driving Wiki.app/Contents/Helpers/wikictl")
    }

    // MARK: - Provider merge order (protected keys win)

    @Test func providerEnvironmentCannotOverrideProtectedRunKeys() {
        let context = makeContext(scratch: URL(fileURLWithPath: "/cache/run"))
        let providerEnvironment = [
            // A provider config trying to redirect routing, scratch, PATH,
            // and temp relocation — every one of these MUST lose.
            "WIKI_DB": "01EVIL",
            "WIKICTL": "/tmp/evil/wikictl",
            "WIKI_SCRATCH": "/tmp/evil",
            "PATH": "/tmp/evil/bin",
            "TMPDIR": "/tmp/evil-tmp",
            "TMPPREFIX": "/tmp/evil-tmp/zsh",
            // A benign provider hint that must survive.
            "ACP_PROVIDER_KEY": "abc123",
        ]
        let env = context.environment(
            providerEnvironment: providerEnvironment,
            baseEnvironment: ["HOME": "/users/dev", "PATH": "/usr/bin:/bin"])

        #expect(env["WIKI_DB"] == "01WIKI")
        #expect(env["WIKICTL"] == context.wikictlPath)
        #expect(env["WIKI_SCRATCH"] == "/cache/run")
        #expect(env["PATH"] == context.effectivePATH)
        #expect(env["TMPDIR"] == "/cache/run/.tmp")
        #expect(env["TMPPREFIX"] == "/cache/run/.tmp/zsh")
        #expect(env["ACP_PROVIDER_KEY"] == "abc123", "benign provider env survives")
        #expect(env["HOME"] == "/users/dev", "base env survives")
    }

    // MARK: - Trusted command rendering

    @Test func wikiCommandIsStructuredTypedData() {
        let context = makeContext(scratch: URL(fileURLWithPath: "/cache/run"))
        #expect(
            context.wikiCommand(["source", "list"])
                == [context.wikictlPath, "--wiki", "01WIKI", "source", "list"])
    }

    @Test func renderedCommandQuotesPathsWithSpaces() {
        let context = makeContext(
            scratch: URL(fileURLWithPath: "/cache/run"),
            wikictlDirectory: "/Applications/My Wiki.app/Contents/Helpers")
        let rendered = context.renderedWikiCommand(["source", "cat", "--id", "01ABC"])
        // The helper path contains a space — the rendered form must be a
        // single shell-safe token sequence that survives `/bin/sh`.
        #expect(rendered.contains("'"))
        #expect(rendered.contains("--wiki"))
        #expect(rendered.contains("01WIKI"))
        #expect(!rendered.contains(" /Applications/My Wiki.app"))
    }

    @Test func renderedCommandLineIsExecutableBySh() async throws {
        // End-to-end on the quoting helper itself: a command line rendered
        // from spaced paths runs under /bin/sh and produces the argv.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quote-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spaced = dir.appendingPathComponent("my tool").path
        let script = dir.appendingPathComponent("echo-args.sh").path
        try Data("""
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a"; done
        """.utf8).write(to: URL(fileURLWithPath: script))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script)

        let rendered = ShellQuoting.commandLine(
            executable: script, arguments: [spaced, "plain"])
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", rendered]
        sh.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        sh.standardOutput = pipe
        sh.standardError = Pipe()
        try sh.run()
        // Nonblocking, deadline-bounded wait (see AgentRuntimePathTests).
        let status: Int32
        do {
            status = try await pollUntilExit(sh, timeout: .seconds(30))
        } catch {
            Issue.record("quoting subprocess timed out")
            throw error
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(status == 0)
        // The script prints its ARGUMENTS (argv[0] is the script itself and
        // is not echoed): the spaced path must arrive as ONE argument.
        #expect(output == "\(spaced)\nplain\n")
    }

    /// Cooperative, deadline-bounded subprocess wait for this suite (same
    /// shape as `AgentRuntimePathTests.waitNonblocking` — no continuation to
    /// strand, no parked pool thread).
    private func pollUntilExit(_ process: Process, timeout: Duration) async throws -> Int32 {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                if process.isRunning { process.terminate() }
                struct PollTimeout: Error {}
                throw PollTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return process.terminationStatus
    }

    // MARK: - Prompt injection

    @Test func promptContextSectionCarriesAbsolutePathsAndTrustedInvocation() {
        let context = makeContext(
            scratch: URL(fileURLWithPath: "/cache/runs/run-1"),
            stateFilePath: "/cache/runs/run-1/WIKI_STATE.md",
            stagedSourcePaths: ["/cache/runs/run-1/report--01SRC.pdf"])
        let section = context.promptContextSection()
        #expect(section.contains("/cache/runs/run-1"))
        #expect(section.contains("/cache/runs/run-1/.tmp"))
        #expect(section.contains("/cache/runs/run-1/WIKI_STATE.md"))
        #expect(section.contains("report--01SRC.pdf"))
        // The PREFERRED form is bare wikictl with --wiki before the subcommand
        // (issue: the space in the absolute helper path made unquoted
        // invocations fail with zsh exit 127).
        #expect(section.contains("PREFERRED FORM"))
        #expect(section.contains("`wikictl --wiki 01WIKI <subcommand> …`"))
        #expect(section.contains("no `--wiki=<id>` form"))
        // The trusted absolute invocation remains the guaranteed fallback,
        // rendered shell-safe, with the space-in-path warning.
        #expect(section.contains("GUARANTEED FALLBACK"))
        #expect(section.contains("--wiki 01WIKI"))
        #expect(section.contains(context.wikictlPath))
        #expect(section.contains("contains a SPACE"))
        // Env vars are named as conveniences, not requirements.
        #expect(section.contains("WIKI_DB"))
    }

    // MARK: - Derived fallback context

    @Test func fallbackScratchGetsIndependentTempRoots() {
        let primary = makeContext(scratch: URL(fileURLWithPath: "/cache/run"))
        let fallbackScratch = URL(fileURLWithPath: "/cache/run/fallback-other")
        let derived = primary.withScratch(fallbackScratch)
        #expect(derived.scratchDirectory.path == fallbackScratch.path)
        #expect(derived.tempDirectory.path == fallbackScratch.appendingPathComponent(".tmp").path)
        #expect(derived.wikiID == primary.wikiID)
        #expect(derived.wikictlPath == primary.wikictlPath)
        #expect(derived.effectivePATH == primary.effectivePATH)
    }

    // MARK: - Session cwd preference (ACP wiring)

    @Test func requestedSessionCWDPrefersRunContextScratch() {
        let context = makeContext(scratch: URL(fileURLWithPath: "/cache/canonical"))
        let profile = BackendProfile(
            providerHints: [:],
            scratchDirectory: URL(fileURLWithPath: "/cache/other"),
            runContext: context)
        #expect(ACPBackend.requestedSessionCWD(for: profile) == "/cache/canonical")
    }

    @Test func requestedSessionCWDFallsBackToProfileScratchThenSpawn() {
        let legacy = BackendProfile(scratchDirectory: URL(fileURLWithPath: "/cache/legacy"))
        #expect(ACPBackend.requestedSessionCWD(for: legacy) == "/cache/legacy")

        let hintsOnly = BackendProfile(model: "/usr/local/bin/agent")
        #expect(ACPBackend.requestedSessionCWD(for: hintsOnly) == nil)
    }

    // MARK: - User environment PATH (shell-neutral resolver)

    private static func result(
        _ status: Int32, _ stdout: String
    ) -> AsyncProcessResult {
        AsyncProcessResult(
            terminationStatus: status,
            output: .separate(stdout: Data(stdout.utf8), stderr: Data()))
    }

    @Test func configuredShellPrefersSHELLAbsolutePath() {
        #expect(
            UserEnvironmentPath.configuredShell(environment: ["SHELL": "/bin/bash"])
                == "/bin/bash")
        // A relative SHELL is not executable-by-path, so the resolver falls
        // through to the passwd record — which (when present) names an
        // absolute shell, else nil.
        let fallback = UserEnvironmentPath.configuredShell(environment: ["SHELL": "bash"])
        #expect(fallback == nil || fallback?.hasPrefix("/") == true)
    }

    @Test func loginShellPATHUsesConfiguredShellNotHardcodedZsh() async throws {
        // The injected runner records WHICH shell was invoked — the resolver
        // must run the account's shell (`$SHELL`), never `/bin/zsh`.
        var invokedExecutable: String?
        let runner: (AsyncProcessRequest) async throws -> AsyncProcessResult = { request in
            invokedExecutable = request.executableURL.path
            return Self.result(0, "/opt/homebrew/bin:/usr/bin:/bin")
        }
        let path = await UserEnvironmentPath.loginShellPATH(
            shellPath: "/bin/bash", runProcess: runner)
        #expect(path == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(invokedExecutable == "/bin/bash")
    }

    @Test func loginShellPATHRejectsImplausibleOutput() async {
        // Non-zero exit → nil.
        let failed = await UserEnvironmentPath.loginShellPATH(
            shellPath: "/bin/sh",
            runProcess: { _ in Self.result(1, "anything") })
        #expect(failed == nil)

        // Whitespace (fish list rendering / an error banner) is not a PATH.
        let spaced = await UserEnvironmentPath.loginShellPATH(
            shellPath: "/bin/sh",
            runProcess: { _ in Self.result(0, "/opt/homebrew/bin /usr/bin") })
        #expect(spaced == nil)

        // Empty → nil.
        let empty = await UserEnvironmentPath.loginShellPATH(
            shellPath: "/bin/sh",
            runProcess: { _ in Self.result(0, "  \n") })
        #expect(empty == nil)
    }
}
#endif
