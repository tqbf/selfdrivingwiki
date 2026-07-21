import AppKit
import Foundation
import WikiFSCore

/// Extracts article markdown + metadata from HTML via the bundled `defuddle`
/// Node script run with the bundled `bun` runtime.
///
/// This is a near-clone of `PdfExtractionService`'s `Process` pattern, but
/// strictly simpler:
/// - no uv/Python/venv (bun is always bundled and required by the build),
/// - HTML on stdin (not a temp file path arg),
/// - sub-second runtime (a 30s timeout is only a safety net),
/// - best-effort: `extract()` returns nil on ANY failure so the caller can fall
///   back to the tag-based `HTMLToMarkdown` path — zero regression.
///
/// `LocalDefuddleExtractor` (a thin struct in this file) conforms to
/// `HtmlMarkdownExtractor` (WikiFSCore protocol) and delegates to these static
/// methods, so `WikiStoreModel.htmlMarkdownExtractor` can invoke defuddle
/// without a direct dependency on the WikiFS target — mirroring the
/// `LocalPdf2MarkdownExtractor` / `PdfExtractionService` split.
///
/// **Invocation:** `bun <defuddle> parse -j -` (HTML on stdin, JSON on stdout).
/// We deliberately use `parse -j -` and NOT `-m -j -`: with `-m -j`, defuddle
/// overloads the `content` field with markdown and drops `contentMarkdown`
/// (verified). The decoder prefers `contentMarkdown` and falls back to `content`
/// so it is robust to either shape. See `tools/defuddle/README.md` and
/// `plans/defuddle-extraction.md` §0/§7.
@MainActor
enum DefuddleExtractionService {

    /// Markdown body + parsed metadata. Empty-string metadata fields are
    /// normalized to nil (defuddle emits `""`, not null, for absent values).
    struct ExtractionResult: Sendable {
        let markdown: String         // contentMarkdown (preferred) or content
        let title: String?
        let author: String?
        let description: String?
        let published: String?       // ISO 8601 string
        let wordCount: Int?
    }

    // MARK: - Public

    /// Resolve the bundled bun runtime + the defuddle script.
    /// Priority for each: bundled → dev build dir → well-known system location.
    /// Returns nil only if EITHER artifact is unresolvable (caller falls back).
    static func resolve() -> (bun: URL, script: URL)? {
        guard let bun = resolveBun(), let script = resolveDefuddle() else {
            return nil
        }
        return (bun, script)
    }

    /// Extract markdown + metadata from HTML bytes via `bun defuddle parse -j -`.
    /// Best-effort: returns nil on any failure (binary missing, non-zero exit,
    /// empty content for SPA/JS-rendered pages, bad JSON, timeout). Never throws.
    static func extract(html: String, timeout: Duration = .seconds(30)) async -> ExtractionResult? {
        guard let (bun, script) = resolve() else {
            DebugLog.extraction("[defuddle] extract: bun or defuddle script not resolvable — falling back to tag-based")
            return nil
        }

        let htmlBytes = Data(html.utf8)
        DebugLog.extraction("[defuddle] extract: \(htmlBytes.count) bytes → bun \(bun.lastPathComponent) + \(script.lastPathComponent)")

        // Continuous stdout/stderr drain. Pipe `readabilityHandler` callbacks fire
        // off-actor, so the buffers they append to must be their own lock-guarded
        // boxes — NOT actor state (same pipe-deadlock avoidance as PdfExtractionService).
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()

        let process = Process()
        process.executableURL = bun                              // Helpers/bun
        process.arguments = [script.path, "parse", "-j", "-"]    // [defuddle, "parse","-j","-"]
        // NO PATH augmentation: bun is an absolute executableURL (unlike pdf2md,
        // whose shebang needs `uv` on PATH). A Finder-launched app has no shell
        // PATH, but we never go through a shebang here — bun IS the executable.

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
        }

