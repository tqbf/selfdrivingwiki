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
    var extractionLog = ""
    /// True while a local `pdf2md` conversion subprocess is running (before the
    /// agent itself starts). Drives the PDF-extraction spinner / Cancel affordance.
    var isExtracting = false
    /// PID of the running `pdf2md` conversion subprocess, surfaced in the UI so a
    /// stuck conversion can be identified (and killed) by the user.
    var extractionPID: Int32?
    /// The ingested-file id currently being operated on — from the moment its
    /// ingest starts (local conversion included) until the agent run ends. Drives
    /// the "Ingesting…" status in `IngestedFileDetailView`. Cleared in `finish()`.
    var ingestingFileID: PageID?
    /// The in-flight ingest operation Task (set by `IngestSheetView`). Cancelling
    /// it aborts a running `pdf2md` conversion (via its task-cancellation handler).
    /// Held here so `stop()` — driven from the transcript sidebar too — can cancel
    /// the conversion phase, not just the agent process. Self-clears when done.
    @ObservationIgnored var ingestTask: Task<Void, Never>?
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
    /// Wall-clock start time for the current/last run. Used by the UI to show a
    /// heartbeat instead of a context-free spinner.
    private(set) var runStartedAt: Date?
    /// Last time stdout/stderr produced bytes, or the run state changed. A live
    /// process with an old `lastActivityAt` is not necessarily dead, but the UI can
    /// name that it is quiet.
    private(set) var lastActivityAt: Date?
    /// The spawned process ID while running, useful context when a run looks quiet.
    private(set) var currentProcessID: Int32?

    /// Builds the login-shell PATH-resolved `claude` path. Injected so tests can
    /// stub it; the app uses the real login-shell preflight.
    @ObservationIgnored var resolveClaude: () -> PathPreflight.Result = {
        PathPreflight.resolveOnLoginShell(executable: "claude")
    }

    private var process: Process?
    /// Backstop poller that reconciles the UI if the process `terminationHandler`
    /// is ever missed (see `startCompletionWatchdog`). Cancelled on teardown.
    private var watchdogTask: Task<Void, Never>?
    /// Carries-over bytes from a stdout read that ended mid-line, so the parser only
    /// ever sees complete NDJSON lines.
    private var stdoutLineBuffer = ""
    /// Append-only handle to the per-run `run.jsonl` (raw stream-json).
    private var logHandle: FileHandle?
    /// Append-only handle to the per-run `run.stderr.log`.
    private var stderrLogHandle: FileHandle?
    /// Writable stdin for an interactive stream-json query session.
    private var inputHandle: FileHandle?
    /// True when the running process is waiting for user turns over stdin.
    private(set) var isInteractiveSession = false

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
        let now = Date()
        isRunning = true
        runningKind = operation.kind
        runStartedAt = now
        lastActivityAt = now
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
            DebugLog.agent("terminationHandler fired: pid=\(proc.processIdentifier) status=\(status)")
            Task { @MainActor [weak self] in
                self?.finish(status: status)
                onUnlock()
            }
        }

        do {
            DebugLog.agent("run: spawning kind=\(operation.kind.rawValue) wikiID=\(wikiID) exe=\(command.executable)")
            try process.run()
            self.process = process
            currentProcessID = process.processIdentifier
            DebugLog.agent("run: spawned pid=\(process.processIdentifier) kind=\(operation.kind.rawValue)")
            startCompletionWatchdog()
        } catch {
            DebugLog.agent("run: spawn FAILED: \(error.localizedDescription)")
            preflightError = "Failed to launch claude: \(error.localizedDescription)"
            closeLogFiles()
            try? FileManager.default.removeItem(at: scratch)
            isRunning = false
            runningKind = nil
            currentProcessID = nil
            lastActivityAt = Date()
            onUnlock()
        }
    }

    /// Poll the spawned process's liveness as a backstop for a missed
    /// `terminationHandler`. The handler is the primary completion signal, but if
    /// it ever fails to fire (or the run hangs), the UI would spin forever with no
    /// way to tell whether the child is alive. This loop logs a heartbeat for
    /// post-hoc analysis and — if the OS reports the process gone while the UI
    /// still thinks it is running — reconciles by calling `finish()` itself.
    private func startCompletionWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.isRunning else { return }
                let alive = self.process?.isRunning ?? false
                let pid = self.currentProcessID ?? -1
                let idle = self.lastActivityAt.map { Date().timeIntervalSince($0) } ?? -1
                DebugLog.agent(
                    "heartbeat pid=\(pid) procAlive=\(alive) isRunning=\(self.isRunning) "
                    + "events=\(self.events.count) idleSec=\(String(format: "%.1f", idle))")
                if let proc = self.process, !proc.isRunning {
                    let status = proc.terminationStatus
                    DebugLog.agent(
                        "watchdog: process exited (status=\(status)) but UI still marked "
                        + "running — terminationHandler was missed; reconciling via finish()")
                    self.finish(status: status)
                    return
                }
            }
        }
    }

    /// Start a stdin-backed query conversation. The first user message is sent
    /// immediately after the process launches; later turns use `sendInteractiveMessage`.
    func startInteractiveQuery(
        firstMessage: String,
        stateMarkdown: String,
        wikiID: String,
        wikiRoot: String,
        systemPrompt: String,
        wikictlDirectory: String,
        onLock: @escaping @MainActor () -> Void,
        onUnlock: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !isRunning else { return }

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

        let stateFilePath: String
        do {
            stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
        } catch {
            preflightError = "Could not stage the agent's inputs: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: scratch)
            return
        }

        let operation = WikiOperation.queryConversation(stateFilePath: stateFilePath)
        let command = OperationCommand.buildInteractiveQuery(
            operation: operation,
            wikiRoot: wikiRoot,
            wikiID: wikiID,
            systemPrompt: systemPrompt,
            scratchDirectory: scratch.path,
            wikictlDirectory: wikictlDirectory,
            claudeExecutable: claudeExecutable
        )

        resetRunState()
        let now = Date()
        isRunning = true
        isInteractiveSession = true
        runningKind = operation.kind
        runStartedAt = now
        lastActivityAt = now
        openLogFiles(in: scratch)
        onLock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = scratch

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.ingestStdout(chunk) }
        }
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
            inputHandle = stdinPipe.fileHandleForWriting
            currentProcessID = process.processIdentifier
            sendInteractiveMessage(firstMessage)
        } catch {
            preflightError = "Failed to launch claude: \(error.localizedDescription)"
            closeLogFiles()
            try? FileManager.default.removeItem(at: scratch)
            isRunning = false
            isInteractiveSession = false
            runningKind = nil
            currentProcessID = nil
            lastActivityAt = Date()
            onUnlock()
        }
    }

    /// Send one user turn to the active interactive query session.
    func sendInteractiveMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, isInteractiveSession, !trimmed.isEmpty else { return }
        guard let line = Self.streamJSONLine(forUserText: trimmed),
              let data = (line + "\n").data(using: .utf8)
        else { return }

        events.append(.userText(trimmed))
        lastActivityAt = Date()
        do {
            try inputHandle?.write(contentsOf: data)
        } catch {
            ingestStderr("Failed to send message to Claude: \(error.localizedDescription)\n")
        }
    }

    /// Terminate the running process, if any, and tear the UI state down
    /// immediately so Cancel is responsive even when the child ignores `SIGTERM`
    /// or its `terminationHandler` is slow/missed. The real handler (if it does
    /// fire) calls `finish()` again, which guards on `isRunning` and no-ops.
    func stop() {
        DebugLog.agent(
            "stop() requested: isRunning=\(isRunning) extracting=\(isExtracting) "
            + "process=\(process != nil) procAlive=\(process?.isRunning ?? false) "
            + "pid=\(currentProcessID ?? -1)")
        // Cancel an in-flight ingest Task first — this aborts a running pdf2md
        // conversion (the agent process may not have started yet during the
        // conversion phase).
        ingestTask?.cancel()
        try? inputHandle?.close()
        inputHandle = nil
        process?.terminate()
        if isRunning {
            finish(status: -1)  // -1 sentinel = user-cancelled / forced teardown
        }
    }

    /// Clear the visible activity feed so a freshly-opened surface (e.g. the ingest
    /// sheet for a different file) doesn't show the previous run's events. No-op
    /// while a run is in flight, so we never wipe a live transcript.
    func resetActivityIfIdle() {
        guard !isRunning && !isExtracting else { return }
        events = []
        rawTranscript = ""
        stderr = ""
        stdoutLineBuffer = ""
        exitStatus = nil
        preflightError = nil
        extractionLog = ""
        extractionPID = nil
    }

    // MARK: - Stream ingestion (main actor)

    /// Append a raw stdout chunk: mirror it to the transcript + `run.jsonl`, then
    /// split into complete lines and feed each to the parser.
    private func ingestStdout(_ chunk: String) {
        lastActivityAt = Date()
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
        lastActivityAt = Date()
        stderr.append(chunk)
        rawTranscript.append(chunk)
        writeLog(chunk, to: stderrLogHandle)
    }

    /// Drain any trailing partial line, record the exit status, and tear down.
    /// Guarded on `isRunning` so it runs EXACTLY ONCE per run: `stop()` and the
    /// watchdog may both race the real `terminationHandler` to call it.
    private func finish(status: Int32) {
        guard isRunning else {
            DebugLog.agent("finish: ignored (already torn down) status=\(status)")
            return
        }
        DebugLog.agent("finish: status=\(status) events=\(events.count)")
        watchdogTask?.cancel()
        watchdogTask = nil
        if !stdoutLineBuffer.isEmpty {
            if let event = AgentEventParser.parse(line: stdoutLineBuffer) {
                events.append(event)
            }
            stdoutLineBuffer = ""
        }
        closeLogFiles()
        isRunning = false
        exitStatus = status
        isInteractiveSession = false
        runningKind = nil
        process = nil
        inputHandle = nil
        currentProcessID = nil
        ingestingFileID = nil
        lastActivityAt = Date()
    }

    /// Clear per-run state at the start of (or on abort before) a run.
    private func resetRunState() {
        watchdogTask?.cancel()
        watchdogTask = nil
        events = []
        rawTranscript = ""
        stderr = ""
        stdoutLineBuffer = ""
        exitStatus = nil
        isRunning = false
        isInteractiveSession = false
        runningKind = nil
        logFileURL = nil
        runStartedAt = nil
        lastActivityAt = nil
        currentProcessID = nil
        inputHandle = nil
    }

    private static func streamJSONLine(forUserText text: String) -> String? {
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": text,
                    ],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        return line
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
