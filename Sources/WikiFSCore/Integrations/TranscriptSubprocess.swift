import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Shared subprocess infrastructure for transcript-fetching PEP 723 scripts
/// (`youtube-transcript`, `podcast-transcript`). Both scripts share the
/// `env -S uv run --script` shebang and are spawned identically: resolve the
/// bundled script, spawn via `Process`, drain stdout/stderr continuously via
/// `readabilityHandler`, clean up in `terminationHandler`, and return captured
/// output.
///
/// Mirrors `PdfExtractionService` (Sources/WikiFS/Sources/PdfExtractionService.swift)
/// but lives in WikiFSCore so the transcript services can use it without importing
/// the app module. The pattern is identical — see the load-bearing invariants
/// documented there (continuous stdout drain, terminationHandler pipe drain,
/// ProcessRegistry orphan killing, no bare `try?`).
enum TranscriptSubprocess {

    // MARK: - OutputBuffer

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

    // MARK: - ProcessRegistry

    /// Tracks live subprocesses so `NSApplication.willTerminate` kills orphans.
    /// Nonisolated so termination handlers (which fire on background threads)
    /// can call track/untrack without crossing actor isolation.
    final class ProcessRegistry: @unchecked Sendable {
        private var procs = Set<Process>()
        private var registered = false
        private let lock = NSLock()

        func registerIfNeeded() {
            lock.lock()
            defer { lock.unlock() }
            guard !registered else { return }
            registered = true
            #if os(macOS)
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.terminateAll()
            }
            #endif
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

    static let processRegistry = ProcessRegistry()

    // MARK: - PATH augmentation

    /// Directories prepended to a subprocess PATH so the script shebang
    /// (`env -S uv run --script`) can find `uv`. Mirrors
    /// `PdfExtractionService.uvSearchPATH` exactly. The bundled uv binary lives
    /// in the app's `Contents/Helpers` directory (placed there by build.sh) and
    /// is resolved via `candidateLocations()`.
    static var uvSearchPATH: String {
        let helpersDir = bundledHelpersDirectory().path
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
        return "\(helpersDir):\(localBin):/opt/homebrew/bin:/usr/local/bin"
    }

    // MARK: - Script resolution

    /// Resolve a named script, mirroring `PdfExtractionService.resolveScript()`
    /// priority order: bundled Helpers → dev build → executable sibling → repo tools.
    static func resolveScript(named name: String, repoSubdir: String) -> URL? {
        for candidate in candidateLocations(repoSubdir: repoSubdir) {
            let script = candidate.appendingPathComponent(name, isDirectory: false)
            let exists = FileManager.default.isExecutableFile(atPath: script.path)
            DebugLog.extraction("[transcript] resolveScript: \(script.path) exists=\(exists)")
            if exists { return script }
        }
        DebugLog.extraction("[transcript] resolveScript: \(name) not found at any candidate location")
        return nil
    }

    // MARK: - Subprocess execution

    /// Run a transcript script to completion, returning captured stdout.
    /// Cancellable: cancelling the surrounding Task terminates the subprocess.
    ///
    /// Load-bearing invariants (identical to `PdfExtractionService.run()`):
    /// - Continuous stdout drain via `readabilityHandler`, NOT post-exit read.
    /// - `terminationHandler` nils handlers and drains the kernel pipe one last time.
    /// - Non-zero exit → throws with captured stderr.
    /// - Empty output → throws `.emptyOutput`.
    static func run(
        script: URL,
        arguments: [String]
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(uvSearchPATH):\(env["PATH"] ?? "")"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
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

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(stdout: String, stderr: String, status: Int32), Error>) in
                process.terminationHandler = { proc in
                    processRegistry.untrack(proc)
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
                    let out = String(data: stdoutBuffer.take(), encoding: .utf8) ?? ""
                    let err = String(data: stderrBuffer.take(), encoding: .utf8) ?? ""
                    cont.resume(returning: (stdout: out, stderr: err, status: status))
                }
                processRegistry.track(process)
                do {
                    try process.run()
                } catch {
                    processRegistry.untrack(process)
                    cont.resume(throwing: TranscriptSubprocessError.processFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Candidate locations

    /// Candidate directories for script resolution, mirroring
    /// `PdfExtractionService.candidateLocations()`.
    private static func candidateLocations(repoSubdir: String) -> [URL] {
        var dirs: [URL] = []

        // 1. Bundled in the signed app (Contents/Helpers).
        dirs.append(bundledHelpersDirectory())

        // 2. Dev build output dir (`build/`), relative to cwd.
        dirs.append(URL(fileURLWithPath: "build", isDirectory: true))

        // 3. Directory of the running executable (covers `swift run`).
        if let exe = Bundle.main.executableURL {
            dirs.append(exe.deletingLastPathComponent())
        }

        // 4. Repo tools directory (development fallback).
        if let exe = Bundle.main.executableURL {
            let projectRoot = exe
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            dirs.append(projectRoot.appendingPathComponent(repoSubdir, isDirectory: true))
        }

        return dirs
    }

    private static func bundledHelpersDirectory() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
    }
}

/// Errors for transcript subprocess execution.
enum TranscriptSubprocessError: Error, LocalizedError {
    case scriptNotFound(String)
    case processFailed(String)
    case emptyOutput
    case subprocessFailed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let name):
            return "The \(name) script isn't available in this build."
        case .processFailed(let msg):
            return "Failed to launch transcript script: \(msg)"
        case .emptyOutput:
            return "The transcript script produced no output."
        case .subprocessFailed(let status, let message):
            return "Transcript script exited \(status)\(message.isEmpty ? "" : ": \(message)")"
        }
    }
}
