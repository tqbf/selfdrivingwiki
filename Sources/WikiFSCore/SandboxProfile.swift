import Darwin
import Foundation

/// Pure generator for the macOS seatbelt (`sandbox-exec`) profile that confines the
/// spawned agent's filesystem writes to a strict allowlist.
///
/// The profile is **allow-by-default for reads, network, and process execution**, but
/// **default-deny for writes** — `(allow default)` keeps the provider running normally
/// (it can read, exec, and use the network to reach its LLM API), then `(deny
/// file-write*)` is overridden by explicit `(allow file-write* …)` rules for ONLY:
///
/// - the per-run scratch dir (a directory tree → `subpath`),
/// - the active wiki's `<ulid>.sqlite` + its SQLite `-wal` / `-shm` / `-journal`
///   sidecars (exact files → `literal`),
/// - any user `extraAllowedPaths`.
///
/// This is provider-agnostic: the profile never names a provider; it fences the write
/// channel only. See `plans/sandbox-agent.md` for the threat model and the
/// `sandbox-exec` syntax research that underpins this.
public enum SandboxProfile {

    /// The fully-resolved invocation the launcher hands to `OperationCommand` when the
    /// sandbox is on: the profile text (one string, passed via `sandbox-exec -p`) plus
    /// the `-D key=value` profile-parameter pairs it references. Equatable so the
    /// pure argv-assembly in `OperationCommand` is unit-testable.
    public struct SandboxInvocation: Equatable, Sendable {
        /// The seatbelt profile text. One argument element (passed via
        /// `sandbox-exec -p <profile>`).
        public let profile: String
        /// `sandbox-exec -D` profile-parameter pairs, in emit order. The profile
        /// references these by `(param "<key>")`. These are profile variables — they
        /// are NOT injected into the child process environment (so `-D WIKI_DB=<path>`
        /// does not collide with the `WIKI_DB=<ulid>` env var `wikictl` uses).
        public let defines: [(String, String)]

        public init(profile: String, defines: [(String, String)]) {
            self.profile = profile
            self.defines = defines
        }