        return await withTaskGroup(of: ExtractionResult?.self) { group in
            // Process completion.
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<ExtractionResult?, Never>) in
                    process.terminationHandler = { proc in
                        processRegistry.untrack(proc)
                        // Stop the continuous handlers, then drain the kernel pipe
                        // buffers so no bytes are lost between the last handler
                        // invocation and now. Do NOT use readToEnd() here — after a
                        // readabilityHandler it races with a queued callback and can
                        // drop the final bytes. Nil the handler, let any in-flight
                        // callback land, then loop availableData. (Same discipline as
                        // PdfExtractionService.)
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        Thread.sleep(forTimeInterval: 0.05)
                        while true {
                            let data = stdoutPipe.fileHandleForReading.availableData
                            if data.isEmpty { break }
                            stdoutBuffer.append(data)
                        }
                        while true {
                            let data = stderrPipe.fileHandleForReading.availableData
                            if data.isEmpty { break }
                            stderrBuffer.append(data)
                        }

                        let status = proc.terminationStatus
                        guard status == 0 else {
                            let err = String(data: stderrBuffer.take(), encoding: .utf8) ?? ""
                            DebugLog.extraction("[defuddle] extract: exit=\(status)\(err.isEmpty ? "" : ": \(err.trimmingCharacters(in: .whitespacesAndNewlines))") — falling back to tag-based")
                            continuation.resume(returning: nil)
                            return
                        }
                        let outData = stdoutBuffer.take()
                        if let result = parseDefuddleJSON(outData) {
                            DebugLog.extraction("[defuddle] extract: success — \(result.markdown.count) chars of markdown")
                            continuation.resume(returning: result)
                        } else {
                            DebugLog.extraction("[defuddle] extract: exit 0 but no usable markdown (SPA / empty / bad JSON) — falling back to tag-based")
                            continuation.resume(returning: nil)
                        }
                    }

                    processRegistry.track(process)
                    do {
                        try process.run()
                    } catch {
                        processRegistry.untrack(process)
                        DebugLog.extraction("[defuddle] extract: process.run() failed: \(error)")
                        continuation.resume(returning: nil)
                        return
                    }

