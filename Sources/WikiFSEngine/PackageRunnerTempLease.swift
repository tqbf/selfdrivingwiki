import Foundation
import WikiFSTypes
import WikiFSCore

/// The effective package runner of one ACP launch (issue #1279).
///
/// Classified from the spawn's executable + argument ARRAYS — never from a
/// joined command string — so an argument that merely contains a runner name
/// (a package spec such as `@agentclientprotocol/codex-acp`) cannot widen the
/// policy. The classification drives two bounded decisions:
///
/// - which provider-home write allowances the sandbox profile layers
///   (`~/.npm`, `~/.bun`, the uv cache/data pair), and
/// - which trusted temp root the launch plan exports as `TMPDIR` (the
///   scratch `.tmp` leaf for everything except an effective Bun launch that
///   carries an allocated `PackageRunnerTempLease`).
///
/// The PRODUCTION decision runs on the EFFECTIVE spawn — the post-
/// `canonicalizedSpawn` command — so an `npx` launch successfully rewritten to
/// `bun x` receives Bun policy, while a canonicalization that declines keeps
/// the original runner's policy (issue #1279 AC.5).
public enum PackageRunnerKind: Sendable, Equatable {
    /// `bun x …` / `bunx …` — writes `~/.bun`, stages + execs adapters under
    /// its own temp root.
    case bun
    /// `npx …` / `npm exec …` / `npm x …` — writes `~/.npm`.
    case npm
    /// `uvx …` / `uv tool run …` — writes the uv cache (`~/.cache/uv`) and
    /// data (`~/.local/share/uv`) trees.
    case uv
    /// A plain provider binary (claude, codex, gemini, …). No runner cache
    /// and no temp-root exception.
    case none

    /// Classify one launch shape. The executable basename selects the runner;
    /// where a runner needs a distinguishing first argument (`bun x`,
    /// `npm exec`/`npm x`, `uv tool run`) the argument array decides — a bare
    /// `bun`/`npm`/`uv` invocation with other subcommands is `.none`.
    public static func classify(executablePath: String, arguments: [String]) -> PackageRunnerKind {
        let basename = (executablePath as NSString).lastPathComponent.lowercased()
        if basename == "bunx" { return .bun }
        if basename == "bun", arguments.first == "x" { return .bun }
        if basename == "npx" { return .npm }
        if basename == "npm", arguments.first == "exec" || arguments.first == "x" { return .npm }
        if basename == "uvx" { return .uv }
        if basename == "uv", arguments.first == "tool", arguments.dropFirst().first == "run" { return .uv }
        return .none
    }
}

/// One package-runner execution-staging lease (issue #1279).
///
/// Under the strict summarizer tier, an effective `bun x` launch stages and
/// EXECUTES the adapter package under the child's own temp root. The strict
/// profile keeps model-controlled scratch W^X (scratch and `scratch/.tmp` stay
/// writable and NON-executable), so the temp root for such a launch moves to a
/// pre-created directory inside the Bun home — the profile's ONE deliberate
/// writable-and-executable package-runner exception.
///
/// This type owns exactly one such directory: a UUID child of
/// `<home>/.bun/wikifs-tmp`. It is deliberately NOT folded into
/// `LLMSandboxScratch` — the two types express different trust zones:
///
/// - `LLMSandboxScratch`: the model's writable, NON-executable scratch world
///   plus its matching sandbox invocation.
/// - `PackageRunnerTempLease`: a narrow writable AND executable runner staging
///   directory; it carries no sandbox data and is consumed only through
///   `BackendProfile.packageRunnerTempURL`.
///
/// Lifecycle: the summarizer snapshot allocates ONE lease before any spawn,
/// keeps it for the cached backend's full lifetime, and removes it in the
/// snapshot teardown transaction AFTER the cached backends shut down and
/// BEFORE the scratch is removed. `remove()` is explicit and logged (the
/// repository forbids silent cleanup failures).
public struct PackageRunnerTempLease: Sendable {
    /// The unique staging directory handed to the child as `TMPDIR`.
    public let directoryURL: URL

    /// The `~`-relative home directory the production lease parent lives
    /// under: the Bun home, already the explicit writable + executable
    /// package-runner exception in every sandbox profile that names it
    /// (layered per-spawn by `ACPBackend.providerHomeSubpaths`).
    private static let bunHomeLeaf = ".bun"
    /// The lease parent under the Bun home. The `wikifs-tmp` name scopes the
    /// exception to THIS app's leases so the parent can be inspected or
    /// cleaned by hand without touching bun's own cache layout.
    private static let tempParentLeaf = "wikifs-tmp"

    /// The production lease parent: `<home>/.bun/wikifs-tmp`. Tests pass an
    /// isolated temporary root instead (the `packageRunnerTempParent` seam).
    public static func defaultParent(homePath: String? = nil) -> URL {
        let home = homePath
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(bunHomeLeaf, isDirectory: true)
            .appendingPathComponent(tempParentLeaf, isDirectory: true)
    }

    /// Allocate one unique lease directory under `parent` (default: the
    /// production `~/.bun/wikifs-tmp`). The directory is created BEFORE the
    /// child spawn — the launch plan points `TMPDIR` at it and bun requires
    /// the root to exist.
    ///
    /// Allocation is transactional: only the `wikifs-tmp` leaf parent may be
    /// created and rolled back by an attempt. `~/.bun` itself is user data —
    /// the rollback NEVER removes it (an empty `~/.bun` left behind by a
    /// first-ever allocation is harmless and stays). If the child directory
    /// cannot be created, a parent this attempt created is removed ONLY when
    /// still EMPTY — the daemon and the renderer share the production
    /// parent, so a concurrent allocator may hold live leases there — and
    /// the error rethrows; a failed preparation therefore leaves nothing
    /// owned behind (issue #1279 AC.8).
    public static func make(parent: URL? = nil) throws -> PackageRunnerTempLease {
        let parentURL = parent ?? defaultParent()
        let fileManager = FileManager.default
        var createdParent = false
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            createdParent = true
        }
        let child = parentURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: child, withIntermediateDirectories: false)
        } catch {
            if createdParent {
                // Roll back ONLY what this attempt created and still owns —
                // never `~/.bun`, and never a parent another allocator shares.
                // The emptiness probe is a best-effort guard: a raced or
                // failing probe just skips the rollback (the parent stays for
                // the other allocator), which is the correct outcome.
                // swiftlint:disable:next silent_try_optional
                let existing: [String]? = try? fileManager.contentsOfDirectory(atPath: parentURL.path)
                let isEmpty = existing?.isEmpty ?? false
                if isEmpty {
                    DebugLog.trying(
                        "remove empty package-runner temp parent after failed allocation",
                        operation: { try fileManager.removeItem(at: parentURL) })
                }
            }
            throw error
        }
        DebugLog.agent("PackageRunnerTempLease: allocated \(child.path)")
        return PackageRunnerTempLease(directoryURL: child)
    }

    /// Delete the staging directory tree. Best-effort and logged (never
    /// throws) — the owner calls this only after the last child that could
    /// use the directory has terminated, so a failure leaves a stale
    /// directory, not a broken run.
    public func remove() {
        DebugLog.trying("remove package-runner temp lease", operation: {
            try FileManager.default.removeItem(at: directoryURL)
        })
    }
}
