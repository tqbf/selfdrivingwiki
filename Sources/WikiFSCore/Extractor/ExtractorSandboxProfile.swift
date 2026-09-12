#if os(macOS)
import Foundation
import WikiFSTypes

/// Pure generator for the per-spawn macOS seatbelt (`sandbox-exec`) profile
/// that confines a managed extractor package process. Modeled on
/// `SandboxProfile` (the agent profile): pure `String`-in / `String`-out, no
/// shell, no IO — the executor applies it.
///
/// ## Threat model
///
/// A compromised or buggy reviewed package. The hard fence is filesystem
/// writes: `(deny file-write*)` is overridden only by explicit allows for the
/// per-operation layout plus capability-gated shared caches. Reads and
/// process-exec stay open — the runtime needs system dylibs, TLS certs, and
/// to exec its interpreter — and network is denied unless the package
/// manifest declares the `network` capability. Unlike the agent profile, the
/// network deny IS enforceable here: the extractor environment is a closed
/// allowlist (`ManagedExtractorProcessExecutor.makeEnvironment`), the layout
/// is hermetic, and every real package that needs network declares the
/// capability (`ExtractorPackages/*/manifest.json`; Defuddle and Docx2md run
/// fully bundled and declare none).
///
/// ## Rule order matters
///
/// The seatbelt resolves a request against the LAST matching filtered rule.
/// `(deny file-write*)` is emitted first and every write allow follows it, so
/// allowed writes win. The `(deny network*)` fence is emitted LAST (and only
/// for packages without the `network` capability) so nothing emitted after it
/// could shadow it accidentally.
///
/// ## Canonicalization
///
/// Every emitted root is passed through `realpath(3)` (via
/// `SandboxProfile.canonical`) because seatbelt `subpath` matchers match the
/// CANONICAL path — the `/tmp` → `/private/tmp` trap documented in
/// `plans/sandbox-agent.md`. An uncanonical root would make an allow rule
/// silently fail and deny the very writes it exists to permit.
///
/// See `plans/extractor-sandbox.md` for the full writeup and the
/// diagnosing-a-denied-write recipe.
enum ExtractorSandboxProfile {

    /// The seatbelt front-end the executor wraps every managed extractor
    /// spawn with on macOS. Deprecated by Apple but accepted repo-wide (same
    /// posture as `plans/sandbox-agent.md`).
    static let sandboxExecutablePath = "/usr/bin/sandbox-exec"

