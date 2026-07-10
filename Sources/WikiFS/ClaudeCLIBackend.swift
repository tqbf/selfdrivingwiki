import Foundation
import os
import WikiFSCore

/// The Claude-CLI stream-json backend — wraps today's spawn/parse/encode
/// **verbatim** behind the `AgentBackend` port (`plans/chat-and-persistence.md`
/// Phase 0). Owns: `OperationCommand` assembly, `AgentEventParser`, the
/// `streamJSONLine` NDJSON encoder, `Process` + pipes + readability/termination
/// handlers, and `PathPreflight` resolution (the executable name stays a
/// backend-internal concern; the launcher resolves the path via its injected
/// `resolveClaude` seam and passes it in via `CLIProfile`).
///
/// **Concurrency shape** (validated against `swift-concurrency-pro`):
/// - An `actor` (holds `Process` — not `Sendable`). No `@unchecked Sendable`.
/// - Per-turn `AsyncStream` via `makeStream(of:)`; the `readabilityHandler`
///   captures the `Sendable` continuation, decodes off-main, `yield`s.
/// - Continuation finished EXACTLY ONCE: on `endsGeneration` event (turn
///   boundary) or `terminationHandler` (process exit). `onTermination`
///   distinguishes `.cancelled` (tear down process) from `.finished` (natural
///   turn end; process stays alive for the next turn).
/// - `.unbounded` buffering — the `@MainActor` consumer drains promptly and
///   tokens must never be dropped.
///
/// **Raw-bytes logging:** the backend owns the pipe reads and calls back to
/// the launcher's `onStdoutChunk`/`onStderrChunk` for raw mirroring
/// (`rawTranscript`, `stderr`, `run.jsonl`, `run.stderr.log`). The launcher
/// owns the log file handles and the mirrors — only the pipe reading moved.
actor ClaudeCLIBackend: AgentBackend {

    /// A `Sendable` gate that fires an `onExit` callback exactly once. Used by
    /// the `terminationHandler` (background queue) without needing to hop to
    /// the actor — the callback itself is `@Sendable` and hops to `@MainActor`
    /// internally (the launcher's handler does `Task { @MainActor in finish() }`).
    private final class OnExitGate: Sendable {
        private let lock = OSAllocatedUnfairLock<(@Sendable (Int) -> Void)?>(initialState: nil)

        init(_ callback: @escaping @Sendable (Int) -> Void) {
            lock.withLock { $0 = callback }
        }

        func fire(status: Int) {
            let callback = lock.withLock { existing -> (@Sendable (Int) -> Void)? in
                let cb = existing
                existing = nil  // one-shot: clear so subsequent calls are no-ops
                return cb
            }
            callback?(status)
        }
    }

    /// One live CLI session: the `Process`, its stdin handle, and the current
    /// turn's stream continuation. Held inside the actor so `Process` (not
    /// Sendable) never crosses an isolation boundary.
    private final class CLISession {
        let process: Process
        let stdinHandle: FileHandle?
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        let isInteractive: Bool
        /// The continuation for the CURRENT turn's stream. Replaced at each
        /// turn boundary. The readabilityHandler captures a reference to the
        /// BOX (not the value) so it always yields to the live continuation
        /// even after a turn swap — but in practice the handler only fires
        /// while a turn is active (the process blocks on stdin between turns).
        let continuationBox: ContinuationBox
        /// Fires exactly once on process exit. Sendable — safe to call from
        /// the terminationHandler (background queue).
        let onExitGate: OnExitGate

        init(process: Process,
             stdinHandle: FileHandle?,
             stdoutPipe: Pipe,
             stderrPipe: Pipe,
             isInteractive: Bool,
             continuationBox: ContinuationBox,
             onExitGate: OnExitGate) {
            self.process = process
            self.stdinHandle = stdinHandle
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.isInteractive = isInteractive
            self.continuationBox = continuationBox
            self.onExitGate = onExitGate
        }
    }

    /// A `Sendable` box holding the current turn's continuation. The
    /// `readabilityHandler` (background queue) captures this box and reads
    /// `.continuation` to yield events. The actor swaps the value at turn
    /// boundaries. Access is synchronized via `OSAllocatedUnfairLock`.
    private final class ContinuationBox: Sendable {
        private let lock = OSAllocatedUnfairLock<AsyncStream<AgentEvent>.Continuation?>(initialState: nil)

        var continuation: AsyncStream<AgentEvent>.Continuation? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }

    /// A `Sendable` line-buffer for the readabilityHandler (background queue).
    /// Synchronized via `OSAllocatedUnfairLock` — the handler holds the lock
    /// for the decode+yield cycle so partial lines carry across reads.
    private final class LineBuffer: Sendable {
        private let lock = OSAllocatedUnfairLock<String>(initialState: "")

        /// Append `chunk`, split off complete lines, pass each to `parse`,
        /// and keep any trailing partial. Returns the parsed events in order.
        func drainAndParse(_ chunk: String) -> [AgentEvent] {
            lock.withLock { buffer in
                buffer.append(chunk)
                var events: [AgentEvent] = []
                while let newlineIndex = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<newlineIndex])
                    buffer.removeSubrange(...newlineIndex)
                    if let event = AgentEventParser.parse(line: line) {
                        events.append(event)
                    }
                }
                return events
            }
        }

        /// Parse any trailing partial line (called at process exit). Returns
        /// the event if one was produced, then clears the buffer.
        func drainTrailing() -> AgentEvent? {
            lock.withLock { buffer in
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer = ""
                return AgentEventParser.parse(line: line)
            }
        }
    }

    private var sessions: [String: CLISession] = [:]

