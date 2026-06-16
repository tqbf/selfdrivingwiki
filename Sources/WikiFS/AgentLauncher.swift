import Foundation
import Observation
import WikiFSCore

/// Runs the three `claude -p` operations — Ingest / Query / Lint — against the
/// currently-selected wiki, streaming a live activity feed back into the app
/// (`plans/llm-wiki.md` Phase C). Generalizes the v0 agent launcher: instead of a
/// free-form shell command, it spawns a scoped `claude -p` invocation built by the
/// pure `OperationCommand.build(...)` seam, now with `--output-format stream-json`
/// so the run is visible as it happens instead of silent until the final result.
///
/// Allowed because the app is **un-sandboxed** (`WikiFS/WikiFS.entitlements` — no
/// `com.apple.security.app-sandbox`); a sandboxed app could not `Process`-spawn.
///
/// `@MainActor @Observable`: the view binds `events`, `isRunning`, `exitStatus`,
/// `preflightError`, and `logFileURL`. State is mutated on the main actor from the
/// pipe `readabilityHandler`s — we NEVER block on `waitUntilExit`; completion
/// arrives via `terminationHandler`, which is also where the per-wiki edit lock
/// releases.
@MainActor
@Observable
final class AgentLauncher {
    /// The live, ordered activity feed for the current/last run: typed events parsed
    /// from the stream-json NDJSON. The UI renders these as tool-call rows, prose,
    /// and a final result. Appended on the main actor as lines arrive.
    private(set) var events: [AgentEvent] = []
    /// The raw combined transcript (raw stream-json stdout + stderr) kept alongside
    /// the typed `events`, so the UI / a debugger can see exactly what the CLI
    /// emitted. This is the in-memory mirror of the on-disk `run.jsonl`.
    private(set) var rawTranscript = ""
    /// stderr captured separately (claude's diagnostics): a failed start, a flag
    /// error, an auth prompt. Surfaced prominently in the UI rather than swallowed.
    private(set) var stderr = ""
    /// True while a spawned `claude -p` process is running.
    private(set) var isRunning = false
    /// Exit status of the last finished process, or nil if none finished / one is
    /// running.
    private(set) var exitStatus: Int32?
    /// Set when the PATH preflight fails (claude not resolvable) or the spawn
    /// itself throws; shown in the UI instead of spawning. Cleared on the next
    /// successful run.
    private(set) var preflightError: String?
    /// The kind of the operation currently running (drives the UI title / spinner).
    private(set) var runningKind: WikiOperation.Kind?
    /// The per-run `run.jsonl` backend log on disk (raw stream-json), so the UI can
    /// offer a "Reveal log" affordance. Its sibling `run.stderr.log` holds stderr.
    private(set) var logFileURL: URL?

    /// Builds the login-shell PATH-resolved `claude` path. Injected so tests can
    /// stub it; the app uses the real login-shell preflight.
    @ObservationIgnored var resolveClaude: () -> PathPreflight.Result = {
        PathPreflight.resolveOnLoginShell(executable: "claude")
    }

    private var process: Process?
    /// Carries-over bytes from a stdout read that ended mid-line, so the parser only
    /// ever sees complete NDJSON lines.
    private var stdoutLineBuffer = ""
    /// Append-only handle to the per-run `run.jsonl` (raw stream-json).
    private var logHandle: FileHandle?
    /// Append-only handle to the per-run `run.stderr.log`.
    private var stderrLogHandle: FileHandle?

