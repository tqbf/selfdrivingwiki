import Foundation
import os
import ACP
import ACPModel
import WikiFSCore

// MARK: - Pure translator: ACP SessionUpdate → AgentEvent

/// Pure, I/O-free translator from ACP `SessionUpdate` values into the
/// backend-neutral `AgentEvent`. Mirrors paseo's `translateSessionUpdate`
/// (acp-agent.ts:2424) and ClaudeCLIBackend's tolerant mapping philosophy — but
/// produces only the events this app's launcher renders.
///
/// Kept free of any live I/O (no `Client`, no subprocess, no JSON decoding) so
/// it is directly unit-testable with hand-built `SessionUpdate` values — see
/// `ACPBackendTests`. The ACP→AgentEvent mapping:
///
/// - `agentMessageChunk(.text)` → `.assistantTextDelta` (streamed prose; the
///   launcher merges deltas into one `.assistantText` row, issue #121).
/// - `agentThoughtChunk(.text)` → `.raw` (reasoning; no dedicated case yet —
///   surfaced verbatim so nothing is swallowed, same fallback as `AgentEventParser`).
/// - `toolCall` / `toolCallUpdate` → `.toolUse` (start) / `.toolResult` (done).
///   ACP folds a tool's whole lifecycle into status updates (`pending` →
///   `in_progress` → `completed`/`failed`); we map the *call* to `.toolUse` and
///   a `completed`/`failed` status (with output text) to `.toolResult`.
/// - everything else (`plan`, `usage_update`, `current_mode_update`, …) → `[]`
///   (not rendered, same as `AgentEventParser`'s unmodeled types).
///
/// Turn-end (`.messageStop`) is NOT produced here — ACP has no turn-end
/// *notification*; the turn ends when the `session/prompt` request returns.
/// `ACPBackend.send` synthesizes `.messageStop` from prompt completion (see
/// `ACPBackend.swift`).
struct ACPEventTranslator: Sendable {

    /// Map one `SessionUpdate` to zero or more `AgentEvent`s. Pure & total: it
    /// never throws and maps every case (unknown → empty, never a crash).
    func translate(_ update: SessionUpdate) -> [AgentEvent] {
        switch update {
        case .agentMessageChunk(let block):
            // Streamed assistant prose. The launcher coalesces deltas into a
            // single `.assistantText` row (issue #121), so emit the delta.
            if let text = Self.text(from: block), !text.isEmpty {
                return [.assistantTextDelta(text)]
            }
            return []

        case .agentThoughtChunk(let block):
            // Agent reasoning. No dedicated AgentEvent; surface verbatim so the
            // chunk isn't silently dropped (mirrors `.raw` fallback in the parser).
            if let text = Self.text(from: block), !text.isEmpty {
                return [.raw(text)]
            }
            return []

        case .userMessageChunk(let block):
            // The agent echoing back the user's own message. The launcher already
            // shows the user's turn; an echo would duplicate it. Drop.
            _ = block
            return []

        case .toolCall(let call):
            // A tool invocation begins. Map to `.toolUse` with a one-liner
            // summary derived from the tool's title/kind/locations.
            return [.toolUse(name: Self.toolName(for: call), inputSummary: Self.toolSummary(for: call))]

        case .toolCallUpdate(let details):
            // A status patch for an existing tool call. Only a terminal status
            // (completed/failed) with output text is rendered — as `.toolResult`.
            if let status = details.status, status == .completed || status == .failed,
               let output = Self.toolOutput(for: details), !output.isEmpty {
                return [.toolResult(isError: status == .failed, summary: output)]
            }
            // Non-terminal / output-less updates: not rendered (a pending or
            // in_progress status carries nothing new for the transcript).
            return []

        case .plan, .planUpdate, .planRemoved,
             .availableCommandsUpdate, .currentModeUpdate,
             .configOptionUpdate, .sessionInfoUpdate, .usageUpdate:
            // Not rendered (no AgentEvent case; same as unmodeled wire types).
            return []
        }
    }

