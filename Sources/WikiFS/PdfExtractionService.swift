import AppKit
import Foundation
import WikiFSCore

/// Converts a PDF to Markdown by spawning the `pdf2md` script as a subprocess,
/// matching the existing `wikictl`/`claude` subprocess pattern.
///
/// `pdf2md` is a PEP 723 inline script (`tools/pdf2md/pdf2md`) — it needs `uv`
/// in PATH to bootstrap its own Python + dependencies on first run.
/// If `uv` is not installed, the subprocess fails and the caller falls back
/// to passing the raw PDF to the agent.
@MainActor
enum PdfExtractionService {
    /// Process registry — non-isolated so termination handlers (which fire on
    /// background threads) can call track/untrack without crossing actor isolation.
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

    /// Thread-safe byte accumulator for a pipe drained on a background queue.
    /// The pipe `readabilityHandler` fires off-actor, so the buffer it appends to
    /// must be its own lock-guarded box (not actor state).
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

    /// Whether `pdf2md` + its uv-managed dependencies are ready to use.
    /// Runs `pdf2md --help` as a lightweight probe — if the venv is cached
    /// this returns in under a second; if not, it can take minutes.
    static func checkReady() async -> Bool {
        guard let script = resolveScript() else {
            DebugLog.extraction("[pdf2md] checkReady: script not found at any candidate location")
            return false
        }
        DebugLog.extraction("[pdf2md] checkReady: probing \(script.path)")

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = script
            process.arguments = ["--help"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            let localBin = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true).path
            let existing = env["PATH"] ?? ""
            env["PATH"] = "\(localBin):\(existing)"
            process.environment = env
            process.terminationHandler = { proc in
                processRegistry.untrack(proc)
                let ok = proc.terminationStatus == 0
                DebugLog.extraction("[pdf2md] checkReady: probe exit=\(proc.terminationStatus) ready=\(ok)")
                continuation.resume(returning: ok)
            }
            processRegistry.track(process)
            do {
                try process.run()
            } catch {
                processRegistry.untrack(process)
                DebugLog.extraction("[pdf2md] checkReady: process.run() failed: \(error)")
                continuation.resume(returning: false)
            }
        }
    }

    /// Quick readiness probe that asks uv whether the dependencies are already
    /// cached, WITHOUT triggering a download.
    ///
    /// `checkReady()` runs `pdf2md --help`, which on a cold cache bootstraps the
    /// whole ~2 GB environment *silently* before returning — useless for a UI that
    /// wants to warn-and-show-progress. Instead this runs `uv run --offline`: uv
    /// resolves the inline script's dependencies from its cache only and never
    /// reaches the network, so a complete install runs `--help` and exits 0 in well
    /// under a second, while any missing distribution fails fast (non-zero). The
    /// timeout is only a safety net — offline mode can't hang waiting on a download.
    static func probeReady(timeout: Duration = .seconds(20)) async -> Bool {
        guard let script = resolveScript() else { return false }

        let process = Process()
        // Go through `env` so uv is found on the augmented PATH (the script's own
        // shebang is `env -S uv run --script`, but we need to inject `--offline`).
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uv", "run", "--offline", "--script", script.path, "--help"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
        env["PATH"] = "\(localBin):\(env["PATH"] ?? "")"
        process.environment = env

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    process.terminationHandler = { proc in
                        processRegistry.untrack(proc)
                        continuation.resume(returning: proc.terminationStatus == 0)
                    }
                    processRegistry.track(process)
                    do {
                        try process.run()
                    } catch {
                        processRegistry.untrack(process)
                        continuation.resume(returning: false)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            defer {
                group.cancelAll()
                if process.isRunning { process.terminate() }
            }
            return await group.next() ?? false
        }
    }

    /// HuggingFace repo that docling's `GRANITEDOCLING_MLX` VLM spec pulls on the
    /// first conversion (verified against `vlm_model_specs.GRANITEDOCLING_MLX.repo_id`
    /// in docling). uv installs the Python packages, but docling fetches these
    /// weights lazily into the shared HF hub cache — so readiness has two
    /// independent halves (packages + weights) that we probe separately.
    static let graniteModelRepoID = "ibm-granite/granite-docling-258M-mlx"

    /// Whether the granite VLM model weights are already on disk in the HF hub
    /// cache. `probeReady()` only proves the uv packages are installed; the model
    /// is a separate ~hundreds-MB download, so we look for `model.safetensors` in
    /// any snapshot of the repo's cache dir. `fileExists` follows the
    /// snapshot→blob symlink, so a half-written or absent blob reads as missing.
    static func modelWeightsPresent() -> Bool {
        let dirName = "models--" + graniteModelRepoID.replacingOccurrences(of: "/", with: "--")
        let snapshots = huggingFaceHubDirectory()
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        let fm = FileManager.default
        guard let revisions = try? fm.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil) else {
            DebugLog.extraction("[pdf2md] modelWeightsPresent: no snapshots at \(snapshots.path)")
            return false
        }
        let present = revisions.contains { revision in
            fm.fileExists(atPath: revision.appendingPathComponent("model.safetensors").path)
        }
        DebugLog.extraction("[pdf2md] modelWeightsPresent: \(present) (\(revisions.count) snapshot(s))")
        return present
    }

    /// Resolve the HuggingFace hub cache dir the same way `huggingface_hub` does:
    /// `HF_HUB_CACHE`, else `HF_HOME/hub`, else `~/.cache/huggingface/hub`. We never
    /// override these in the subprocess env, so the model docling downloads lands
    /// in the dir this check inspects.
    private static func huggingFaceHubDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let hub = env["HF_HUB_CACHE"], !hub.isEmpty {
            return URL(fileURLWithPath: hub, isDirectory: true)
        }
        if let hfHome = env["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome, isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// Pre-download everything `convert()` needs, streaming progress lines.
    /// Two phases: (1) `pdf2md --help` primes the uv-managed Python packages
    /// (docling, torch, spacy — `--help` defers the heavy imports), then (2) a
    /// `huggingface_hub.snapshot_download` pulls the granite model weights that
    /// docling would otherwise fetch lazily on the first conversion. Both are
    /// idempotent — fast no-ops when already cached. May take several minutes on a
    /// cold run (~2 GB total).
    static func preDownload(onProgress: @escaping @Sendable (String) -> Void) async throws {
        guard let script = resolveScript() else {
            throw ExtractionError.scriptNotFound
        }
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path

        onProgress("Installing Python packages (docling, torch, spacy)…\n")
        try await streamProcess(
            executable: script, arguments: ["--help"],
            extraPATH: localBin, onProgress: onProgress)

        onProgress("\nDownloading model weights (\(graniteModelRepoID))…\n")
        try await streamProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["uv", "run", "--quiet", "--with", "huggingface_hub",
                        "python", "-c", modelDownloadProgram, graniteModelRepoID],
            extraPATH: localBin, onProgress: onProgress)
    }

    /// Inline Python that fetches a repo into the HF hub cache, emitting tqdm
    /// progress on stderr. `sys.argv[1]` is the repo id (argv[0] is `-c`).
    private static let modelDownloadProgram = """
        import sys
        from huggingface_hub import snapshot_download
        snapshot_download(sys.argv[1])
        """

    /// Run a process to completion, forwarding its stderr to `onProgress` line by
    /// line and throwing on non-zero exit. Shared by both `preDownload` phases.
    static func streamProcess(
        executable: URL,
        arguments: [String],
        extraPATH: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stderrBuffer = OutputBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
            if let line = String(data: data, encoding: .utf8) {
                onProgress(line)
            }
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(extraPATH):\(env["PATH"] ?? "")"
        process.environment = env

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                processRegistry.untrack(proc)
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // Drain any bytes still in the kernel pipe buffer before taking.
                if let tail = try? stderrPipe.fileHandleForReading.readToEnd() {
                    stderrBuffer.append(tail)
                }
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let msg = String(data: stderrBuffer.take(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: ExtractionError.conversionFailed(status: proc.terminationStatus, message: msg))
                }
            }
            processRegistry.track(process)
            do {
                try process.run()
            } catch {
                processRegistry.untrack(process)
                continuation.resume(throwing: ExtractionError.processFailed(error))
            }
        }
    }

    /// Resolve the `pdf2md` script, mirroring `HelpersLocation.wikictlDirectory`
    /// priority order: bundled → dev build → executable sibling → repo tools.
    static func resolveScript() -> URL? {
        for candidate in candidateLocations() {
            let script = candidate.appendingPathComponent("pdf2md", isDirectory: false)
            let exists = FileManager.default.isExecutableFile(atPath: script.path)
            DebugLog.extraction("[pdf2md] resolveScript: \(script.path) exists=\(exists)")
            if exists { return script }
        }
        DebugLog.extraction("[pdf2md] resolveScript: not found in any candidate location")
        return nil
    }

    /// Convert PDF bytes to Markdown.  Throws on any failure — the caller is
    /// expected to catch, print the message, and fall back to raw PDF.
    static func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)? = nil,
        onStart: (@Sendable (Int32) -> Void)? = nil
    ) async throws -> String {
        guard let script = resolveScript() else {
            throw ExtractionError.scriptNotFound
        }

        DebugLog.extraction("[pdf2md] convert: \(filename) (\(pdfData.count) bytes) → \(script.path)")
        onProgress?("Converting \(filename) (\(pdfData.count / 1024) KB)…\n")

        // Write PDF bytes to a temp file so pdf2md can read them.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf2md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputFile = tempDir.appendingPathComponent(filename, isDirectory: false)
        try pdfData.write(to: inputFile)
        DebugLog.extraction("[pdf2md] convert: wrote temp input \(inputFile.path)")

        let result = try await run(script: script, input: inputFile, onProgress: onProgress, onStart: onStart)
        onProgress?("Done — \(result.count) chars of markdown.\n")
        DebugLog.extraction("[pdf2md] convert: success — \(result.count) chars of markdown")
        return result
    }

    // MARK: - Private

    /// Run `pdf2md` to completion. There is deliberately NO timeout — a first run
    /// can take many minutes downloading models, and a hard limit would kill a
    /// legitimately-slow conversion. Instead the call is cancellable: cancelling
    /// the surrounding Task (e.g. via the UI's Cancel button) terminates the
    /// subprocess, which surfaces as a thrown error the caller treats as cancelled.
    private static func run(
        script: URL,
        input: URL,
        onProgress: (@Sendable (String) -> Void)? = nil,
        onStart: (@Sendable (Int32) -> Void)? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = script
        process.arguments = [input.path]
        process.currentDirectoryURL = input.deletingLastPathComponent()

        // Prepend ~/.local/bin to PATH so the pdf2md shebang can find `uv`.
        // The system PATH (used when the app is launched from Finder) does not
        // include ~/.local/bin, but that is where `uv` installs itself.
        var env = ProcessInfo.processInfo.environment
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
        let existing = env["PATH"] ?? ""
        env["PATH"] = "\(localBin):\(existing)"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // CRITICAL: drain stdout CONTINUOUSLY, not just after exit. The markdown a
        // full-paper conversion writes to stdout easily exceeds the 64 KB pipe
        // buffer; if we only read it in the terminationHandler, `pdf2md` blocks in
        // write() once the pipe fills, can never exit, and we never drain it — a
        // deadlock that hangs the conversion forever. The handler accumulates bytes
        // off a background queue so the pipe never backs up.
        let stdoutBuffer = OutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
        }

        // Stream stderr lines to the progress callback (uv's download progress,
        // docling warnings, etc.). Also keep a copy for the failure message.
        let stderrBuffer = OutputBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
            if let onProgress, let line = String(data: data, encoding: .utf8) {
                onProgress(line)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                process.terminationHandler = { proc in
                    processRegistry.untrack(proc)
                    // Stop the continuous handlers, then drain whatever is still in
                    // the kernel pipe buffers so no bytes are lost between the last
                    // handler invocation and now.
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    if let tail = try? stdoutPipe.fileHandleForReading.readToEnd() {
                        stdoutBuffer.append(tail)
                    }
                    if let tail = try? stderrPipe.fileHandleForReading.readToEnd() {
                        stderrBuffer.append(tail)
                    }
                    let status = proc.terminationStatus
                    guard status == 0 else {
                        let errMsg = String(data: stderrBuffer.take(), encoding: .utf8) ?? ""
                        continuation.resume(throwing: ExtractionError.conversionFailed(status: status, message: errMsg))
                        return
                    }
                    let outData = stdoutBuffer.take()
                    guard let text = String(data: outData, encoding: .utf8),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        continuation.resume(throwing: ExtractionError.emptyOutput)
                        return
                    }
                    continuation.resume(returning: text)
                }

                processRegistry.track(process)
                do {
                    try process.run()
                    onStart?(process.processIdentifier)
                } catch {
                    processRegistry.untrack(process)
                    continuation.resume(throwing: ExtractionError.processFailed(error))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func candidateLocations() -> [URL] {
        var dirs: [URL] = []

        // 1. Bundled in the signed app (Contents/Helpers/pdf2md).
        dirs.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
        )

        // 2. Dev build output dir (`build/pdf2md`), relative to cwd.
        dirs.append(URL(fileURLWithPath: "build", isDirectory: true))

        // 3. Directory of the running executable (covers `swift run`).
        if let exe = Bundle.main.executableURL {
            dirs.append(exe.deletingLastPathComponent())
        }

        // 4. Repo tools directory (development).
        if let exe = Bundle.main.executableURL {
            let projectRoot = exe
                .deletingLastPathComponent()  // debug
                .deletingLastPathComponent()  // .build
            dirs.append(projectRoot.appendingPathComponent("tools/pdf2md", isDirectory: true))
        }

        return dirs
    }

    enum ExtractionError: LocalizedError {
        case scriptNotFound
        case timedOut
        case conversionFailed(status: Int32, message: String)
        case emptyOutput
        case processFailed(Error)

        var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                return "pdf2md script not found (PATH=\(ProcessInfo.processInfo.environment["PATH"] ?? "")). PDF will be sent to the agent directly."
            case .timedOut:
                return "pdf2md timed out after 180s — first run downloads ~2 GB (docling, granite model, spacy, torch). PDF will be sent to the agent directly."
            case .conversionFailed(let status, let message):
                let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
                if detail.contains("uv: command not found") || detail.contains("No such file") {
                    return "uv is not installed (PATH=\(path)) — PDF will be sent to the agent directly. Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
                }
                return "pdf2md exited \(status)\(detail.isEmpty ? "" : ": \(detail)") (PATH=\(path)). PDF will be sent to the agent directly."
            case .emptyOutput:
                return "pdf2md produced no output. PDF will be sent to the agent directly."
            case .processFailed(let error):
                return "Failed to launch pdf2md: \(error.localizedDescription) (PATH=\(ProcessInfo.processInfo.environment["PATH"] ?? "")). PDF will be sent to the agent directly."
            }
        }
    }
}