    /// Run an operation `request` against one wiki. No-op if a process is already
    /// running.
    ///
    /// The launcher OWNS the per-run scratch dir, so it also owns STAGING: it creates
    /// scratch, writes `WIKI_STATE.md` (and, for Ingest, `source.<ext>`) from the
    /// bytes the caller read from SQLite, then finalizes the `WikiOperation` with the
    /// resulting absolute scratch paths so the `-p` prompt points the agent at
    /// reliable local disk — never the ~5s-laggy read-only mount.
    ///
    /// - `request` carries the per-op intent + the source bytes/state text gathered
    ///   at click time.
    /// - `wikiID`/`wikiRoot`/`systemPrompt` come from the active wiki at click time
    ///   (`wikiRoot` resolved from the FP manager — never hardcoded).
    /// - `wikictlDirectory` is the dir holding the embedded `wikictl`
    ///   (`Self Driving Wiki.app/Contents/Helpers`), prepended to the child's PATH so the
    ///   agent's `wikictl` calls resolve.
    /// - `onLock`/`onUnlock` are the edit-lock callbacks: `onLock` fires before the
    ///   spawn, `onUnlock` from the `terminationHandler` (so a killed agent still
    ///   releases). Both run on the main actor.
    func run(
        request: OperationRequest,
        wikiID: String,
        wikiRoot: String,
        systemPrompt: String,
        wikictlDirectory: String,
        onLock: @escaping @MainActor () -> Void,
        onUnlock: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !isRunning else { return }

        // PATH preflight: surface a clear in-UI error instead of a cryptic spawn
        // failure if `claude` isn't on the login-shell PATH.
        let claudeExecutable: String
        switch resolveClaude() {
        case .found(let path):
            claudeExecutable = path
        case .missing(let reason):
            preflightError = reason
            resetRunState()
            return
        }
        preflightError = nil

        guard let scratch = makeScratchDirectory() else {
            preflightError = "Could not create a scratch working directory for the agent."
            return
        }

        // Stage inputs into scratch from reliable local disk, then finalize the
        // operation with the staged absolute paths. A staging failure aborts the run
        // (a run that couldn't stage would fall back to probing the laggy mount).
        let operation: WikiOperation
        do {
            operation = try request.stage(into: scratch)
        } catch {
            preflightError = "Could not stage the agent's inputs: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: scratch)
            return
        }

        let command = OperationCommand.build(
            operation: operation,
            wikiRoot: wikiRoot,
            wikiID: wikiID,
            systemPrompt: systemPrompt,
            scratchDirectory: scratch.path,
            wikictlDirectory: wikictlDirectory,
            claudeExecutable: claudeExecutable
        )

        resetRunState()
        isRunning = true
        runningKind = operation.kind
        openLogFiles(in: scratch)
        onLock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = scratch

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // stdout is line-buffered NDJSON: accumulate bytes, split on newlines, and
        // feed each COMPLETE line to the parser. Non-blocking — the handler fires on
        // a background queue, then hops to the main actor.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.ingestStdout(chunk) }
        }
        // stderr is claude's diagnostics — surfaced separately and prominently.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.ingestStderr(chunk) }
        }

        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.finish(status: status)
                onUnlock()
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            preflightError = "Failed to launch claude: \(error.localizedDescription)"
            closeLogFiles()
            try? FileManager.default.removeItem(at: scratch)
            isRunning = false
            runningKind = nil
            onUnlock()
        }
    }

    /// Terminate the running process, if any. The `terminationHandler` releases the
    /// edit lock and clears `isRunning`.
    func stop() {
        process?.terminate()
    }

    // MARK: - Stream ingestion (main actor)

    /// Append a raw stdout chunk: mirror it to the transcript + `run.jsonl`, then
    /// split into complete lines and feed each to the parser.
    private func ingestStdout(_ chunk: String) {
        rawTranscript.append(chunk)
        writeLog(chunk, to: logHandle)

        stdoutLineBuffer.append(chunk)
        // Split off only the COMPLETE lines; keep any trailing partial in the buffer
        // until its newline arrives so the parser never sees a half line.
        while let newlineIndex = stdoutLineBuffer.firstIndex(of: "\n") {
            let line = String(stdoutLineBuffer[..<newlineIndex])
            stdoutLineBuffer.removeSubrange(...newlineIndex)
            if let event = AgentEventParser.parse(line: line) {
                events.append(event)
            }
        }
    }

    /// Append a raw stderr chunk: surface it in `stderr`, mirror to the transcript +
    /// `run.stderr.log`.
    private func ingestStderr(_ chunk: String) {
        stderr.append(chunk)
        rawTranscript.append(chunk)
        writeLog(chunk, to: stderrLogHandle)
    }

    /// Drain any trailing partial line, record the exit status, and tear down.
    private func finish(status: Int32) {
        if !stdoutLineBuffer.isEmpty {
            if let event = AgentEventParser.parse(line: stdoutLineBuffer) {
                events.append(event)
            }
            stdoutLineBuffer = ""
        }
        closeLogFiles()
        isRunning = false
        exitStatus = status
        runningKind = nil
        process = nil
    }

    /// Clear per-run state at the start of (or on abort before) a run.
    private func resetRunState() {
        events = []
        rawTranscript = ""
        stderr = ""
        stdoutLineBuffer = ""
        exitStatus = nil
        isRunning = false
        runningKind = nil
        logFileURL = nil
    }

    // MARK: - Backend log files

    /// Create `run.jsonl` (raw stream-json) and `run.stderr.log` under the run's
    /// scratch dir and open append handles. Best-effort: if a handle can't open, the
    /// in-memory transcript still works.
    private func openLogFiles(in scratch: URL) {
        let jsonl = scratch.appendingPathComponent("run.jsonl", isDirectory: false)
        let stderrLog = scratch.appendingPathComponent("run.stderr.log", isDirectory: false)
        let manager = FileManager.default
        manager.createFile(atPath: jsonl.path, contents: nil)
        manager.createFile(atPath: stderrLog.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: jsonl)
        stderrLogHandle = try? FileHandle(forWritingTo: stderrLog)
        logFileURL = jsonl
    }

    private func writeLog(_ text: String, to handle: FileHandle?) {
        guard let handle, let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    private func closeLogFiles() {
        try? logHandle?.close()
        try? stderrLogHandle?.close()
        logHandle = nil
        stderrLogHandle = nil
    }

    /// Create a fresh per-run writable scratch dir under the app's Caches (decision
    /// #4 — Claude Code needs a writable cwd; the mount is read-only). The dir also
    /// holds the per-run `run.jsonl` / `run.stderr.log` backend logs, so — unlike
    /// the previous version — we do NOT delete it on termination; it persists for
    /// post-hoc debugging via "Reveal log". Returns nil only if it can't be created.
    private func makeScratchDirectory() -> URL? {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let scratch = base
            .appendingPathComponent("Self Driving Wiki-agent", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            return scratch
        } catch {
            return nil
        }
    }
}
