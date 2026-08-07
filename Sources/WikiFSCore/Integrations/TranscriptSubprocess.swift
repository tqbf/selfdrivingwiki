import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Shared subprocess infrastructure for transcript-fetching PEP 723 scripts
/// (`youtube-transcript`, `podcast-transcript`). Both scripts share the
/// `env -S uv run --script` shebang and are spawned identically.
///
/// Lives in WikiFSCore so the transcript services can use it without importing
/// the app module. The low-level process execution is delegated to
/// `AsyncProcessRunner`; this type keeps only transcript-specific script
/// resolution, PATH augmentation, and app-lifetime orphan cleanup.
enum TranscriptSubprocess {

    // MARK: - ProcessRegistry

    /// Tracks launch identities so `NSApplication.willTerminate` can clean up
    /// orphans without relying on a recyclable numeric PID.
    final class ProcessRegistry: @unchecked Sendable {
        private var identities = [ProcessSignalSafety.PositivePID: ProcessSignalSafety.Identity]()
        private var registered = false
        private let lock = NSLock()

        func registerIfNeeded() {
            lock.lock()
            defer { lock.unlock() }
            guard !registered else { return }
            registered = true
            #if os(macOS)
            // Token discarded on purpose: `registered` makes this once-only for
            // the life of the process, and the observer fires during app
            // termination — there is no point at which we would detach it.
            // swiftlint:disable:next discarded_notification_center_observer
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.terminateAll()
            }
            #endif
        }

        func track(_ identity: ProcessSignalSafety.Identity) {
            registerIfNeeded()
            lock.lock()
            identities[identity.processID] = identity
            lock.unlock()
        }

        func untrack(_ processID: Int32) {
            guard let processID = ProcessSignalSafety.PositivePID(rawValue: processID) else { return }
            lock.lock()
            identities.removeValue(forKey: processID)
            lock.unlock()
        }

        func terminateAllForTesting(
            observeProcess: @escaping (ProcessSignalSafety.PositivePID) -> ProcessSignalSafety.Identity?,
            sendSignal: @escaping (Int32, Int32) -> Int32
        ) {
            terminateAll(observeProcess: observeProcess, sendSignal: sendSignal)
        }

        private func terminateAll() {
            terminateAll(
                observeProcess: { ProcessIdentityObservation.observe(processID: $0) },
                sendSignal: { processID, signal in kill(processID, signal) })
        }

        private func terminateAll(
            observeProcess: (ProcessSignalSafety.PositivePID) -> ProcessSignalSafety.Identity?,
            sendSignal: (Int32, Int32) -> Int32
        ) {
            lock.lock()
            let snapshot = Array(identities.values)
            lock.unlock()

            guard let expectedParentProcessID = ProcessSignalSafety.PositivePID(
                rawValue: ProcessInfo.processInfo.processIdentifier)
            else {
                DebugLog.extraction("[transcript] refused orphan cleanup: invalid parent process ID")
                return
            }

            for identity in snapshot {
                switch ProcessSignalSafety.signal(
                    processID: identity.processID,
                    expectedIdentity: identity,
                    expectedParentProcessID: expectedParentProcessID,
                    observedIdentity: observeProcess(identity.processID),
                    signal: sendSignal) {
                case .sent(let result) where result == 0:
                    break
                case .sent(let result):
                    DebugLog.extraction(
                        "[transcript] orphan cleanup signal failed for PID \(identity.processID.rawValue): result=\(result)")
                case .refused(let refusal):
                    DebugLog.extraction(
                        "[transcript] refused orphan cleanup for PID \(identity.processID.rawValue): \(refusal)")
                }
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
    static func run(
        script: URL,
        arguments: [String]
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(uvSearchPATH):\(env["PATH"] ?? "")"
        let request = AsyncProcessRequest(
            executableURL: script,
            arguments: arguments,
            environment: env,
            outputMode: .separate)

        do {
            let result = try await AsyncProcessRunner.run(
                request,
                hooks: .init(
                    didLaunchIdentity: { identity in
                        if let identity {
                            processRegistry.track(identity)
                        }
                    },
                    didTerminate: { processID, _ in
                        processRegistry.untrack(processID)
                    }))
            let stdout = String(data: result.stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderrData, encoding: .utf8) ?? ""
            return (stdout: stdout, stderr: stderr, status: result.terminationStatus)
        } catch let error as AsyncProcessRunnerError {
            switch error {
            case .cancelled:
                throw CancellationError()
            case .launchFailed(let message), .pipeSetupFailed(let message):
                throw TranscriptSubprocessError.processFailed(message)
            }
        } catch {
            throw TranscriptSubprocessError.processFailed(error.localizedDescription)
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
