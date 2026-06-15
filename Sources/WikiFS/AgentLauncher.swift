import Foundation
import Observation

/// Spawns an agent (or any shell command) against the live File Provider mount,
/// with `WIKI_ROOT` pointing at it, and streams the combined stdout/stderr back
/// into the app (INITIAL §8 / M6). The wiki is treated as read-only input.
///
/// This is allowed because the app is **un-sandboxed** (see
/// `WikiFS/WikiFS.entitlements` — no `com.apple.security.app-sandbox`); a
/// sandboxed app could not `Process`-spawn an arbitrary binary (`plans/signing.md`).
///
/// `@MainActor @Observable`: the view binds `command`, watches `output`,
/// `isRunning`, and `exitStatus`. Output is appended on the main actor from the
/// pipe `readabilityHandler`s — we NEVER block the main thread on
/// `waitUntilExit`; completion arrives via `terminationHandler`.
@MainActor
@Observable
final class AgentLauncher {
    /// The combined stdout+stderr captured so far.
    private(set) var output = ""
    /// True while a spawned process is running.
    private(set) var isRunning = false
    /// The exit status of the last finished process, or nil if none has run /
    /// one is still running.
    private(set) var exitStatus: Int32?

    /// The command the agent runs, editable in the launcher UI. The default
    /// exercises `find` + `cat` over BOTH the Markdown pages and the generated
    /// indexes, demonstrating the agent contract end to end.
    var command = """
    cd "$WIKI_ROOT" && echo '== tree ==' && find . -maxdepth 3 \
    && echo '== manifest ==' && cat manifest.json \
    && echo '== pages ==' && cat indexes/pages.jsonl \
    && echo '== links ==' && cat indexes/links.jsonl
    """

    private var process: Process?

    /// Spawn the command with `WIKI_ROOT=wikiRoot`. No-op if one is already
    /// running. `wikiRoot` MUST be the live mount resolved from the File
    /// Provider manager at click time — never a hardcoded CloudStorage path.
    func run(wikiRoot: String) {
        guard !isRunning else { return }

        output = ""
        exitStatus = nil
        isRunning = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        var env = ProcessInfo.processInfo.environment
        env["WIKI_ROOT"] = wikiRoot
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Stream both pipes onto the main actor as bytes arrive. Non-blocking:
        // the handlers fire on a background queue, then hop to the main actor.
        let appendHandler: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.output.append(text) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = appendHandler
        stderrPipe.fileHandleForReading.readabilityHandler = appendHandler

        process.terminationHandler = { [weak self] proc in
            // Drain any buffered tail, then detach the handlers.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.exitStatus = status
                self?.process = nil
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            output.append("Failed to launch: \(error.localizedDescription)\n")
            isRunning = false
            exitStatus = nil
        }
    }

    /// Terminate the running process, if any.
    func stop() {
        process?.terminate()
    }
}