        // MARK: - Equatable (tuples aren't Equatable by default)
        public static func == (lhs: SandboxInvocation, rhs: SandboxInvocation) -> Bool {
            guard lhs.profile == rhs.profile, lhs.defines.count == rhs.defines.count else {
                return false
            }
            return zip(lhs.defines, rhs.defines).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    /// The SQLite journal-mode sidecar suffixes that may be created alongside the
    /// active wiki DB. `(WAL → -wal/-shm; DELETE/TRUNCATE/PERSIST → -journal.)`
    static let sqliteSidecarSuffixes = ["-wal", "-shm", "-journal"]

    /// Generate the seatbelt profile text. Pure `String → String` — no shell, no IO.
    ///
    /// - Parameters:
    ///   - scratchDir: the per-run scratch directory absolute path (the writable cwd).
    ///   - wikiDBPath: the active wiki's `<ulid>.sqlite` absolute file path.
    ///   - extraAllowedPaths: additional absolute paths to allow writes to (already
    ///     tilde-expanded and absolute-filtered by `SandboxConfig`).
    public static func generate(
        scratchDir: String,
        wikiDBPath: String,
        extraAllowedPaths: [String] = []
    ) -> String {
        var lines: [String] = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            // The scratch dir is a directory tree.
            "(allow file-write* (subpath (param \"SCRATCH_DIR\")))",
            // The active wiki DB and its SQLite sidecars are exact files.
            "(allow file-write* (literal (param \"WIKI_DB\")))",
        ]
        for suffix in sqliteSidecarSuffixes {
            lines.append(
                "(allow file-write* (literal (string-append (param \"WIKI_DB\") \"\(suffix)\")))"
            )
        }
        // User-widened paths. A path that is an existing directory is matched as a
        // subtree; anything else is matched as an exact file. Non-absolute entries
        // are dropped defensively (the caller already filters them, but this stays
        // robust if invoked directly).
        for path in extraAllowedPaths {
            guard path.hasPrefix("/") else { continue }
            let kind = isDirectory(path) ? "subpath" : "literal"
            lines.append("(allow file-write* (\(kind) \"\(escape(path))\"))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Generate a READ-ONLY seatbelt profile that allows writes to scratch (the agent
    /// needs a writable cwd for temp files) but DENIES writes to the wiki database.
    /// Used when the query agent runs without "Allow wiki edits" — it physically
    /// prevents `wikictl page upsert` / `wikictl index set` / `wikictl log append`
    /// from writing, regardless of prompt instructions.
    public static func generateReadOnly(scratchDir: String) -> String {
        let lines: [String] = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            // The scratch dir is writable — the agent needs a cwd.
            "(allow file-write* (subpath (param \"SCRATCH_DIR\")))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Build a read-only `SandboxInvocation` that confines the agent to scratch
    /// writes only. No wiki DB path is allowed — wikictl writes will fail.
    public static func readOnlyInvocation(
        homePath: String,
        scratchDir: String
    ) -> SandboxInvocation {
        let resolvedScratch = Self.canonical(scratchDir)
        let profile = generateReadOnly(scratchDir: resolvedScratch)
        return SandboxInvocation(
            profile: profile,
            defines: [
                ("HOME", homePath),
                ("SCRATCH_DIR", resolvedScratch),
            ]
        )
    }

    /// Build a `SandboxInvocation` from the three spawn-time paths. The scratch dir,
    /// DB path, and extra-allowed paths are **symlink-resolved** here, because the
    /// seatbelt `subpath`/`literal` matchers match the CANONICAL path — a symlinked
    /// component (e.g. `/tmp` → `/private/tmp`) makes an allow rule silently fail and
    /// writes get denied. Keeping this resolution in the (tested) core layer guards
    /// against a launcher regression dropping it. `extraAllowedPaths` should already
    /// be absolute (tilde-expanded); non-absolute entries are dropped by `generate`.
    public static func invocation(
        homePath: String,
        scratchDir: String,
        wikiDBPath: String,
        extraAllowedPaths: [String] = []
    ) -> SandboxInvocation {
        func realPath(_ s: String) -> String {
            Self.canonical(s)
        }
        let resolvedScratch = realPath(scratchDir)
        let resolvedDB = realPath(wikiDBPath)
        let resolvedExtra = extraAllowedPaths.map(realPath)
        let profile = generate(
            scratchDir: resolvedScratch,
            wikiDBPath: resolvedDB,
            extraAllowedPaths: resolvedExtra
        )
        // NOTE: these are profile parameters, NOT child env vars. `-D WIKI_DB=<path>`
        // is consumed by `(param "WIKI_DB")`; it does not touch the `WIKI_DB=<ulid>`
        // env var the agent/wikictl use.
        return SandboxInvocation(
            profile: profile,
            defines: [
                ("HOME", homePath),
                ("SCRATCH_DIR", resolvedScratch),
                ("WIKI_DB", resolvedDB),
            ]
        )
    }

    // MARK: - Helpers

    /// `true` if `path` exists and is a directory. Used to pick `subpath` (tree) vs
    /// `literal` (exact file) for an extra-allowed path.
    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// `realpath(3)` — the kernel's own canonical-path resolution, which is exactly
    /// what the seatbelt `subpath`/`literal` matchers resolve against. Foundation's
    /// `URL.resolvingSymlinksInPath()` is unreliable for this (it does NOT resolve
    /// `/tmp` → `/private/tmp`); `realpath` does. Falls back to the input when the
    /// path doesn't exist yet (`realpath` returns nil for non-existent paths), since
    /// a non-existent path can't be symlink-resolved and the seatbelt will create it.
    private static func canonical(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(path, &buf) else { return path }
        return String(cString: resolved)
    }

    /// Escape a path for a double-quoted SBPL string literal (backslash + quote).
    private static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
