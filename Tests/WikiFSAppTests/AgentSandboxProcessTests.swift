#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFSEngine

/// Live macOS Seatbelt suite (`plans/sandbox-agent.md` §live-sandbox): runs the
/// REAL `/usr/bin/sandbox-exec` profile against scratch/temp/heredoc/runtime
/// scenarios and the trusted absolute `wikictl` CLI — NO LLM provider, no ACP
/// adapter, no File Provider mount, no scratch wrapper binary.
///
/// Policy compliance: every subprocess is waited on via the nonblocking
/// `terminationHandler` + checked-continuation + timeout pattern (never
/// `waitUntilExit`, never `Thread.sleep`, never a semaphore), and the suite is
/// serialized + time-limited. Real Bun/Python smokes are capability-gated —
/// a missing optional runtime records an explicit skip, never a failure.
@Suite("Agent sandbox processes", .serialized, .timeLimit(.minutes(10)))
struct AgentSandboxProcessTests {

    struct SubprocessTimeout: Error {}

    // MARK: - Fixture

    /// A disposable production-shaped world: a temp HOME (so no rule ever
    /// touches the developer's real home), an App Group container with TWO
    /// registered wikis (each seeded with a source + a processed-markdown
    /// chain), and a scratch workspace with the relocated temp roots.
    final class Fixture {
        let root: URL
        let home: URL
        let container: URL
        let scratch: URL
        let queueDatabase: URL
        let wikiA: WikiDescriptor
        let wikiB: WikiDescriptor
        let storeA: GRDBWikiStore
        let storeB: GRDBWikiStore
        let sourceA: SourceSummary
        let headA: SourceMarkdownVersion

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sandbox-suite-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            // wikictl resolves the container under the REAL account home
            // (`homeDirectoryForCurrentUser` does not honor $HOME in the
            // child), so the fixture container is a test-prefixed App Group
            // SIBLING of the developer's real container — never the real one.
            container = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Group Containers", isDirectory: true)
                .appendingPathComponent("group.test.selfdrivingwiki", isDirectory: true)
            scratch = root.appendingPathComponent("scratch", isDirectory: true)
            queueDatabase = container.appendingPathComponent("queue.sqlite", isDirectory: false)
            for dir in [home, container, scratch] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            // The relocated temp roots the launcher pre-creates.
            try FileManager.default.createDirectory(
                at: scratch.appendingPathComponent(".tmp", isDirectory: true),
                withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: scratch.appendingPathComponent(".tmp/zsh", isDirectory: true),
                withIntermediateDirectories: true)

            // Two registered wikis, each with its own DB + seeded chain.
            var mutableA = WikiDescriptor.make(displayName: "Sandbox A")
            var mutableB = WikiDescriptor.make(displayName: "Sandbox B")
            mutableA.lastUsedAt = Date()
            mutableB.lastUsedAt = Date()
            wikiA = mutableA
            wikiB = mutableB
            var registry = WikiRegistry.load(from: container)
            registry.add(wikiA)
            registry.add(wikiB)
            try registry.save(to: container)

            storeA = try GRDBWikiStore(
                databaseURL: container.appendingPathComponent(wikiA.dbFileName, isDirectory: false))
            storeB = try GRDBWikiStore(
                databaseURL: container.appendingPathComponent(wikiB.dbFileName, isDirectory: false))
            sourceA = try storeA.addSource(filename: "transcript.md", data: Data("RAW BYTES v0".utf8))
            _ = try storeA.appendProcessedMarkdown(
                sourceID: sourceA.id, content: "# processed v1", origin: .extraction, note: nil)
            headA = try #require(try storeA.processedMarkdownHead(sourceID: sourceA.id))
        }

        func cleanup() {
            // The fixture container lives under the real Group Containers —
            // remove it explicitly; everything else is under the temp root.
            try? FileManager.default.removeItem(at: container)
            try? FileManager.default.removeItem(at: root)
        }

        /// The production-shaped write-fence invocation for wiki A: writes
        /// allowed ONLY under scratch (+ the wiki-A DB, temp home's .claude,
        /// the Claude temp base, and device aliases). Wiki B is OUTSIDE.
        func sandboxInvocationForWikiA() throws -> SandboxProfile.SandboxInvocation {
            SandboxProfile.invocation(
                homePath: home.path,
                scratchDir: scratch.path,
                wikiDBPath: container.appendingPathComponent(wikiA.dbFileName, isDirectory: false).path,
                queueDBPath: queueDatabase.path)
        }