    // MARK: - Field extraction helpers

    /// Extract plain text from a content block (the `agentMessageChunk` /
    /// `agentThoughtChunk` payload). Non-text blocks (image/audio/resource) → nil.
    private static func text(from block: ContentBlock) -> String? {
        if case .text(let content) = block { return content.text }
        return nil
    }

    /// A renderable tool name. Prefers the ACP `title`; falls back to the
    /// `kind` (capitalized), then a generic "tool".
    private static func toolName(for call: ToolCallUpdate) -> String {
        if let title = call.title, !title.isEmpty { return title }
        if let kind = call.kind { return kind.rawValue.capitalized }
        return "tool"
    }

    /// A one-liner input summary for a tool call. ACP carries locations (file
    /// paths) rather than a structured `input` map like Claude's `tool_use`, so
    /// render the first location's path (e.g. `Edit  /path/to/file.swift`),
    /// falling back to the tool kind/title.
    private static func toolSummary(for call: ToolCallUpdate) -> String {
        if let path = call.locations?.first?.path, !path.isEmpty {
            return path
        }
        return ""
    }

    /// Extract a tool's output text (the `.toolResult` body) from a
    /// `tool_call_update`. ACP tool output lives in `content`
    /// (`[ToolCallContent]`) — flatten text/diff blocks to a string.
    private static func toolOutput(for details: ToolCallUpdateDetails) -> String? {
        guard let content = details.content else { return nil }
        return content.compactMap { $0.displayText }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Permission policy (the always-ask/yolo lever)

/// How the app (the ACP *client*) responds to a `session/request_permission`
/// from the agent. This is the structural enforcement of #287: a write cannot
/// land until the policy resolves.
///
/// - `yolo`: auto-approve — resolve immediately with the request's allow option.
///   Today's "writes apply with no review" behavior. Safe default (see caveat).
/// - `alwaysAsk`: defer — record the request as *pending* and block until the
///   future UI resolves it via `ACPBackend.resolvePermission`. Mirrors paseo's
///   `pendingPermissions` map + `permission_requested` event pattern
///   (acp-agent.ts:2050).
///
/// **Caveat (design doc):** always-ask enforcement *depends on the agent
/// emitting `request_permission` for writes*. Most do (Claude via the wrapper,
/// Copilot, …), but not all — so yolo is the safe default.
public enum PermissionPolicy: String, Sendable, CaseIterable {
    /// Skip all permission prompts — writes apply automatically.
    case bypass
    /// Pause for user approval before each tool that needs permission.
    case alwaysAsk
    /// Auto-approve edit/write tools; ask for everything else.
    case acceptEdits
    /// Deny all writes — read-only analysis mode.
    case plan

    public var label: String {
        switch self {
        case .bypass: "Bypass"
        case .alwaysAsk: "Always Ask"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan"
        }
    }

    public var help: String {
        switch self {
        case .bypass: "Skip all permission prompts (use with caution)"
        case .alwaysAsk: "Pause for your approval before each write"
        case .acceptEdits: "Auto-approve file edits; ask for other tools"
        case .plan: "Read-only: deny all writes and edits"
        }
    }

    /// SF Symbol for the mode's composer chip + dropdown row. A shield motif
    /// echoing paseo's permission menu (bolt = skip/fast, checkmark = safe/ask,
    /// exclamation = auto-apply edits, half-shield = read-only plan).
    public var glyph: String {
        switch self {
        case .bypass: "bolt.shield"
        case .alwaysAsk: "checkmark.shield"
        case .acceptEdits: "exclamationmark.shield"
        case .plan: "shield.lefthalf.filled"
        }
    }
}

/// A snapshot of a pending permission request (always-ask). The future chat UI
/// surfaces these as Approve/Reject affordances; `options` are the agent's
/// offered choices (typically an `allow_*` and a `reject_*`).
///
/// `Equatable` by `toolCallId`: a pending request is identified by its tool-call
/// id (the ACP permission gate keys on it), and the offered options don't change
/// while a request is pending. This identity-based equality is what the
/// launcher's snapshot diff (`snapshot != pendingPermissions`) relies on to
/// avoid redundant view updates. (`PermissionOption` is not `Equatable`, so
/// `==` cannot be synthesized — implemented explicitly instead.)
public struct PendingPermission: Sendable, Equatable {
    public let toolCallId: String
    public let title: String?
    /// A human-readable tool name (e.g. "Edit file", "Create directory").
    /// Derived from the permission request's `ToolCallUpdate.title`/`.kind`.
    public let toolName: String?
    /// A one-liner summary of what the tool will do (e.g. the file path being
    /// edited). Derived from `ToolCallUpdate.locations`.
    public let inputSummary: String?
    public let options: [PermissionOption]

    public init(
        toolCallId: String, title: String?, toolName: String?,
        inputSummary: String?, options: [PermissionOption]
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.toolName = toolName
        self.inputSummary = inputSummary
        self.options = options
    }

    public static func == (lhs: PendingPermission, rhs: PendingPermission) -> Bool {
        lhs.toolCallId == rhs.toolCallId
    }
}

/// The `ClientDelegate` that owns the permission policy + pending-permissions
/// map. Conforms to `ClientDelegate` so it lands on the agent's
/// `session/request_permission`; only `handlePermissionRequest` is policy-driven
/// here — the fs/terminal/elicitation defaults (throw `.invalidResponse`) are
/// inherited, since this spike doesn't perform those operations.
///
/// **Concurrency:** a `final class` (required — `ClientDelegate: AnyObject`)
/// holding its mutable state behind an `OSAllocatedUnfairLock` so it's
/// `Sendable` without `@unchecked`. The pending map maps `toolCallId` → a
/// `CheckedContinuation` that `resolve(optionId:)` resumes. No actor hop needed
/// (the continuation + map are lock-protected), so resolution is immediate.
public final class ACPPermissionDelegate: ClientDelegate, @unchecked Sendable {

    /// A pending request's resolution channel.
    private struct Pending {
        let options: [PermissionOption]
        let toolName: String?
        let inputSummary: String?
        let continuation: CheckedContinuation<RequestPermissionResponse, Never>
    }

    private let policy: PermissionPolicy
    /// Synchronized state (pending map + one-shot onExit). A dedicated struct
    /// (not a tuple) — `OSAllocatedUnfairLock`'s tuple initializer can't infer
    /// the heterogeneous element types, so a named struct is the clean form.
    private struct LockedState: Sendable {
        var pending: [String: Pending] = [:]
        var onExit: (@Sendable (Int) -> Void)?
    }
    private let lock = OSAllocatedUnfairLock<LockedState>(initialState: LockedState())

    init(policy: PermissionPolicy) {
        self.policy = policy
    }

    // MARK: - ClientDelegate: the permission seam

    public func handlePermissionRequest(request: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        switch policy {
        case .bypass:
            // Auto-approve: resolve immediately with the request's allow option.
            if let allow = Self.allowOption(in: request.options) {
                DebugLog.agent("ACPBackend: bypass auto-allow toolCallId=\(request.toolCall.toolCallId)")
                return RequestPermissionResponse(outcome: PermissionOutcome(optionId: allow.optionId))
            }
            return RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))

        case .acceptEdits:
            // Auto-approve tools that look like file edits/writes; defer others.
            if Self.isEditTool(request.toolCall), let allow = Self.allowOption(in: request.options) {
                DebugLog.agent("ACPBackend: acceptEdits auto-allow edit toolCallId=\(request.toolCall.toolCallId)")
                return RequestPermissionResponse(outcome: PermissionOutcome(optionId: allow.optionId))
            }
            // Non-edit tool → defer to the user (same as alwaysAsk).
            return await Self.deferPermission(request: request, lock: lock)

        case .plan:
            // Deny all writes — auto-cancel every permission request.
            DebugLog.agent("ACPBackend: plan auto-deny toolCallId=\(request.toolCall.toolCallId)")
            return RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))

