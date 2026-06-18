import AppKit
import Foundation

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

    /// Whether `pdf2md` + its uv-managed dependencies are ready to use.
    /// Runs `pdf2md --help` as a lightweight probe — if the venv is cached
    /// this returns in under a second; if not, it can take minutes.
    static func checkReady() async -> Bool {
        guard let script = resolveScript() else {
            print("[pdf2md] checkReady: script not found at any candidate location")
            return false
        }
        print("[pdf2md] checkReady: probing \(script.path)")

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
                print("[pdf2md] checkReady: probe exit=\(proc.terminationStatus) ready=\(ok)")
                continuation.resume(returning: ok)
            }
            processRegistry.track(process)
            do {
                try process.run()
            } catch {
                processRegistry.untrack(process)
                print("[pdf2md] checkReady: process.run() failed: \(error)")
                continuation.resume(returning: false)
            }
        }
    }

    /// Pre-download all dependencies, streaming uv's stderr as progress lines.
    /// Primes the uv cache so subsequent `convert()` calls are fast.
    /// May take several minutes on first run (~2 GB: docling, granite model,
    /// spacy, torch, mlx-metal).
    static func preDownload(onProgress: @escaping @Sendable (String) -> Void) async throws {
        guard let script = resolveScript() else {
            throw ExtractionError.scriptNotFound
        }

        let process = Process()
        process.executableURL = script
        process.arguments = ["--help"]
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            onProgress(line)
        }

        var env = ProcessInfo.processInfo.environment
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
        env["PATH"] = "\(localBin):\(env["PATH"] ?? "")"
        process.environment = env

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                processRegistry.untrack(proc)
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: errData, encoding: .utf8) ?? ""
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
            print("[pdf2md] resolveScript: \(script.path) exists=\(exists)")
            if exists { return script }
        }
        print("[pdf2md] resolveScript: not found in any candidate location")
        return nil
    }

    /// Convert PDF bytes to Markdown.  Throws on any failure — the caller is
    /// expected to catch, print the message, and fall back to raw PDF.
    static func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard let script = resolveScript() else {
            throw ExtractionError.scriptNotFound
        }

        print("[pdf2md] convert: \(filename) (\(pdfData.count) bytes) → \(script.path)")
        onProgress?("Converting \(filename) (\(pdfData.count / 1024) KB)…\n")

        // Write PDF bytes to a temp file so pdf2md can read them.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf2md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputFile = tempDir.appendingPathComponent(filename, isDirectory: false)
        try pdfData.write(to: inputFile)
        print("[pdf2md] convert: wrote temp input \(inputFile.path)")

        let result = try await run(script: script, input: inputFile, onProgress: onProgress)
        onProgress?("Done — \(result.count) chars of markdown.\n")
        print("[pdf2md] convert: success — \(result.count) chars of markdown")
        return result
    }

    // MARK: - Private

    private static func run(
        script: URL,
        input: URL,
        onProgress: (@Sendable (String) -> Void)? = nil
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

        // Stream stderr lines to the progress callback (uv's download progress,
        // docling warnings, etc.).
        if let onProgress {
            stderrPipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                onProgress(line)
            }
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { proc in
                        processRegistry.untrack(proc)
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        let status = proc.terminationStatus
                        guard status == 0 else {
                            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                            let errMsg = String(data: errData, encoding: .utf8) ?? ""
                            continuation.resume(throwing: ExtractionError.conversionFailed(status: status, message: errMsg))
                            return
                        }
                        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
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
                    } catch {
                        processRegistry.untrack(process)
                        continuation.resume(throwing: ExtractionError.processFailed(error))
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw ExtractionError.timedOut
            }

            defer {
                group.cancelAll()
                if process.isRunning {
                    process.terminate()
                }
            }
            return try await group.next()!
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