// MARK: - AgentBackend
// TEMP DEBUG: the ClaudeCLIBackend.start/send/cancel lines below carry verbose
// TEMP DEBUG: lifecycle logging (spawn args, per-event routing, turn end). Strip
// TEMP DEBUG: via `grep -n "TEMP DEBUG"`.

    func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        guard let cli = profile.cli else {
            DebugLog.agent("ClaudeCLIBackend.start: FAIL noCLIProfile") // TEMP DEBUG
            throw ClaudeCLIError.noCLIProfile
        }

        // Build the command (the backend owns OperationCommand assembly).
        // #329: the chat-composer picker's per-provider model selection is
        // threaded in as `providerHints["cliSelectedModel"]` by the launcher;
        // nil/empty = "no preference" → the builder's legacy precedence applies
        // (Settings modelOverride → per-op alias). Default = unchanged.
        let cliSelectedModel = profile.providerHints["cliSelectedModel"]
        let isInteractive: Bool
        let command: OperationCommand
        if case .queryChat = cli.operation {
            isInteractive = true
            command = OperationCommand.buildInteractiveQuery(
                operation: cli.operation,
                wikiRoot: cli.wikiRoot,
                wikiID: cli.wikiID,
                systemPrompt: systemPrompt,
                scratchDirectory: profile.scratchDirectory?.path ?? cli.command.executable,
                wikictlDirectory: cli.wikictlDirectory,
                resolvedExecutable: cli.resolvedExecutable,
                command: cli.command,
                sandbox: cli.sandbox,
                selectedModel: cliSelectedModel
            )
        } else {
            isInteractive = false
            command = OperationCommand.build(
                operation: cli.operation,
                wikiRoot: cli.wikiRoot,
                wikiID: cli.wikiID,
                systemPrompt: systemPrompt,
                scratchDirectory: profile.scratchDirectory?.path ?? "",
                wikictlDirectory: cli.wikictlDirectory,
                resolvedExecutable: cli.resolvedExecutable,
                command: cli.command,
                sandbox: cli.sandbox,
                selectedModel: cliSelectedModel
            )
        }

        DebugLog.agent("ClaudeCLIBackend.start: command \(command.debugSummary)") // TEMP DEBUG (existed; re-tagged)
        DebugLog.agent("ClaudeCLIBackend.start: isInteractive=\(isInteractive) exe=\(command.executable) argCount=\(command.arguments.count) authSet=\(!(command.environment["ANTHROPIC_API_KEY"]?.isEmpty ?? true)) cwd=\(profile.scratchDirectory?.lastPathComponent ?? "(none)")") // TEMP DEBUG

        // Create the per-turn stream BEFORE spawning so no events are lost
        // between spawn and the first `send`.
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        let box = ContinuationBox()
        box.continuation = continuation

        // NOTE: the cancellation bridge (onTermination) is set AFTER spawning
        // so it can capture the PID (the Process is not Sendable and can't be
        // captured in the @Sendable closure). See below.

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        if let scratch = profile.scratchDirectory {
            process.currentDirectoryURL = scratch
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        if isInteractive {
            process.standardInput = stdinPipe
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lineBuffer = LineBuffer()

        // stdout is line-buffered NDJSON: accumulate bytes, split on newlines,
        // decode each COMPLETE line OFF-MAIN, and yield to the continuation.
        // Non-blocking — the handler fires on a background queue.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            // Raw mirror callback (launcher does rawTranscript + run.jsonl).
            cli.onStdoutChunk?(chunk)
            let events = lineBuffer.drainAndParse(chunk)
            for event in events {
                DebugLog.agent("ClaudeCLIBackend: parsed → \(event)") // TEMP DEBUG
                // Yield to the current turn's continuation. If the turn was
                // already finished (e.g. process exit raced), yield is a
                // no-op on a finished continuation.
                box.continuation?.yield(event)
                // Turn boundary: finish THIS turn's stream so the consumer's
                // for-await exits. The process stays alive (interactive) or
                // will exit (one-shot → terminationHandler).
                if AgentEvent.endsGeneration(event) {
                    DebugLog.agent("ClaudeCLIBackend: endsGeneration → finish turn stream") // TEMP DEBUG
                    box.continuation?.finish()
                    box.continuation = nil
                }
            }
        }

        // stderr is claude's diagnostics — surfaced separately and prominently.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            cli.onStderrChunk?(chunk)
        }

        let sessionID = UUID().uuidString
        let onExitGate = OnExitGate(onExit)

        process.terminationHandler = { proc in
            // Nil out the readability handlers so they stop firing.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            let status = proc.terminationStatus
            DebugLog.agent("ClaudeCLIBackend: terminationHandler fired pid=\(proc.processIdentifier) status=\(status)") // TEMP DEBUG (existed; re-tagged)

            // Drain any trailing partial line and yield it before finishing.
            if let trailing = lineBuffer.drainTrailing() {
                box.continuation?.yield(trailing)
            }
            // Finish the continuation (idempotent if already finished at a
            // turn boundary).
            box.continuation?.finish()
            box.continuation = nil

            // Fire onExit exactly once (the gate is one-shot).
            onExitGate.fire(status: Int(status))
        }

        do {
            DebugLog.agent("ClaudeCLIBackend: spawning kind=\(cli.operation.kind.rawValue) wikiID=\(cli.wikiID) exe=\(command.executable)") // TEMP DEBUG (existed; re-tagged)
            try process.run()
            DebugLog.agent("ClaudeCLIBackend: spawned pid=\(process.processIdentifier) kind=\(cli.operation.kind.rawValue)") // TEMP DEBUG (existed; re-tagged)
        } catch {
            // Clean up the stream so the consumer doesn't hang.
            DebugLog.agent("ClaudeCLIBackend: spawn FAILED: \(error.localizedDescription)") // TEMP DEBUG
            continuation.finish()
            throw error
        }

        // Cancellation bridge: if the consumer cancels the for-await loop
        // (stopAgent), terminate the process via its PID. `.finished` (natural
        // turn end) is a no-op — the process stays alive for the next turn.
        let pid = process.processIdentifier
        continuation.onTermination = { @Sendable reason in
            if case .cancelled = reason {
                if pid > 0 { kill(pid, SIGTERM) }
            }
            // .finished: natural turn end, process stays alive for next turn.
        }

        let stdinHandle: FileHandle? = isInteractive ? stdinPipe.fileHandleForWriting : nil
        let session = CLISession(
            process: process,
            stdinHandle: stdinHandle,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            isInteractive: isInteractive,
            continuationBox: box,
            onExitGate: onExitGate)
        sessions[sessionID] = session

        // Store the initial stream for the first `send` to return.
        initialStreams[sessionID] = stream

        return SessionHandle(id: sessionID)
    }

    /// The initial per-turn stream created at `start`, returned by the first
    /// `send` so the consumer begins draining immediately.
    private var initialStreams: [String: AsyncStream<AgentEvent>] = [:]

    func send(_ turn: TurnInput, into handle: SessionHandle) async -> AsyncStream<AgentEvent> {
        guard let session = sessions[handle.id] else {
            // Session gone (cancelled/finished) — return an empty stream.
            DebugLog.agent("ClaudeCLIBackend.send: no session for handle \(handle.id) — empty stream") // TEMP DEBUG
            return AsyncStream { $0.finish() }
        }
        DebugLog.agent("ClaudeCLIBackend.send: turn chars=\(turn.userText.count) handle=\(handle.id) interactive=\(session.isInteractive)") // TEMP DEBUG

        // Resolve THIS turn's stream BEFORE writing stdin, so no response event
        // is lost in the gap between the stdin write and the continuation being
        // installed. The first turn reuses the stream created at `start` (its
        // continuation is already live); subsequent turns create a fresh one and
        // install it into the continuation box here. The readabilityHandler
        // (background queue) reads the box, so installing first closes the race
        // where a fast-responding process could emit before the box is set.
        let stream: AsyncStream<AgentEvent>
        if let initial = initialStreams.removeValue(forKey: handle.id) {
            stream = initial
        } else {
            let (newStream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
            session.continuationBox.continuation = continuation

            // Capture the PID (Sendable) for the cancellation bridge — the Process
            // itself is not Sendable and must not cross isolation boundaries.
            let pid = session.process.processIdentifier
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason {
                    // Consumer cancelled (stopAgent) — terminate the process via
                    // its PID. Equivalent to process.terminate() (SIGTERM).
                    if pid > 0 { kill(pid, SIGTERM) }
                }
                // .finished: natural turn end, process stays alive for next turn.
            }
            stream = newStream
        }

        // Now write the user turn — the continuation is live, so any event the
        // process emits in response is delivered, not dropped.
        if session.isInteractive {
            let trimmed = turn.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let line = Self.streamJSONLine(forUserText: trimmed)
                if let line, let data = (line + "\n").data(using: .utf8) {
                    do {
                        try session.stdinHandle?.write(contentsOf: data)
                        DebugLog.agent("ClaudeCLIBackend.send: wrote \(data.count) bytes to stdin (turn end will synthesize .messageStop)") // TEMP DEBUG
                    } catch {
                        // Write failed — surface as a raw event and finish. Also
                        // finish the turn's continuation so its stream doesn't
                        // dangle (terminationHandler would finish it, but be explicit).
                        DebugLog.agent("ClaudeCLIBackend.send: stdin write FAILED: \(error.localizedDescription)") // TEMP DEBUG
                        session.continuationBox.continuation?.finish()
                        session.continuationBox.continuation = nil
                        let (errStream, cont) = AsyncStream.makeStream(of: AgentEvent.self)
                        cont.yield(.raw("Failed to send message to the Agent: \(error.localizedDescription)"))
                        cont.finish()
                        return errStream
                    }
                }
            }
        }

        return stream
    }

    func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? {
        // Phase 0 does NOT implement resume. The CLI backend cannot resume a
        // prior session by opaque id (claude's `--resume` was never wired).
        return nil
    }

    func cancel(_ session: SessionHandle) async {
        guard let session = sessions.removeValue(forKey: session.id) else {
            DebugLog.agent("ClaudeCLIBackend.cancel: no session for handle \(session.id) — no-op") // TEMP DEBUG
            return
        }
        DebugLog.agent("ClaudeCLIBackend.cancel: terminating session pid=\(session.process.processIdentifier)") // TEMP DEBUG
        // Close stdin and terminate the process. The terminationHandler will
        // fire onExit via the one-shot OnExitGate (safe even though the
        // session is already removed from the actor's map).
        try? session.stdinHandle?.close()
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        session.process.terminate()
    }

    // MARK: - Internal

    // MARK: - NDJSON encoder (moved verbatim from AgentLauncher)

    /// Encode one user turn as a `claude --input-format stream-json` NDJSON line.
    /// Verbatim from `AgentLauncher.streamJSONLine` (Phase 0 move, not rewrite).
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
}

// MARK: - Errors

enum ClaudeCLIError: Error, LocalizedError {
    case noCLIProfile

    var errorDescription: String? {
        switch self {
        case .noCLIProfile:
            return "ClaudeCLIBackend requires a CLIProfile in BackendProfile."
        }
    }
}