    /// Generate the profile text for one operation. Pure; emits, in order:
    ///
    /// 1. `(version 1)` / `(allow default)` / `(deny file-write*)` — reads,
    ///    exec, and mach-lookup stay open; writes are fenced.
    /// 2. `(allow file-write* (subpath (param "OPERATION_ROOT")))` — always.
    ///    The operation root already contains `packageRoot`, `homeRoot`,
    ///    `temporaryRoot`, and `privateCacheRoot` (enforced by
    ///    `ManagedExtractorProcessExecutor.validate`), so one subpath allow
    ///    covers the whole per-operation layout.
    /// 3. `SHARED_RUNTIME_CACHE` subpath allow — only when the manifest
    ///    declares `.sharedRuntimeCache` AND the host supplied the root (the
    ///    capability without a root grants nothing).
    /// 4. `SHARED_MODEL_CACHE` subpath allow — only when the manifest
    ///    declares `.modelDownload` AND the host supplied the root.
    /// 5. `TOKEN_CACHE` subpath allow — only when the host supplied the
    ///    durable token-cache root for this exact revision. Not a manifest
    ///    capability: the host decides, the manifest cannot request it.
    /// 6. `/dev/null` + `/dev/fd` data-write allows — the shell/interpreter
    ///    basics (the agent profile's `agentRuntimeWriteRules` equivalent,
    ///    minus the Claude-specific tmp marker no extractor needs).
    /// 7. `(deny network*)` — LAST, only when the capabilities do NOT contain
    ///    `.network`. Last so no later rule could shadow it; absent entirely
    ///    for network-capable packages.
    static func generate(
        paths: ManagedExtractorProcessPaths,
        capabilities: Set<ExtractorCapability>,
        durableTokenCacheRoot: URL?
    ) -> String {
        var lines: [String] = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            // One allow covers the entire per-operation layout: package,
            // home, temp, and private-cache roots are validated to live
            // under the operation root before a launch is ever prepared.
            "(allow file-write* (subpath (param \"OPERATION_ROOT\")))",
        ]
        if capabilities.contains(.sharedRuntimeCache),
           paths.sharedRuntimeCacheRoot != nil {
            lines.append("(allow file-write* (subpath (param \"SHARED_RUNTIME_CACHE\")))")
        }
        if capabilities.contains(.modelDownload),
           paths.sharedModelCacheRoot != nil {
            lines.append("(allow file-write* (subpath (param \"SHARED_MODEL_CACHE\")))")
        }
        if durableTokenCacheRoot != nil {
            lines.append("(allow file-write* (subpath (param \"TOKEN_CACHE\")))")
        }
        // Shell/interpreter basics: zsh and the runtimes redirect to
        // /dev/null, and /dev/stdout & co canonicalize under /dev/fd. Data
        // writes only — no chmod/unlink on the devices.
        lines.append("(allow file-write-data (literal \"/dev/null\"))")
        lines.append("(allow file-write-data (subpath \"/dev/fd\"))")
        // The network fence is emitted ONLY for packages that did not declare
        // the capability, and LAST: in the seatbelt the last matching rule
        // wins, so a trailing deny cannot be shadowed by anything emitted
        // after it.
        if !capabilities.contains(.network) {
            lines.append("(deny network*)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Build the resolved invocation for one operation: the profile text plus
    /// the `-D` defines its `(param …)` references. Every root is
    /// canonicalized with `realpath(3)` first — the seatbelt matches
    /// canonical paths, so a symlinked component (e.g. `/tmp` →
    /// `/private/tmp`) would otherwise make an allow rule silently fail.
    /// Defines are emitted only for rules the profile actually contains, in
    /// the same order.
    static func invocation(
        paths: ManagedExtractorProcessPaths,
        capabilities: Set<ExtractorCapability>,
        durableTokenCacheRoot: URL?
    ) -> SandboxProfile.SandboxInvocation {
        func canonical(_ url: URL) -> String {
            SandboxProfile.canonical(url.path)
        }
        let profile = generate(
            paths: paths,
            capabilities: capabilities,
            durableTokenCacheRoot: durableTokenCacheRoot)
        var defines: [(String, String)] = [
            ("OPERATION_ROOT", canonical(paths.operationRoot)),
        ]
        if capabilities.contains(.sharedRuntimeCache),
           let root = paths.sharedRuntimeCacheRoot {
            defines.append(("SHARED_RUNTIME_CACHE", canonical(root)))
        }
        if capabilities.contains(.modelDownload),
           let root = paths.sharedModelCacheRoot {
            defines.append(("SHARED_MODEL_CACHE", canonical(root)))
        }
        if let durableTokenCacheRoot {
            defines.append(("TOKEN_CACHE", canonical(durableTokenCacheRoot)))
        }
        return SandboxProfile.SandboxInvocation(profile: profile, defines: defines)
    }

    /// Assemble the `sandbox-exec` argv that wraps a real spawn:
    /// `-p <profile> -D k=v … -- <executable> <args…>`. Byte-for-byte the
    /// argv pattern the deleted `OperationCommand.applySandbox` used for the
    /// pre-ACP agent (verified in git at
    /// `a79469d5^:Sources/WikiFSCore/OperationCommand.swift`).
    static func wrappedArguments(
        executablePath: String,
        arguments: [String],
        invocation: SandboxProfile.SandboxInvocation
    ) -> [String] {
        ["-p", invocation.profile]
            + invocation.defines.flatMap { ["-D", "\($0.0)=\($0.1)"] }
            + ["--", executablePath]
            + arguments
    }
}
#endif
