// pattern: Functional Core

import Foundation

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

    /// Classify a failed tool call's cause text. Returns nil when the text
    /// matches no known failure signature.
    public static func classify(_ causeText: String) -> ACPToolFailureClassification? {
        if causeText.contains(Self.sandboxApplySignature) {
            return .execKernelSandboxDenied
        }
        return nil
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