        /// The child environment an adapter would receive: scratch-relocated
        /// temp paths, minimal PATH — with wiki routing env vars ABSENT. The
        /// App Group id IS set (it routes wikictl to the fixture container —
        /// it is a selector convenience, not a capability).
        func childEnvironment() -> [String: String] {
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            env["WIKI_APP_GROUP_ID"] = "group.test.selfdrivingwiki"
            env["TMPDIR"] = scratch.appendingPathComponent(".tmp").path
            env["TMPPREFIX"] = scratch.appendingPathComponent(".tmp/zsh").path
            env["PATH"] = "/usr/bin:/bin"
            // AC.5: correctness must not depend on these.
            env.removeValue(forKey: "WIKI_DB")
            env.removeValue(forKey: "WIKICTL")
            return env
        }
    }

    // MARK: - Subprocess runner (nonblocking)

    struct ProcessResult {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
        var outputText: String {
            String(decoding: standardOutput, as: UTF8.self)
        }
        var errorText: String {
            String(decoding: standardError, as: UTF8.self)
        }
    }

    private func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration = .seconds(60),
        stdinData: Data? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        if let stdinData {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            // Write stdin from here: the child may exit before consuming it,
            // so writes are best-effort and the pipe is closed promptly.
            try? stdin.fileHandleForWriting.write(contentsOf: stdinData)
            try? stdin.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        let status = try await AgentRuntimePathTests.waitNonblocking(process, timeout: timeout)
        return ProcessResult(
            status: status,
            standardOutput: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            standardError: standardError.fileHandleForReading.readDataToEndOfFile())
    }

    /// Wrap a spawn in the production seatbelt argv shape for wiki A.
    private func runSandboxed(
        _ fixture: Fixture,
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(120),
        stdinData: Data? = nil
    ) async throws -> ProcessResult {
        let invocation = try fixture.sandboxInvocationForWikiA()
        let wrapped = SandboxProfile.wrappedArguments(
            executablePath: executablePath,
            arguments: arguments,
            invocation: invocation)
        return try await run(
            executablePath: SandboxProfile.sandboxExecutablePath,
            arguments: wrapped,
            environment: environment ?? fixture.childEnvironment(),
            timeout: timeout,
            stdinData: stdinData)
    }

    /// The absolute `wikictl` binary produced by the package build.
    private func wikictlPath() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            repositoryRoot.appendingPathComponent(".build/debug/wikictl"),
            repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/wikictl"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        throw WikictlNotFound()
    }

    struct WikictlNotFound: Error {}

    // MARK: - AC.1: the POSIX /bin/sh baseline

    @Test func posixShTransformsInsideScratchAndRejectsOutsideWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let script = """
        printf 'hello world\\n' | tr '[:lower:]' '[:upper:]' > "$SCRATCH/upper.txt"
        cat "$SCRATCH/upper.txt"
        """
        var environment = fixture.childEnvironment()
        environment["SCRATCH"] = fixture.scratch.path
        let result = try await runSandboxed(
            fixture,
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            environment: environment)

        #expect(result.status == 0, "subprocess failed — stderr captured separately")
        #expect(result.outputText == "HELLO WORLD\n")
        let written = try Data(contentsOf: fixture.scratch.appendingPathComponent("upper.txt"))
        #expect(String(decoding: written, as: UTF8.self) == "HELLO WORLD\n")

        // The fence: a write to a path OUTSIDE the allowlist (a sibling of
        // scratch, not matching any allow rule) must fail and leave no file.
        let outside = fixture.root.appendingPathComponent("outside-denied.txt")
        let denyScript = "echo nope > '\(outside.path)'"
        let denied = try await runSandboxed(
            fixture,
            executablePath: "/bin/sh",
            arguments: ["-c", denyScript],
            environment: environment)
        #expect(denied.status != 0, "the outside write must be denied, not silently allowed")
        #expect(!FileManager.default.fileExists(atPath: outside.path),
                "a denied write must not leave an artifact")
    }

    /// Issue #1314: an agent-launched `wikictl extractor sync … --force`
    /// reads the existing source from the active wiki, then persists its
    /// extraction request in the sibling central queue database. Exercise the
    /// same SQLite write under the real Seatbelt profile, entirely inside the
    /// disposable test App Group container.
    @Test func writeProfileAllowsCentralQueueSQLiteInsert() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let queue = try QueueStore(databaseURL: fixture.queueDatabase)
        queue.close()

        var environment = fixture.childEnvironment()
        environment["QUEUE_DB"] = fixture.queueDatabase.path
        let result = try await runSandboxed(
            fixture,
            executablePath: "/usr/bin/sqlite3",
            arguments: [
                fixture.queueDatabase.path,
                "INSERT INTO queue_items "
                    + "(id, queue, wiki_id, payload, state, ordering_key, attempt, created_at) "
                    + "VALUES ('issue-1314', 'extraction', 'test-wiki', "
                    + "'{\"sourceIDs\":[\"01ARZ3NDEKTSV4RRFFQ69G5FAV\"]}', 'queued', 1000, 0, 0);",
            ],
            environment: environment)

        #expect(result.status == 0, "queue INSERT failed: \(result.errorText)")
        let reopened = try QueueStore(databaseURL: fixture.queueDatabase)
        defer { reopened.close() }
        #expect(try reopened.loadActive(for: .extraction).count == 1)
    }

    /// Issue #1314 root-cause control: the PRE-FIX write fence — the production
    /// invocation WITHOUT the queue DB allowance — denies the same central-queue
    /// INSERT, and SQLite surfaces the seatbelt denial as its classic
    /// "attempt to write a readonly database" (SQLITE_READONLY, error 8): the
    /// exact failure the issue reports for `extractor sync --force`. The denial
    /// must also leave no durable row behind (the zero-byte, never-extracted
    /// source the issue describes).
    @Test func profileWithoutQueueAllowanceDeniesCentralQueueSQLiteInsert() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let queue = try QueueStore(databaseURL: fixture.queueDatabase)
        queue.close()

        let invocation = SandboxProfile.invocation(
            homePath: fixture.home.path,
            scratchDir: fixture.scratch.path,
            wikiDBPath: fixture.container.appendingPathComponent(
                fixture.wikiA.dbFileName, isDirectory: false).path)
        let wrapped = SandboxProfile.wrappedArguments(
            executablePath: "/usr/bin/sqlite3",
            arguments: [
                fixture.queueDatabase.path,
                "INSERT INTO queue_items "
                    + "(id, queue, wiki_id, payload, state, ordering_key, attempt, created_at) "
                    + "VALUES ('issue-1314-denied', 'extraction', 'test-wiki', "
                    + "'{\"sourceIDs\":[\"01ARZ3NDEKTSV4RRFFQ69G5FAV\"]}', 'queued', 1000, 0, 0);",
            ],
            invocation: invocation)
        let result = try await run(
            executablePath: SandboxProfile.sandboxExecutablePath,
            arguments: wrapped,
            environment: fixture.childEnvironment())

        #expect(result.status != 0,
                "the queue INSERT must be denied under the pre-fix fence")
        #expect(result.errorText.contains("attempt to write a readonly database"),
                "the denial must surface as SQLITE_READONLY (error 8), got: \(result.errorText)")
        let reopened = try QueueStore(databaseURL: fixture.queueDatabase)
        defer { reopened.close() }
        #expect(try reopened.loadActive(for: .extraction).isEmpty,
                "a denied enqueue must not persist a durable row")
    }

    @Test func posixShellHeredocWorksInsideScratch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        // A heredoc feeds the sandboxed child's STDIN; the child transforms
        // it and writes a file under scratch — the stdin/redirection leg of
        // the sh baseline. (Empirical macOS constraint, verified live: sh and
        // bash stage heredoc TEMP FILES in /tmp regardless of $TMPDIR, so an
        // in-shell heredoc cannot run inside the fence without broadening
        // /tmp — which this profile must never do. The scratch-local heredoc
        // contract is the zsh TMPPREFIX test below; stdin piping is the
        // portable /bin/sh path.)
        let heredoc = "# alpha heading\nbody line\n"
        var environment = fixture.childEnvironment()
        environment["SCRATCH"] = fixture.scratch.path
        let result = try await runSandboxed(
            fixture,
            executablePath: "/bin/sh",
            arguments: ["-c", "sed 's/alpha/beta/' > \"$SCRATCH/heredoc-out.md\"; cat \"$SCRATCH/heredoc-out.md\""],
            environment: environment,
            stdinData: Data(heredoc.utf8))

        #expect(result.status == 0, "subprocess failed — stderr captured separately")
        #expect(!result.errorText.contains("cannot create temp file"))
        #expect(result.outputText == "# beta heading\nbody line\n")
        let written = try Data(contentsOf: fixture.scratch.appendingPathComponent("heredoc-out.md"))
        #expect(String(decoding: written, as: UTF8.self) == "# beta heading\nbody line\n")
    }

    // MARK: - AC.2: zsh TMPPREFIX compatibility (regression-scoped)

    private static let zshInstalled = FileManager.default.isExecutableFile(atPath: "/bin/zsh")

    /// The rbenv-init heredoc shape from chat `01M2EXC4NEDK5WYEMZGFADYXCH`:
    /// zsh keeps its own temp prefix (`/tmp/zsh…` by default — NOT `$TMPDIR`)
    /// for heredocs. With the defensive scratch-local TMPPREFIX, an in-shell
    /// heredoc — including one run inside a command substitution and one that
    /// WRITES A FILE under scratch — succeeds with no temp-file permission
    /// error. Regression compatibility only — zsh is not the product's shell.
    @Test(.enabled(if: AgentSandboxProcessTests.zshInstalled))
    func zshRbenvStyleHeredocUsesScratchTMPPREFIX() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let script = """
        eval "$(cat <<'INIT'
        echo rbenv-init-emitted
        INIT
        )"
        cat <<"OUT" > "$SCRATCH/zsh-heredoc.md"
        # zsh heredoc body
        OUT
        cat "$SCRATCH/zsh-heredoc.md"
        """
        var environment = fixture.childEnvironment()
        environment["SCRATCH"] = fixture.scratch.path
        let result = try await runSandboxed(
            fixture,
            executablePath: "/bin/zsh",
            arguments: ["-f", "-c", script],
            environment: environment)

        #expect(result.status == 0, "subprocess failed — stderr captured separately")
        #expect(!result.errorText.contains("cannot create temp file for here document"),
                "the rbenv-style heredoc must not hit the /tmp/zsh denial (scratch TMPPREFIX is set)")
        #expect(result.outputText.contains("rbenv-init-emitted"))
        #expect(result.outputText.contains("# zsh heredoc body"))
        let written = try Data(contentsOf: fixture.scratch.appendingPathComponent("zsh-heredoc.md"))
        #expect(String(decoding: written, as: UTF8.self) == "# zsh heredoc body\n")
    }

    // MARK: - AC.3: real installed runtimes (capability-gated smokes)

    private static let python3Installed =
        FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

    private static let bunSearchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

    private static var bunInstalled: Bool {
        if case .found = PathPreflight.resolve(
            executable: "bun",
            onPath: bunSearchPath,
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }
        return false
    }

    /// The system Python reads input, performs deterministic text cleanup,
    /// writes the output under scratch, and emits a marker — inside the
    /// production sandbox.
    @Test(.enabled(if: AgentSandboxProcessTests.python3Installed))
    func installedPythonTransformsInsideScratch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("line   one\nline\ttwo\n".utf8).write(
            to: fixture.scratch.appendingPathComponent("input.txt"))

        let script = """
        import re
        with open("\(fixture.scratch.path)/input.txt") as f:
            text = f.read()
        cleaned = re.sub(r"[ \\t]+", " ", text).strip()
        with open("\(fixture.scratch.path)/cleaned.txt", "w") as f:
            f.write(cleaned)
        print("PY-CLEAN-OK")
        """
        let result = try await runSandboxed(
            fixture,
            executablePath: "/usr/bin/python3",
            arguments: ["-c", script])

        #expect(result.status == 0, "subprocess failed — stderr captured separately")
        #expect(result.outputText == "PY-CLEAN-OK\n")
        let cleaned = try Data(contentsOf: fixture.scratch.appendingPathComponent("cleaned.txt"))
        #expect(String(decoding: cleaned, as: UTF8.self) == "line one\nline two")
    }

    /// Bun resolved through an injected search path (the resolved user
    /// environment PATH shape), executing a scratch script. Skipped with a
    /// recorded reason when Bun is not installed — never a false failure.
    @Test(.enabled(if: AgentSandboxProcessTests.bunInstalled))
    func installedBunTransformsInsideScratch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let resolved: String
        switch PathPreflight.resolve(
            executable: "bun",
            usingSearchPath: Self.bunSearchPath) {
        case .found(let path): resolved = path
        case .missing: Issue.record("bun vanished mid-test"); return
        }

        let scriptPath = fixture.scratch.appendingPathComponent("clean.js")
        try Data("""
        const fs = require('fs');
        const text = fs.readFileSync("\(fixture.scratch.path)/input.txt", "utf8");
        fs.writeFileSync("\(fixture.scratch.path)/bun-out.txt", text.toUpperCase());
        console.log("BUN-OK");
        """.utf8).write(to: scriptPath)
        try Data("scratch input\n".utf8).write(
            to: fixture.scratch.appendingPathComponent("input.txt"))

        let result = try await runSandboxed(
            fixture,
            executablePath: resolved,
            arguments: ["run", scriptPath.path])

        #expect(result.status == 0, "subprocess failed — stderr captured separately")
        #expect(result.outputText.contains("BUN-OK"))
        let out = try Data(contentsOf: fixture.scratch.appendingPathComponent("bun-out.txt"))
        #expect(String(decoding: out, as: UTF8.self) == "SCRATCH INPUT\n")
    }

    // MARK: - AC.5: absolute wiki-tool invocation + cross-wiki denial

    /// The absolute `wikictl --wiki <id>` invocation performs a CAS
    /// processed-markdown rewrite from a scratch file with WIKI_DB, WIKICTL,
    /// and PATH removed from the child environment — no scratch wrapper, no
    /// File Provider mount, no ACP agent. Raw bytes + history are then read
    /// back through the store AND the CLI.
    @Test func absoluteWikictlInvocationWorksWithoutAgentEnvironment() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let wikictl = try wikictlPath()

        // The scratch-style body file the agent's script would produce.
        let cleanedPath = fixture.scratch.appendingPathComponent("cleaned.md")
        try Data("# cleaned by scratch script".utf8).write(to: cleanedPath)

        var environment = fixture.childEnvironment()
        environment.removeValue(forKey: "PATH")  // AC.5: PATH absent too.
        let result = try await run(
            executablePath: wikictl,
            arguments: [
                "--wiki", fixture.wikiA.id.rawValue,
                "source", "edit-markdown",
                "--id", fixture.sourceA.id.rawValue,
                "--file", cleanedPath.path,
                "--expect-head", fixture.headA.id.rawValue,
            ],
            environment: environment)

        #expect(result.status == 0, "subprocess failed — stderr captured separately")
        #expect(result.errorText.contains("head_version_id: "),
                "the new head is echoed on stderr like page writes do")

        // Raw bytes are untouched; the chain gained exactly one .user child.
        let raw = try fixture.storeA.sourceContent(id: fixture.sourceA.id)
        #expect(String(decoding: raw, as: UTF8.self) == "RAW BYTES v0")
        let history = try fixture.storeA.processedMarkdownHistory(sourceID: fixture.sourceA.id)
        #expect(history.count == 2)
        #expect(history[0].origin == .user)
        #expect(history[0].content == "# cleaned by scratch script")
        #expect(history[0].parentID == fixture.headA.id)

        // And the read path through the CLI sees the new head too.
        let readBack = try await run(
            executablePath: wikictl,
            arguments: [
                "--wiki", fixture.wikiA.id.rawValue,
                "source", "cat", "--id", fixture.sourceA.id.rawValue, "--markdown",
            ],
            environment: fixture.childEnvironment())
        #expect(readBack.status == 0)
        #expect(readBack.outputText == "# cleaned by scratch script\n")
    }

    /// Targeting wiki B under wiki A's production sandbox must be prevented
    /// by Seatbelt: B's DB is not in the allowlist, so the mutation is denied
    /// and B's data is unchanged.
    @Test func productionSandboxPreventsCrossWikiMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let wikictl = try wikictlPath()

        // Seed wiki B with its own chain (a second wiki's independent data).
        let sourceB = try fixture.storeB.addSource(filename: "b.md", data: Data("B RAW".utf8))
        _ = try fixture.storeB.appendProcessedMarkdown(
            sourceID: sourceB.id, content: "# b v1", origin: .extraction, note: nil)
        let headBBefore = try #require(try fixture.storeB.processedMarkdownHead(sourceID: sourceB.id))

        let cleanedPath = fixture.scratch.appendingPathComponent("cross-wiki.md")
        try Data("# cross-wiki attack\n".utf8).write(to: cleanedPath)

        let result = try await runSandboxed(
            fixture,
            executablePath: wikictl,
            arguments: [
                "--wiki", fixture.wikiB.id.rawValue,
                "source", "edit-markdown",
                "--id", sourceB.id.rawValue,
                "--file", cleanedPath.path,
                "--expect-head", headBBefore.id.rawValue,
            ])

        // Seatbelt (or SQLite's EPERM surface of it) denies the write.
        #expect(result.status != 0,
                "the cross-wiki write must be denied under wiki A's sandbox")
        let headBAfter = try #require(try fixture.storeB.processedMarkdownHead(sourceID: sourceB.id))
        #expect(headBAfter.id == headBBefore.id, "wiki B's head must be unchanged")
        let historyB = try fixture.storeB.processedMarkdownHistory(sourceID: sourceB.id)
        #expect(historyB.count == 1, "no version may be appended to wiki B")
    }

    // MARK: - AC.7 (issue #1276): the extraction-shaped fence, live

    /// The REAL extraction-shaped spawn: a read-only `LLMSandboxScratch` (temp
    /// HOME, staged PDF-like input) wrapped through the SAME production
    /// sandboxed launch-plan helper `ACPExtractionClient.convert` feeds its
    /// backend. The child reads + writes INSIDE the scratch and is DENIED a
    /// write to a sibling path outside it.
    @Test func extractionShapedProcessWritesOnlyInsideScratch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extraction-shape-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("extraction-shape cleanup failed: \(error)") }
        }

        // The scratch world via the production constructor (temp HOME so no
        // rule ever references the developer's real home).
        let scratch = try LLMSandboxScratch.make(
            under: root,
            namePrefix: "wiki-extraction",
            homePath: home.path)

        // Stage a PDF-like input under the scratch (extraction shape: the
        // staged file the prompt hands to the agent).
        let stagedInput = scratch.directoryURL.appendingPathComponent("document.pdf")
        try Data("alpha heading\nalpha body\n".utf8).write(to: stagedInput)

        // The wrapped argv comes from the SHARED production plan helper — this
        // test never wraps a base invocation independently.
        func makePlan(_ script: String) -> ACPBackend.SandboxedSpawnPlan {
            ACPBackend.sandboxedSpawnPlan(
                invocation: scratch.sandbox,
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                environment: ["PATH": "/usr/bin:/bin"],
                scratchDirectory: scratch.directoryURL)
        }
        func runPlan(_ plan: ACPBackend.SandboxedSpawnPlan) async throws -> ProcessResult {
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["PATH"] = "/usr/bin:/bin"
            for (key, value) in plan.environment { environment[key] = value }
            return try await run(
                executablePath: plan.executablePath,
                arguments: plan.arguments,
                environment: environment)
        }

        // IN-SIDE: read the staged input, write the extraction output under
        // the scratch (its relocated TMPDIR is in the effective environment).
        let scratchPath = scratch.directoryURL.path
        let insideScript = """
        sed 's/alpha/beta/' '\(scratchPath)/document.pdf' > '\(scratchPath)/extracted.md'
        cat '\(scratchPath)/extracted.md'
        """
        let inside = try await runPlan(makePlan(insideScript))
        #expect(inside.status == 0, "subprocess failed — stderr: \(inside.errorText)")
        #expect(inside.outputText.contains("beta heading"), "the transform wrote inside the scratch")

        // OUT-SIDE: a write to a SIBLING of the scratch (matching no allow
        // rule) must be denied and leave no artifact — including a wiki-DB-
        // SHAPED file and a global /private/tmp location, both of which the
        // read-only profile must never allow (review LOW #9).
        let outsideDB = root.appendingPathComponent("wiki.sqlite")
        let outsideTmp = "/private/tmp/1276-\(UUID().uuidString)"
        let outsideScript = """
        echo nope > '\(outsideDB.path)'
        echo nope > '\(outsideTmp)'
        """
        let denied = try await runPlan(makePlan(outsideScript))
        #expect(denied.status != 0, "outside-scratch writes must be denied, not silently allowed")
        #expect(!FileManager.default.fileExists(atPath: outsideDB.path),
                "a denied wiki-DB-shaped write must not leave an artifact")
        #expect(!FileManager.default.fileExists(atPath: outsideTmp),
                "a denied global-temp write must not leave an artifact")
    }

    // MARK: - Strict summarizer tier (issue #1276), live

    /// The REAL strict summarizer fence: `LLMSandboxScratch.make(strict: true)`
    /// wrapped through `SandboxProfile.wrappedArguments`. Proves, against the
    /// real `/usr/bin/sandbox-exec`:
    ///
    /// - W^X: a binary planted in the scratch (or its `.tmp` temp root) cannot
    ///   execute — and the SAME plant EXECUTES under the plain read-only
    ///   profile (control: the deny is the strict rule, not the harness).
    /// - A script stored inside the scratch still runs via an outside
    ///   interpreter (scratch stays readable; the adapter's own binary is
    ///   unaffected).
    /// - Named credential reads are denied; benign temp-HOME reads are not.
    /// - The macOS pivots (`open`, `osascript`) are denied.
    /// - Ordinary scratch writes and the installed Python runtime keep
    ///   working.
    @Test func strictSummarizerProfileBlocksPlantedExecCredentialReadsAndPivots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("strict-summarizer-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("strict-summarizer cleanup failed: \(error)") }
        }

        let scratch = try LLMSandboxScratch.make(
            under: root,
            namePrefix: "summarizer",
            homePath: home.path,
            strict: true)
        let plainControl = try LLMSandboxScratch.make(
            under: root,
            namePrefix: "plain-readonly",
            homePath: home.path)

        // A fake credential store, seeded UNSANDBOXED like the real one.
        let sshDir = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try Data("SECRET-KEY-MATERIAL".utf8).write(to: sshDir.appendingPathComponent("id_rsa"))

        func runSandboxed(_ scratchWorld: LLMSandboxScratch, script: String) async throws -> ProcessResult {
            let wrapped = SandboxProfile.wrappedArguments(
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                invocation: scratchWorld.sandbox)
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["PATH"] = "/usr/bin:/bin"
            environment["TMPDIR"] = scratchWorld.tempDirectoryURL.path
            return try await run(
                executablePath: SandboxProfile.sandboxExecutablePath,
                arguments: wrapped,
                environment: environment)
        }

        let scratchPath = scratch.directoryURL.path

        // Plant helper: a freshly-written shebang script (NOT a copy of a
        // trust-cache-signed system binary — AMFI SIGKILLs those copies on
        // macOS 15 regardless of any sandbox, which would make the control
        // meaningless).
        func plantScript(at path: String, marker: String) -> String {
            """
            printf '#!/bin/sh\\necho \(marker)\\n' > '\(path)'
            chmod +x '\(path)'
            '\(path)'
            """
        }

        // L1 (control first): under the PLAIN read-only profile the planted
        // script EXECUTES — proving the harness allows this shape at all.
        let control = try await runSandboxed(
            plainControl,
            script: plantScript(
                at: plainControl.directoryURL.path + "/implant.sh",
                marker: "planted-exec-ok"))
        #expect(control.status == 0 && control.outputText.contains("planted-exec-ok"),
                "control: the plain read-only profile must allow the planted exec (stderr: \(control.errorText))")

        // L1: the same plant under STRICT is denied.
        let planted = try await runSandboxed(
            scratch,
            script: plantScript(at: scratchPath + "/implant.sh", marker: "pwned"))
        #expect(planted.status != 0, "a scratch-planted binary must not execute under strict")
        #expect(!planted.outputText.contains("pwned"))

        // L6: the relocated TMPDIR leaf inside the scratch is covered too.
        let tmpPlanted = try await runSandboxed(
            scratch,
            script: plantScript(at: scratchPath + "/.tmp/implant.sh", marker: "pwned"))
        #expect(tmpPlanted.status != 0, "the relocated TMPDIR leaf must not be an exec hole")

        // L2: an outside binary executes; a scratch-stored SCRIPT is still
        // readable and runs through the outside interpreter.
        let outsideScript = "/bin/echo outside-ok"
        let outside = try await runSandboxed(scratch, script: outsideScript)
        #expect(outside.status == 0 && outside.outputText.contains("outside-ok"),
                "strict must not brick the child's own exec (stderr: \(outside.errorText))")
        let scriptInScratch = scratch.directoryURL.appendingPathComponent("task.sh")
        try Data("#!/bin/sh\necho script-ok\n".utf8).write(to: scriptInScratch)
        let viaInterpreter = try await runSandboxed(
            scratch, script: "/bin/sh '\(scratchPath)/task.sh'")
        #expect(viaInterpreter.status == 0 && viaInterpreter.outputText.contains("script-ok"),
                "scratch stays READABLE — scripts run via outside interpreters (stderr: \(viaInterpreter.errorText))")

        // L3: the named credential read is denied…
        let credentialScript = "cat '\(home.path)/.ssh/id_rsa'"
        let credential = try await runSandboxed(scratch, script: credentialScript)
        #expect(credential.status != 0, "the .ssh read must be denied under strict")
        #expect(!credential.outputText.contains("SECRET-KEY-MATERIAL"))
        // …while a benign temp-HOME read is not (no blanket HOME deny). The
        // probe file sits in the HOME root — `ls .ssh` would match the .ssh
        // subpath deny itself.
        try Data("benign".utf8).write(to: home.appendingPathComponent("notes.txt"))
        let benign = try await runSandboxed(scratch, script: "cat '\(home.path)/notes.txt'")
        #expect(benign.status == 0 && benign.outputText.contains("benign"),
                "strict must not be a blanket HOME read deny")

        // L5: the macOS pivots are denied.
        let openScript = "/usr/bin/open -a 'Finder'"
        let openAttempt = try await runSandboxed(scratch, script: openScript)
        #expect(openAttempt.status != 0, "`open` is a launchd-spawn escape and must be denied")
        let osascriptScript = "/usr/bin/osascript -e 'return 1'"
        let osascriptAttempt = try await runSandboxed(scratch, script: osascriptScript)
        #expect(osascriptAttempt.status != 0, "osascript must be denied under strict")

        // L4: ordinary scratch writes keep working.
        let writeScript = "echo ok > '\(scratchPath)/out.txt'"
        let write = try await runSandboxed(scratch, script: writeScript)
        #expect(write.status == 0, "scratch writes must keep working (stderr: \(write.errorText))")
        #expect(FileManager.default.fileExists(atPath: scratchPath + "/out.txt"))

        // L9: the installed Python interpreter is unaffected (capability-gated).
        if Self.python3Installed {
            let python = try await runSandboxed(scratch, script: "/usr/bin/python3 -c 'print(\"PY-OK\")'")
            #expect(python.status == 0 && python.outputText.contains("PY-OK"),
                    "the system interpreter must keep working under strict (stderr: \(python.errorText))")
        }
    }

    // MARK: - Issue #1279: the package-runner temp exception under the REAL sandbox

    /// AC.2 (live): an effective `bun x` summarizer launch stages + executes
    /// the adapter under its OWNED temp root (`~/.bun/wikifs-tmp/<uuid>`).
    /// The strict profile keeps that root writable (the `.bun` runner-home
    /// exception) and NOT exec-denied, so bun's exact pattern — write a
    /// launcher file into `$TMPDIR`, chmod +x, exec it — works. The lease is
    /// allocated through the production `PackageRunnerTempLease`.
    @Test func strictBunRunnerCanExecuteFromOwnedTemp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("strict-bun-runner-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("strict-bun-runner cleanup failed: \(error)") }
        }

        let scratch = try LLMSandboxScratch.make(
            under: root,
            namePrefix: "summarizer",
            homePath: home.path,
            strict: true)
        // The PRODUCTION home mapping for a bun x launch — the live test
        // consumes the same derivation `ACPBackend.sandboxedSpawnPlan` uses.
        let subpaths = ACPBackend.providerHomeSubpaths(
            executablePath: "/resolved/bun",
            arguments: ["x", "@agentclientprotocol/claude-agent-acp"])
        #expect(subpaths == [".bun"])
        let invocation = SandboxProfile.invocation(scratch.sandbox, addingHomeSubpaths: subpaths)

        // The production lease allocation, anchored at the fixture home so
        // the developer's real `.bun` is never touched.
        let lease = try PackageRunnerTempLease.make(
            parent: home.appendingPathComponent(".bun/wikifs-tmp", isDirectory: true))
        defer { lease.remove() }

        let script = """
        printf '#!/bin/sh\\necho staged-exec-ok\\n' > "$TMPDIR/staged-launcher.sh"
        chmod +x "$TMPDIR/staged-launcher.sh"
        "$TMPDIR/staged-launcher.sh"
        """
        let wrapped = SandboxProfile.wrappedArguments(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            invocation: invocation)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = "/usr/bin:/bin"
        environment["TMPDIR"] = lease.directoryURL.path
        let result = try await run(
            executablePath: SandboxProfile.sandboxExecutablePath,
            arguments: wrapped,
            environment: environment)
        #expect(result.status == 0 && result.outputText.contains("staged-exec-ok"),
                "an effective bun x launch must execute from its owned staging lease (status \(result.status), stderr: \(result.errorText))")
    }

    /// AC.1 (live): the package-runner lease does NOT open scratch
    /// execution. Even with `TMPDIR` pointed at the owned lease, a freshly
    /// written executable under the scratch, under `scratch/.tmp`, or under
    /// global temp stays DENIED, and writes outside the scratch and the
    /// allowed runner homes stay denied. The strict trailer is unchanged.
    @Test func strictPackageRunnerTempDoesNotOpenScratchExecution() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("strict-lease-fence-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("strict-lease-fence cleanup failed: \(error)") }
        }

        let scratch = try LLMSandboxScratch.make(
            under: root,
            namePrefix: "summarizer",
            homePath: home.path,
            strict: true)
        let invocation = SandboxProfile.invocation(
            scratch.sandbox,
            addingHomeSubpaths: ACPBackend.providerHomeSubpaths(
                executablePath: "/resolved/bun",
                arguments: ["x", "@agentclientprotocol/claude-agent-acp"]))
        let lease = try PackageRunnerTempLease.make(
            parent: home.appendingPathComponent(".bun/wikifs-tmp", isDirectory: true))
        defer { lease.remove() }

        func runSandboxed(_ script: String) async throws -> ProcessResult {
            let wrapped = SandboxProfile.wrappedArguments(
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                invocation: invocation)
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["PATH"] = "/usr/bin:/bin"
            environment["TMPDIR"] = lease.directoryURL.path
            return try await run(
                executablePath: SandboxProfile.sandboxExecutablePath,
                arguments: wrapped,
                environment: environment)
        }
        // Freshly-written shebang scripts (never copies of trust-cache
        // binaries — AMFI kills those regardless of any sandbox).
        func plantScript(at path: String, marker: String) -> String {
            """
            printf '#!/bin/sh\\necho \(marker)\\n' > '\(path)'
            chmod +x '\(path)'
            '\(path)'
            """
        }

        let scratchPath = scratch.directoryURL.path

        // (a) A planted executable under the scratch stays denied.
        let scratchPlant = try await runSandboxed(
            plantScript(at: scratchPath + "/implant.sh", marker: "pwned"))
        #expect(scratchPlant.status != 0, "scratch execution must stay denied with a lease in play")
        #expect(!scratchPlant.outputText.contains("pwned"))

        // (b) The scratch `.tmp` leaf — no longer the child's TMPDIR — stays
        // an exec hole closed.
        let tmpLeafPlant = try await runSandboxed(
            plantScript(at: scratchPath + "/.tmp/implant.sh", marker: "pwned"))
        #expect(tmpLeafPlant.status != 0, "scratch/.tmp execution must stay denied")
        #expect(!tmpLeafPlant.outputText.contains("pwned"))

        // (c) An executable under GLOBAL temp (planted unsandboxed under the
        // canonical /private/tmp) stays denied — the strict trailer's
        // /private/tmp exec deny is unchanged by the lease.
        let globalPlant = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("strict-lease-1279-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\necho pwned\n".utf8).write(to: globalPlant)
        #expect(chmod(globalPlant.path, 0o755) == 0)
        defer {
            do { try FileManager.default.removeItem(at: globalPlant) }
            catch { Issue.record("global-temp plant cleanup failed: \(error)") }
        }
        let globalExec = try await runSandboxed("'\(globalPlant.path)'")
        #expect(globalExec.status != 0, "global-temp execution must stay denied")
        #expect(!globalExec.outputText.contains("pwned"))

        // (d) Writes outside the scratch and the allowed runner homes stay
        // denied — the HOME root gains nothing from the lease.
        let outsideWrite = try await runSandboxed("echo x > '\(home.path)/escape.txt'")
        #expect(outsideWrite.status != 0, "a HOME-root write must stay denied")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("escape.txt").path))

        // (e) The exception is real but bounded: the Bun staging home stays
        // writable (that is what makes bun x work), and the lease itself can
        // hold written files.
        let leaseWrite = try await runSandboxed(
            "echo staged > '\(lease.directoryURL.path)/staged.txt'")
        #expect(leaseWrite.status == 0,
                "the owned staging lease stays writable (stderr: \(leaseWrite.errorText))")
        #expect(FileManager.default.fileExists(atPath: lease.directoryURL.appendingPathComponent("staged.txt").path))
    }
}
#endif
