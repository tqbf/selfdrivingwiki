// pattern: Functional Core

import Foundation
import WikiFSCore

/// Structured classification of the diagnostics text a failed ACP tool call
/// carries in its output (`rawOutput` or rendered content).
///
/// **Why classification instead of repair:** the tool loop lives inside the
/// ACP agent subprocess. The app's client role (`ClientDelegate`) can only
/// answer fs/terminal/permission/elicitation requests, and `session/update`
/// notifications are one-way agent → client — there is no protocol surface
/// for injecting a tool result into the agent's own loop. The strongest
/// truthful response to a failed tool call is therefore to classify it and
/// carry the actionable reason in the persisted transcript row, where the
/// operator and any transcript-reading consumer can see why the tool failed
/// (issue #1417).
public enum ACPToolFailureClassification: Equatable, Sendable {

    /// Upper bound for cause text carried into a transcript row (`detail` /
    /// `output`). Keeps a pathological multi-kilobyte stderr dump from
    /// bloating `chat_transcript_items.item_json` while preserving the
    /// signature lines, which lead the text. 2 KiB comfortably fits the
    /// observed kernel diagnostics.
    public static let maxCauseTextLength = 2_048

    /// The agent's exec kernel exited at startup because macOS denied the
    /// nested `sandbox-exec` sandbox it tried to apply (`sandbox_apply` →
    /// EPERM, e.g. "sandbox-exec: sandbox_apply: Operation not permitted").
    /// This is a kernel startup failure, not a workspace-permission denial:
    /// retrying the same tool reproduces it, and the terminal-exec path may
    /// still work.
    case execKernelSandboxDenied

    /// Spawn-time denial (#1409): the OS refused to start `sandbox-exec`
    /// itself — spawning the seatbelt front-end failed with `EPERM`. The
    /// sandbox never applied; nothing of the agent ran. Same shape as
    /// `.sandboxUnavailable` (front-end missing) but a policy denial instead
    /// of an absent binary.
    case sandboxExecLaunchDenied

    /// Spawn-time denial (#1409 + #1417): the launched child applied its own
    /// nested `sandbox-exec` sandbox and macOS denied the apply
    /// (`sandbox_apply` → EPERM), killing the child at startup. This is the
    /// spawn-boundary form of `.execKernelSandboxDenied`: the signature
    /// arrives in the failing child's stderr instead of a failed tool call's
    /// cause text.
    case sandboxExecNestedDenial

    /// Classify a failed tool call's cause text. Returns nil when the text
    /// matches no known failure signature.
    public static func classify(_ causeText: String) -> ACPToolFailureClassification? {
        if causeText.contains(Self.sandboxApplySignature) {
            return .execKernelSandboxDenied
        }
        return nil
    }

    /// Classify a spawn/launch failure from its synchronously available
    /// diagnostics (#1409). The POSIX errno and the sandbox-apply stderr
    /// signature are all that is available at spawn time — Seatbelt denial
    /// records reach the unified log asynchronously (issue #1279), so no
    /// synchronous classification can quote them. Returns nil when the
    /// failure matches no known denial signature.
    public static func classifySpawn(
        error: Error,
        causeText: String,
        stderr: String?,
        executablePath: String
    ) -> ACPToolFailureClassification? {
        // The seatbelt front-end itself was denied its spawn — macOS refused
        // `sandbox_apply` before any child code ran.
        if SpawnFailureDetail.isPosixError(error, code: SpawnFailureDetail.eperm),
           isSandboxExecPath(executablePath) {
            return .sandboxExecLaunchDenied
        }
        // A child started and then died applying its own nested sandbox.
        if causeText.contains(sandboxApplySignature)
            || (stderr?.contains(sandboxApplySignature) ?? false) {
            return .sandboxExecNestedDenial
        }
        return nil
    }

    /// Render + classify a spawn failure into one bounded cause string for a
    /// user-visible error: the OS status (`SpawnFailureDetail.render`) with
    /// the actionable denial reason prefixed when a signature matches. Empty
    /// stderr contributes nothing; the text is bounded at
    /// `maxCauseTextLength` either way.
    public static func annotatedSpawnCause(
        error: Error,
        stderr: String?,
        executablePath: String,
        operation: String
    ) -> String {
        let cause = bounded(SpawnFailureDetail.render(error, operation: operation))
        guard
            let classification = classifySpawn(
                error: error,
                causeText: cause,
                stderr: stderr,
                executablePath: executablePath)
        else { return cause }
        return "\(classification.actionableReason)\n\n\(cause)"
    }

    /// True when `executablePath` names the seatbelt front-end regardless of
    /// its directory (production resolves `/usr/bin/sandbox-exec`).
    private static func isSandboxExecPath(_ executablePath: String) -> Bool {
        (executablePath as NSString).lastPathComponent == "sandbox-exec"
    }

    /// The literal `sandbox-exec` denial line, matched as a substring so
    /// surrounding diagnostics (kernel pids, exit codes, stderr tails) do not
    /// affect recognition.
    private static let sandboxApplySignature = "sandbox-exec: sandbox_apply"

    /// The actionable annotation for this failure, worded for both the
    /// operator and any model reading the transcript: what broke, why
    /// retrying unchanged cannot help, and which path may still work.
    public var actionableReason: String {
        switch self {
        case .execKernelSandboxDenied:
            return "Exec kernel could not start: macOS denied the nested sandbox "
                + "it tried to apply (sandbox-exec: sandbox_apply: Operation not permitted). "
                + "This is a kernel startup failure, not a workspace-permission denial; "
                + "retrying the same tool will fail the same way. The terminal-exec path may still work."
        case .sandboxExecLaunchDenied:
            return "Launch denied: macOS refused to start the sandbox front-end "
                + "(/usr/bin/sandbox-exec) with EPERM, so the process never ran. "
                + "This is a sandbox-policy denial, not a missing binary; check the "
                + "sandbox profile and any Seatbelt policy changes. Denial records "
                + "reach the unified log asynchronously — this message carries only "
                + "what the spawn itself reported."
        case .sandboxExecNestedDenial:
            return "Launch failed: the process applied its own nested sandbox-exec "
                + "sandbox and macOS denied it (sandbox_apply: Operation not permitted), "
                + "killing the process at startup. Nested sandbox applies are denied "
                + "when the parent is already confined; the outer wrapper fences this "
                + "subtree, so the nested sandbox is unnecessary. Denial records reach "
                + "the unified log asynchronously — this message carries only what the "
                + "failing process reported synchronously."
        }
    }

    /// Cause text bounded for persistence: hard-truncated at
    /// `maxCauseTextLength` characters with an explicit marker so a reader
    /// can tell truncation happened. Text within the bound passes through
    /// unchanged; empty text stays empty.
    public static func bounded(_ causeText: String) -> String {
        guard causeText.count > maxCauseTextLength else { return causeText }
        return String(causeText.prefix(maxCauseTextLength))
            + "\n[truncated at \(maxCauseTextLength) characters]"
    }

    /// The persisted failure text for a tool call: the actionable reason for a
    /// known signature prefixed to the bounded cause text, otherwise just the
    /// bounded cause. Empty text stays empty so absent diagnostics are never
    /// replaced by synthesized annotation.
    public static func annotatedDetail(for causeText: String) -> String {
        let boundedCause = bounded(causeText)
        guard !boundedCause.isEmpty else { return "" }
        guard let classification = classify(causeText) else { return boundedCause }
        return "\(classification.actionableReason)\n\n\(boundedCause)"
    }
}
