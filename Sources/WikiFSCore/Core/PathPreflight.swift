import Foundation

/// Verifies that an executable is resolvable on a PATH before the app tries to
/// spawn it (`plans/llm-wiki.md` Phase C — "PATH preflight: check `claude` is on
/// the login-shell PATH before spawning; surface a clear error if not"). The
/// failure reason is PROVIDER-NEUTRAL: every ACP provider goes through here, so
/// the text names the missing executable and never a specific product (#1371
/// review; the provider-specific hint path is `ProviderEnvHint`/readiness).
///
/// PURE + injectable: `resolve(executable:onPath:fileExists:)` takes the PATH
/// string and a file-existence predicate, so the search logic is unit-tested
/// without touching the real filesystem. The app calls `resolveOnLoginShell` to
/// get the actual login-shell PATH (a real `zsh -lc 'echo $PATH'` hop, since the
/// GUI app's own environment PATH is not the user's login PATH).
public enum PathPreflight {
    /// The outcome of a preflight: either the resolved absolute path, or a
    /// human-readable reason it failed (surfaced verbatim in the UI).
    public enum Result: Equatable, Sendable {
        case found(path: String)
        case missing(reason: String)
    }

    /// Search `path` (a colon-separated PATH string) for `executable`, using
    /// `fileExists` to test each candidate. Returns the first hit. An absolute or
    /// `./`-relative `executable` is tested directly without consulting PATH.
    public static func resolve(
        executable: String,
        onPath path: String,
        fileExists: (String) -> Bool
    ) -> Result {
        guard !executable.isEmpty else {
            return .missing(reason: "No executable name given.")
        }

        // An explicit path bypasses PATH lookup.
        if executable.hasPrefix("/") || executable.hasPrefix("./") || executable.hasPrefix("../") {
            return fileExists(executable)
                ? .found(path: executable)
                : .missing(reason: "‘\(executable)’ does not exist.")
        }

        let directories = path.split(separator: ":", omittingEmptySubsequences: true)
        for directory in directories {
            let candidate = directory + "/" + executable
            if fileExists(String(candidate)) {
                return .found(path: String(candidate))
            }
        }
        return .missing(reason: """
            ‘\(executable)’ was not found on your PATH. Install it and make \
            sure it is on your login shell PATH.
            """)
    }

    /// Resolve `executable` against the user's LOGIN-shell PATH — not the GUI
    /// app's process PATH, which is the launchd-minimal one and usually lacks
    /// `/opt/homebrew/bin`. Best-effort: if the shell hop fails we fall back to
    /// the process PATH so we never spuriously block a working setup.
    public static func resolveOnLoginShell(executable: String = "claude") async -> Result {
        await resolveOnLoginShell(executable: executable, runProcess: AsyncProcessRunner.run)
    }

    static func resolveOnLoginShell(
        executable: String = "claude",
        runProcess: (AsyncProcessRequest) async throws -> AsyncProcessResult
    ) async -> Result {
        await resolveOnLoginShell(
            executable: executable,
            runProcess: runProcess,
            fallbackPath: ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    static func resolveOnLoginShell(
        executable: String = "claude",
        runProcess: (AsyncProcessRequest) async throws -> AsyncProcessResult,
        fallbackPath: String
    ) async -> Result {
        let path = (await loginShellPATH(using: runProcess)) ?? fallbackPath
        return resolve(
            executable: executable,
            onPath: path,
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// The login-shell PATH (`zsh -lc 'printf %s "$PATH"'`), or nil if the
    /// hop fails.
    ///
    /// Deliberately unbounded: the hop runs on user-triggered discovery paths
    /// (provider readiness, catalog probe, one per agent run or extraction
    /// resolution), never per spawn, so a pathological login shell costs one
    /// stuck discovery — not a wedged spawn path. A bounded variant would
    /// need a cancellation/timeout race around `AsyncProcessRunner`, and the
    /// accepted risk is cheaper than that machinery (#1371 review).
    public static func loginShellPATH() async -> String? {
        await loginShellPATH(using: AsyncProcessRunner.run)
    }

    static func loginShellPATH(
        using runProcess: (AsyncProcessRequest) async throws -> AsyncProcessResult
    ) async -> String? {
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", "printf %s \"$PATH\""])

        do {
            let result = try await runProcess(request)
            guard result.terminationStatus == 0 else { return nil }
            let path = String(data: result.stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    public static func resolve(
        executable: String,
        usingSearchPath path: String
    ) -> Result {
        resolve(
            executable: executable,
            onPath: path,
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