        case .alwaysAsk:
            // Defer: record pending and SUSPEND until resolve(optionId:). The
            // future UI calls ACPBackend.resolvePermission, which calls into
            // here. This is the pending-permission-blocking pattern from paseo.
            return await Self.deferPermission(request: request, lock: lock)
        }
    }

    // MARK: - Shared helpers

    /// Defer a permission request to the user (alwaysAsk / acceptEdits-non-edit).
    /// Records the pending continuation and returns when the user resolves it.
    private static func deferPermission(
        request: RequestPermissionRequest,
        lock: OSAllocatedUnfairLock<LockedState>
    ) async -> RequestPermissionResponse {
        let toolCall = request.toolCall
        let toolName = Self.toolName(for: toolCall)
        let inputSummary = Self.toolSummary(for: toolCall)
        return await withCheckedContinuation { (continuation: CheckedContinuation<RequestPermissionResponse, Never>) in
            lock.withLock { state in
                state.pending[request.toolCall.toolCallId] = Pending(
                    options: request.options,
                    toolName: toolName,
                    inputSummary: inputSummary,
                    continuation: continuation
                )
            }
            DebugLog.agent("ACPBackend: deferring toolCallId=\(request.toolCall.toolCallId) (\(request.options.count) options)")
        }
    }

    /// Heuristic: does this tool call look like a file edit/write? Used by
    /// `acceptEdits` to auto-approve edits while deferring other tools.
    private static func isEditTool(_ toolCall: ToolCallUpdate) -> Bool {
        let kind = toolCall.kind?.rawValue.lowercased() ?? ""
        let title = toolCall.title?.lowercased() ?? ""
        let combined = "\(kind) \(title)"
        return combined.contains("edit") || combined.contains("write")
            || combined.contains("create") || combined.contains("delete")
            || combined.contains("move") || combined.contains("rename")
    }

    // MARK: - ClientDelegate: fs / terminal (not performed in this spike)

    // This spike only exercises the permission seam. The fs read/write and
    // terminal delegate methods are required by `ClientDelegate` but unused
    // here — they throw `.invalidResponse` (the same default the protocol uses
    // for MCP/elicitation). A future slice wires these to perform (and gate)
    // file writes / terminal commands on the agent's behalf.

    public func handleFileReadRequest(_ path: String, sessionId: String, line: Int?, limit: Int?) async throws -> ReadTextFileResponse {
        throw ClientError.invalidResponse
    }

    public func handleFileWriteRequest(_ path: String, content: String, sessionId: String) async throws -> WriteTextFileResponse {
        throw ClientError.invalidResponse
    }

    public func handleTerminalCreate(command: String, sessionId: String, args: [String]?, cwd: String?, env: [EnvVariable]?, outputByteLimit: Int?) async throws -> CreateTerminalResponse {
        throw ClientError.invalidResponse
    }

    public func handleTerminalOutput(terminalId: TerminalId, sessionId: String) async throws -> TerminalOutputResponse {
        throw ClientError.invalidResponse
    }

    public func handleTerminalWaitForExit(terminalId: TerminalId, sessionId: String) async throws -> WaitForExitResponse {
        throw ClientError.invalidResponse
    }

    public func handleTerminalKill(terminalId: TerminalId, sessionId: String) async throws -> KillTerminalResponse {
        throw ClientError.invalidResponse
    }

    public func handleTerminalRelease(terminalId: TerminalId, sessionId: String) async throws -> ReleaseTerminalResponse {
        throw ClientError.invalidResponse
    }

    // MARK: - Resolution seam (for the future UI / tests)

    /// Resolve a pending request by selecting an option id. Returns true if a
    /// pending request with a matching option was resolved. In always-ask this
    /// is what the Approve/Reject UI calls.
    @discardableResult
    func resolve(optionId: String) -> Bool {
        let resolved: CheckedContinuation<RequestPermissionResponse, Never>? = lock.withLock { state in
            // Find the pending request that offers this option (a request is
            // identified by toolCallId; the UI passes the chosen option id).
            for (toolCallId, pending) in state.pending where pending.options.contains(where: { $0.optionId == optionId }) {
                state.pending.removeValue(forKey: toolCallId)
                return pending.continuation
            }
            return nil
        }
        guard let continuation = resolved else { return false }
        continuation.resume(returning: RequestPermissionResponse(outcome: PermissionOutcome(optionId: optionId)))
        return true
    }

    /// A snapshot of all pending requests (for the UI to render affordances).
    func pendingSnapshot() -> [PendingPermission] {
        lock.withLock { state in
            state.pending.map { (toolCallId, pending) in
                PendingPermission(
                    toolCallId: toolCallId,
                    title: pending.toolName,
                    toolName: pending.toolName,
                    inputSummary: pending.inputSummary,
                    options: pending.options
                )
            }
        }
    }

    /// Drain (drain-on-cancel): resume EVERY pending always-ask continuation as
    /// `PermissionOutcome(cancelled: true)` and clear the pending map. Called from
    /// `ACPBackend.cancel` when a session is torn down / the agent exits, so no
    /// `CheckedContinuation` leaks (a leaked continuation warns/traps at task end).
    ///
    /// Safe to call with nothing pending (no-op) and idempotent (the map is cleared
    /// under the lock before any continuation is resumed, so a concurrent
    /// `resolve(optionId:)` races only against an already-emptied map). Returns
    /// the number of continuations resumed (for tests).
    @discardableResult
    func cancelAllPending() -> Int {
        let drained = lock.withLock { state -> [(options: [PermissionOption], continuation: CheckedContinuation<RequestPermissionResponse, Never>)] in
            let pending = state.pending
            state.pending.removeAll()
            return pending.map { (toolCallId, value) in (value.options, value.continuation) }
        }
        for item in drained {
            _ = item.options  // toolCallId is implicit; nothing else needed
            item.continuation.resume(returning: RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true)))
        }
        return drained.count
    }

    // MARK: - onExit binding (wired in ACPBackend.start)

    /// Bind the launcher's one-shot exit callback. Stored under the lock; fired
    /// once from `ACPBackend.cancel` (and would fire on natural process exit in
    /// a future slice with a termination handler).
    func bindOnExit(_ callback: @escaping @Sendable (Int) -> Void) {
        lock.withLock { state in state.onExit = callback }
    }

    /// Fire the bound exit callback once (no-op if already fired / unbound).
    func fireOnExit(status: Int) {
        let callback = lock.withLock { state -> (@Sendable (Int) -> Void)? in
            let cb = state.onExit
            state.onExit = nil
            return cb
        }
        callback?(status)
    }

    // MARK: - Helpers

    /// A renderable tool name for a permission request. Prefers the ACP
    /// `title`; falls back to the `kind` (capitalized), then a generic "tool".
    /// Same logic as `ACPEventTranslator.toolName(for:)`.
    private static func toolName(for call: ToolCallUpdate) -> String? {
        if let title = call.title, !title.isEmpty { return title }
        if let kind = call.kind { return kind.rawValue.capitalized }
        return nil
    }

    /// A one-liner summary for a permission request — the file path being
    /// changed. Same logic as `ACPEventTranslator.toolSummary(for:)`.
    private static func toolSummary(for call: ToolCallUpdate) -> String? {
        if let path = call.locations?.first?.path, !path.isEmpty {
            return path
        }
        return nil
    }

    /// Pick the "allow" option from a permission request's options. An allow
    /// option's `kind` is `allow_once`/`allow_always`; fall back to any option
    /// whose kind starts with "allow".
    private static func allowOption(in options: [PermissionOption]) -> PermissionOption? {
        if let allowAlways = options.first(where: { $0.kind == "allow_always" }) {
            return allowAlways
        }
        if let allowOnce = options.first(where: { $0.kind == "allow_once" }) {
            return allowOnce
        }
        return options.first(where: { $0.kind.hasPrefix("allow") })
    }
}
