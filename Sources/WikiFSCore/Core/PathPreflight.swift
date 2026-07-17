import Foundation

/// Verifies that an executable (specifically `claude`) is resolvable on a PATH
/// before the app tries to spawn it (`plans/llm-wiki.md` Phase C — "PATH
/// preflight: check `claude` is on the login-shell PATH before spawning; surface
/// a clear error if not").
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
            ‘\(executable)’ was not found on your PATH. Install the Claude CLI \
            (claude.com/claude-code) and make sure it is on your login shell PATH.
            """)
    }

    /// Resolve `executable` against the user's LOGIN-shell PATH — not the GUI
    /// app's process PATH, which is the launchd-minimal one and usually lacks
    /// `/opt/homebrew/bin`. Runs `zsh -lc 'echo $PATH'` to read the real PATH,
    /// then searches it. Best-effort: if the shell hop fails we fall back to the
    /// process PATH so we never spuriously block a working setup.
    public static func resolveOnLoginShell(executable: String = "claude") -> Result {
        let path = loginShellPATH() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        return resolve(
            executable: executable,
            onPath: path,
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// The login-shell PATH (`zsh -lc 'echo $PATH'`), or nil if the hop fails.
    public static func loginShellPATH() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}
