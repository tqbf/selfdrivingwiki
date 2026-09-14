import Foundation
import WikiFSCore

/// One LLM-driven child process's writable scratch world (issue #1276).
///
/// ACP extraction, model summarization/title generation, and provider-model
/// probes each start an LLM agent WITHOUT a wiki database. Every one of those
/// children gets a unique scratch directory and a read-only
/// `SandboxProfile.SandboxInvocation` fenced to it: writes are allowed only
/// under the scratch subtree (plus the provider runtime homes the base
/// read-only profile already allows, and the relocated temp root inside the
/// scratch). The typed value owns the directory and the invocation together,
/// so a spawn site cannot pair one with a mismatched other, and the source
/// audit (`LLMSpawnSandboxExhaustivenessTests`) can require every production
/// `BackendProfile` constructor to name a sandbox explicitly.
///
/// Cleanup ownership is explicit: `remove()` deletes the tree, and the owner
/// must call it only when no cached ACP process can still use the directory.
/// `AgentProviderRuntime`'s summarizer path shows the required order:
/// retire the lease → await active operations → terminate the cached backends
/// → remove the scratch.
public struct LLMSandboxScratch: Sendable {
    /// The unique scratch directory — the sandboxed child's working directory
    /// and the only filesystem subtree it may write.
    public let directoryURL: URL
    /// The scratch-local `.tmp` leaf that `ACPBackend.sandboxedSpawnPlan`
    /// points the child's `TMPDIR` at. Created eagerly so the relocated temp
    /// root exists before the child starts.
    public let tempDirectoryURL: URL
    /// The read-only seatbelt invocation confined to `directoryURL`. It
    /// carries NO `WIKI_DB` define — the child cannot write the wiki database.
    public let sandbox: SandboxProfile.SandboxInvocation

    /// The scratch-relative leaf `ACPBackend` relocates `TMPDIR` to. Pinned
    /// here (and asserted against `ACPBackend.tmpRelocationLeaf` in tests) so
    /// the two cannot drift.
    private static let tempLeaf = ".tmp"

    /// Create the scratch world as a unique directory under `parent`
    /// (default: the process temporary directory): `<prefix>-<uuid>` plus its
    /// scratch-local `.tmp` leaf, and the matching read-only invocation.
    ///
    /// - Parameters:
    ///   - parent: the root the scratch directory is created under. Must be an
    ///     absolute path; `SandboxProfile.readOnlyInvocation` canonicalizes it
    ///     for the seatbelt matchers.
    ///   - namePrefix: the scratch directory's name prefix (e.g. `acp-probe`).
    ///   - strict: when true, the invocation is
    ///     `SandboxProfile.strictReadOnlyInvocation` (W^X scratch/temp, pivot
    ///     exec denies, credential read denies) instead of the plain read-only
    ///     profile. A profile choice ONLY — the directory layout, `remove()`,
    ///     and lease ownership are identical either way. Summarizer children
    ///     pass true; extraction and probes stay on the plain profile until
    ///     separately validated.
    ///   - homePath: the current-user home passed to the profile as `HOME`
    ///     (the provider runtime homes hang off it).
    ///   - pdf2mdScriptPath: when non-nil, the same `pdf2md` exec/read deny
    ///     the write profile emits.
    public static func make(
        under parent: URL? = nil,
        namePrefix: String,
        homePath: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        pdf2mdScriptPath: String? = nil,
        strict: Bool = false
    ) throws -> LLMSandboxScratch {
        let base = parent ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(
            "\(namePrefix)-\(UUID().uuidString)", isDirectory: true)
        return try adopt(
            directory: directory,
            homePath: homePath,
            pdf2mdScriptPath: pdf2mdScriptPath,
            strict: strict)
    }

    /// Adopt an EXISTING unique directory (the extraction staging directory)
    /// as the scratch world: create its `.tmp` leaf and build the read-only
    /// invocation. The directory is created when missing so callers may adopt
    /// before staging their files.
    public static func adopt(
        directory: URL,
        homePath: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        pdf2mdScriptPath: String? = nil,
        strict: Bool = false
    ) throws -> LLMSandboxScratch {
        let tempDirectory = directory.appendingPathComponent(Self.tempLeaf, isDirectory: true)
        DebugLog.trying("create llm scratch", operation: {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        })
        let sandbox = strict
            ? SandboxProfile.strictReadOnlyInvocation(
                homePath: homePath,
                scratchDir: directory.path,
                pdf2mdScriptPath: pdf2mdScriptPath)
            : SandboxProfile.readOnlyInvocation(
                homePath: homePath,
                scratchDir: directory.path,
                pdf2mdScriptPath: pdf2mdScriptPath)
        return LLMSandboxScratch(
            directoryURL: directory,
            tempDirectoryURL: tempDirectory,
            sandbox: sandbox)
    }

    /// Delete the scratch tree. Best-effort and logged (never throws) — the
    /// child is already terminated when the owner calls this, so a failure
    /// leaves a stale temp directory, not a broken run.
    public func remove() {
        DebugLog.trying("remove llm scratch", operation: {
            try FileManager.default.removeItem(at: directoryURL)
        })
    }
}