                    // Feed HTML to stdin, then CLOSE the write end (EOF signals
                    // defuddle that input is complete — without it defuddle blocks
                    // waiting for more input → deadlock). Write on a background
                    // queue so a very large page can't block the actor; close
                    // immediately after the write drains.
                    let writeHandle = stdinPipe.fileHandleForWriting
                    DispatchQueue.global(qos: .userInitiated).async {
                        writeHandle.write(htmlBytes)
                        try? writeHandle.close()
                    }
                }
            }

            // Timeout safety net. defuddle is sub-second, but a hung process
            // (e.g. stdin not closed, pathological input) must not hang ingestion.
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            defer {
                group.cancelAll()
                if process.isRunning { process.terminate() }
            }

            let result = await group.next() ?? nil
            // If the timeout won, the process may still be running; the defer
            // terminates it. If the process won, cancelling the sleep task is a
            // no-op.
            return result
        }
    }

    // MARK: - Binary resolution

    /// Resolve the bun runtime. `isExecutableFile` — bun is exec'd directly.
    private static func resolveBun() -> URL? {
        let fm = FileManager.default
        for candidate in candidateHelperDirectories() {
            let bun = candidate.appendingPathComponent("bun", isDirectory: false)
            if fm.isExecutableFile(atPath: bun.path) {
                return bun
            }
        }
        // ~ ~/.bun/bin/bun (dev / `swift run` before `make build`).
        let homeBun = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".bun/bin/bun", isDirectory: false)
        if fm.isExecutableFile(atPath: homeBun.path) {
            return homeBun
        }
        DebugLog.extraction("[defuddle] resolveBun: bun not found in any candidate location")
        return nil
    }

    /// Resolve the defuddle script. `fileExists` (NOT `isExecutableFile`) — bun
    /// reads the script rather than exec'ing it, so readability is what matters.
    private static func resolveDefuddle() -> URL? {
        let fm = FileManager.default
        for candidate in candidateHelperDirectories() {
            let script = candidate.appendingPathComponent("defuddle", isDirectory: false)
            if fm.fileExists(atPath: script.path) {
                DebugLog.extraction("[defuddle] resolveDefuddle: \(script.path)")
                return script
            }
        }
        // Repo tools directory (development / `swift run`): tools/defuddle/defuddle,
        // resolved relative to the running executable's project root.
        if let exe = Bundle.main.executableURL {
            let projectRoot = exe
                .deletingLastPathComponent()  // debug (in .build/...)
                .deletingLastPathComponent()  // .build
            let repoScript = projectRoot
                .appendingPathComponent("tools/defuddle/defuddle", isDirectory: false)
            if fm.fileExists(atPath: repoScript.path) {
                DebugLog.extraction("[defuddle] resolveDefuddle: \(repoScript.path)")
                return repoScript
            }
        }
        // System install (~/.local/bin/defuddle — the npm global bin).
        let system = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/defuddle", isDirectory: false)
        if fm.fileExists(atPath: system.path) {
            DebugLog.extraction("[defuddle] resolveDefuddle: \(system.path)")
            return system
        }
        DebugLog.extraction("[defuddle] resolveDefuddle: script not found in any candidate location")
        return nil
    }

    /// Bundled Helpers/ then dev build/ then the executable's own directory.
    /// Mirrors `HelpersLocation`/`PdfExtractionService.candidateLocations`.
    private static nonisolated func candidateHelperDirectories() -> [URL] {
        var dirs: [URL] = []
        // 1. Signed app bundle (Contents/Helpers).
        dirs.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
        )
        // 2. Dev build output dir (build/bun, build/defuddle), relative to cwd.
        dirs.append(URL(fileURLWithPath: "build", isDirectory: true))
        // 3. Directory of the running executable (covers `swift run`).
        if let exe = Bundle.main.executableURL {
            dirs.append(exe.deletingLastPathComponent())
        }
        return dirs
    }

    // MARK: - JSON parse

    /// Parse defuddle's `parse -j -` JSON. Robust to both `-j` (contentMarkdown
    /// present) and `-m -j` shapes (content overloaded with markdown,
    /// contentMarkdown absent). Prefers `contentMarkdown`; falls back to `content`
    /// only when it actually holds markdown. Empty strings → nil.
    ///
    /// `nonisolated` because it's called from the `terminationHandler` (which
    /// fires off-actor). It's a pure decoder with no actor state.
    private static nonisolated func parseDefuddleJSON(_ data: Data) -> ExtractionResult? {
        struct DefuddlePayload: Decodable {
            let content: String?
            let contentMarkdown: String?
            let title: String?
            let author: String?
            let description: String?
            let published: String?
            let wordCount: Int?
        }
        guard let payload = try? JSONDecoder().decode(DefuddlePayload.self, from: data) else {
            DebugLog.extraction("[defuddle] parseJSON: decode failed (\(data.count) bytes)")
            return nil
        }
        // Prefer the dedicated markdown field; fall back to `content` (which
        // holds markdown when `-m` was passed). Either way: non-empty check.
        let markdown = nonEmpty(payload.contentMarkdown) ?? nonEmpty(payload.content)
        guard let markdown else {
            DebugLog.extraction("[defuddle] parseJSON: empty markdown — SPA or no article body")
            return nil
        }
        return ExtractionResult(
            markdown: markdown,
            title: nonEmpty(payload.title),
            author: nonEmpty(payload.author),
            description: nonEmpty(payload.description),
            published: nonEmpty(payload.published),
            wordCount: payload.wordCount
        )
    }

    /// Map empty/whitespace-only strings to nil (defuddle emits `""` for absent
    /// metadata rather than null). `nonisolated` — pure string helper called from
    /// the off-actor terminationHandler.
    private static nonisolated func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return s
    }

    // MARK: - Process registry

    /// Tracks spawned defuddle processes so they can be terminated at app exit.
    /// Non-isolated: termination handlers fire on background threads, so the
    /// registry must be its own lock-guarded box (not actor state).
    final class ProcessRegistry: @unchecked Sendable {
        private var procs = Set<Process>()
        private var registered = false
        private let lock = NSLock()

        func registerIfNeeded() {
            lock.lock()
            defer { lock.unlock() }
            guard !registered else { return }
            registered = true
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.terminateAll()
            }
        }

        func track(_ process: Process) {
            registerIfNeeded()
            lock.lock()
            procs.insert(process)
            lock.unlock()
        }

        func untrack(_ process: Process) {
            lock.lock()
            procs.remove(process)
            lock.unlock()
        }

        /// For tests: terminate any tracked processes.
        func terminateAllForTesting() { terminateAll() }

        private func terminateAll() {
            lock.lock()
            let snapshot = procs
            lock.unlock()
            for p in snapshot where p.isRunning {
                p.terminate()
            }
        }
    }

    private static nonisolated let processRegistry = ProcessRegistry()

    // MARK: - Output buffer

    /// Thread-safe byte accumulator for a pipe drained on a background queue.
    final class OutputBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }
        func take() -> Data {
            lock.lock(); defer { lock.unlock() }; return data
        }
    }
}

// MARK: - HtmlMarkdownExtractor conformance

/// The bundled defuddle backend as an `HtmlMarkdownExtractor`.
///
/// `DefuddleExtractionService` itself is a caseless `@MainActor enum` used as a
/// namespace of static subprocess methods, so it can't be an instance conformer.
/// This thin non-isolated value type is the conformer: it delegates across the
/// main-actor boundary (allowed for async) so `WikiStoreModel` can invoke it.
/// Mirrors the `LocalPdf2MarkdownExtractor` / `PdfExtractionService` split.
struct LocalDefuddleExtractor: HtmlMarkdownExtractor {
    func extract(html: String) async -> HtmlExtractionResult? {
        await DefuddleExtractionService.extract(html: html).map {
            HtmlExtractionResult(
                markdown: $0.markdown,
                title: $0.title,
                author: $0.author,
                description: $0.description,
                published: $0.published,
                wordCount: $0.wordCount)
        }
    }
}
