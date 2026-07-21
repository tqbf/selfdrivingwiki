import Foundation
import ACP
import ACPModel
import WikiFSCore

// MARK: - Shared tool-call rendering

/// Renders a stable tool name + one-liner input summary from an ACP
/// `ToolCallUpdate`. Shared by `ACPEventTranslator` (the event stream) and
/// `ACPPermissionDelegate` (the permission prompt) so both see identical
/// rendering — issue #426.
///
/// **Why `kind`-derived names:** ACP agents pick their own `title` ("Run
/// command", "Bash", "Edit file", …) so downstream consumers that key off the
/// tool name (`ToolInputSummary.summarize`, the transcript renderer, the #420
/// eval harness) see different strings per agent. `kind` is a stable
/// discriminant the SDK already decodes — we map it to the same canonical names
/// the Claude-CLI path uses (`Bash`, `webfetch`, `search`) so the two backends
/// converge. Falls back to `title` then `kind.rawValue.capitalized` when `kind`
/// is `nil` (preserves existing behavior for agents that omit it).
///
/// **Why `rawInput`:** ACP carries structured tool args in `rawInput` (an
/// `AnyCodable` boxing a dictionary). For `.execute` it's `{"command": "…"}`;
/// for `.fetch`, `{"url": "…"}`; for `.search`, `{"query": "…"}`; for file
/// ops, `{"file_path"|"path": "…"}`. We extract the substantive arg based on
/// `kind`, mirroring `ToolInputSummary.summarize` (AgentEvent.swift:404-447).
enum ToolCallRendering {

    /// A stable, renderable tool name derived from `kind`, falling back to
    /// `title` then `kind.rawValue.capitalized`, then `"tool"`.
    static func toolName(for call: ToolCallUpdate) -> String {
        // Prefer kind-derived stable names so downstream ToolInputSummary logic
        // works uniformly across ACP agents (each agent picks its own title —
        // "Run command", "Bash", etc. — but kind is stable).
        if let kind = call.kind {
            switch kind {
            case .execute: return "Bash"
            case .fetch:   return "webfetch"
            case .search:  return "search"
            default: break
            }
        }
        if let title = call.title, !title.isEmpty { return title }
        if let kind = call.kind { return kind.rawValue.capitalized }
        return "tool"
    }

    /// A one-liner input summary: the substantive arg from `rawInput` keyed by
    /// `kind`, falling back to the first location's path, then empty string.
    static func toolSummary(for call: ToolCallUpdate) -> String {
        // rawInput carries the structured args (command/url/query/path). Pull
        // the substantive one based on kind, mirroring ToolInputSummary.summarize.
        if let kind = call.kind, let input = call.rawInput {
            switch kind {
            case .execute:
                if let s = Self.stringField(input, keys: ["command"]) { return s }
            case .fetch:
                if let s = Self.stringField(input, keys: ["url"]) { return s }
            case .search:
                if let s = Self.stringField(input, keys: ["query", "pattern"]) { return s }
            case .read, .edit, .delete, .move:
                if let s = Self.stringField(input, keys: ["file_path", "path"]) { return s }
            default: break
            }
        }
        // Fall back to the first location's path (preserves existing behavior
        // for agents that populate locations but not rawInput).
        if let path = call.locations?.first?.path, !path.isEmpty {
            return path
        }
        return ""
    }

    /// Extract a string field from an `AnyCodable` regardless of how the SDK
    /// boxed the dictionary. AnyCodable.value may be `[String: any Sendable]`
    /// (from a dict literal) or a JSON-decoded form — we round-trip through
    /// JSON to get a `[String: Any]` we can subscript safely. No force-casts;
    /// returns nil for missing keys or non-string values.
    private static func stringField(_ raw: AnyCodable, keys: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(raw),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in keys {
            if let s = object[key] as? String { return s }
        }
        return nil
    }
}

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
/// - `agentThoughtChunk(.text)` → `.thinkingDelta` (streamed reasoning; the
///   launcher merges deltas into one `.thinking` row, issue #391).
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
            // Agent reasoning/thinking. Mapped to `.thinkingDelta` (issue #391)
            // so the launcher can coalesce chunks into a `.thinking` row and the
            // transcript renderer can display it as a collapsible, dimmed box —
            // distinct from regular assistant prose and tool calls.
            if let text = Self.text(from: block), !text.isEmpty {
                return [.thinkingDelta(text)]
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

    /// A renderable tool name. Delegates to `ToolCallRendering` (shared with
    /// `ACPPermissionDelegate`) — see issue #426 for why `kind`-derived stable
    /// names matter.
    private static func toolName(for call: ToolCallUpdate) -> String {
        ToolCallRendering.toolName(for: call)
    }

    /// A one-liner input summary for a tool call. Delegates to
    /// `ToolCallRendering` — extracts the substantive arg from `rawInput`
    /// (command/url/query/path) keyed by `kind`, falling back to the first
    /// location's path.
    private static func toolSummary(for call: ToolCallUpdate) -> String {
        ToolCallRendering.toolSummary(for: call)
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
///
/// **#606 — bounded auto-reject budget:** a deferred permission request that is
/// never resolved will hang a turn until the 1800s `TurnLivenessPolicy` ceiling.
/// For unattended pipelines (ingest/lint) that is unacceptable — nobody is
/// watching the transcript to click Approve/Reject. The `budget` parameter arms
/// a detached `Task` that sleeps for the chosen `Duration` and, if the user
/// hasn't resolved first, auto-rejects via `timeOut(toolCallId:)`. Interactive
/// chat passes `budget: nil` (unbounded — preserves the prior behavior so the
/// UI chip stays the source of truth). The race is safe by construction: the
/// existing `removeValue`-then-resume discipline in `resolve` /
/// `cancelAllPending` is mirrored by `timeOut` — whichever wins the race pulls
/// the entry out of the map under the lock, so the others find nothing to
/// resume (`CheckedContinuation` cannot be resumed twice). The `Task` handle is
/// stored on `Pending` so `resolve`/`cancelAllPending` cancel it on the winning
/// side, avoiding a stray timer firing after teardown.
/// See `plans/acp-permissions.md` §4.1 for the load-bearing invariants + the
/// TaskGroup-rejection rationale.
public final class ACPPermissionDelegate: ClientDelegate, @unchecked Sendable {

    /// A pending request's resolution channel.
    private struct Pending {
        let options: [PermissionOption]
        let toolName: String?
        let inputSummary: String?
        let continuation: CheckedContinuation<RequestPermissionResponse, Never>
        /// #606: the auto-reject timer Task, armed in `deferPermission` when a
        /// non-nil `budget` is set. `resolve`/`cancelAllPending` cancel it when
        /// they win the race; the timer task itself calls `timeOut(toolCallId:)`
        /// when it wins. nil for interactive chat (`budget: nil`) — no timer.
        let timer: Task<Void, Never>?
    }

    private let policy: PermissionPolicy
    /// #606: the per-request auto-reject budget. nil = no timer (current
    /// behavior — interactive chat). non-nil = a deferred permission auto-
    /// rejects after the duration elapses. Threading: only read at
    /// `handlePermissionRequest` entry (no lock needed — it's a `let`).
    private let budget: Duration?
    /// The per-run debug logger, for capturing permission request/response
    /// exchanges to `permissions.jsonl`. nil when debug logging is disabled —
    /// all calls are no-ops via optional chaining.
    private let debugLogger: DebugRunLogger?
    /// Synchronized state (pending map + one-shot onExit). A dedicated struct
    /// (not a tuple) — `OSAllocatedUnfairLock`'s tuple initializer can't infer
    /// the heterogeneous element types, so a named struct is the clean form.
    private struct LockedState: Sendable {
        var pending: [String: Pending] = [:]
        var onExit: (@Sendable (Int) -> Void)?
    }
    private let lock = PortableLock<LockedState>(initialState: LockedState())

    /// - Parameters:
    ///   - policy: the permission policy (`bypass`/`alwaysAsk`/`acceptEdits`/`plan`).
    ///   - debugLogger: optional per-run permission-exchange logger.
    ///   - budget: #606 auto-reject budget. nil (default) = no timer; non-nil =
    ///     after this `Duration` elapses with no user resolution, the pending
    ///     request is auto-rejected as `cancelled`. Interactive chat passes nil
    ///     (preserves the prior indefinite-suspend behavior — the live UI is the
    ///     release valve); ingest/lint pass `.seconds(60)` so an unattended
    ///     pipeline can't stall on a stuck permission.
    init(policy: PermissionPolicy, debugLogger: DebugRunLogger? = nil, budget: Duration? = nil) {
        self.policy = policy
        self.debugLogger = debugLogger
        self.budget = budget
    }

    // MARK: - ClientDelegate: the permission seam

    public func handlePermissionRequest(request: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        let response: RequestPermissionResponse
        switch policy {
        case .bypass:
            // Auto-approve: resolve immediately with the request's allow option.
            if let allow = Self.allowOption(in: request.options) {
                DebugLog.agent("ACPBackend: bypass auto-allow toolCallId=\(request.toolCall.toolCallId)")
                response = RequestPermissionResponse(outcome: PermissionOutcome(optionId: allow.optionId))
            } else {
                response = RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))
            }

        case .acceptEdits:
            // Auto-approve tools that look like file edits/writes; defer others.
            if Self.isEditTool(request.toolCall), let allow = Self.allowOption(in: request.options) {
                DebugLog.agent("ACPBackend: acceptEdits auto-allow edit toolCallId=\(request.toolCall.toolCallId)")
                response = RequestPermissionResponse(outcome: PermissionOutcome(optionId: allow.optionId))
            } else {
                // Non-edit tool → defer to the user (same as alwaysAsk). Same
                // auto-reject budget applies — a stalled non-edit permission
                // blocks the turn identically to an alwaysAsk stall (#606).
                response = await Self.deferPermission(request: request, lock: lock, budget: budget)
            }

        case .plan:
            // Deny all writes — auto-cancel every permission request.
            DebugLog.agent("ACPBackend: plan auto-deny toolCallId=\(request.toolCall.toolCallId)")
            response = RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))

        case .alwaysAsk:
            // Defer: record pending and SUSPEND until resolve(optionId:). The
            // future UI calls ACPBackend.resolvePermission, which calls into
            // here. This is the pending-permission-blocking pattern from paseo.
            response = await Self.deferPermission(request: request, lock: lock, budget: budget)
        }
        // Debug: log the full request/response exchange to permissions.jsonl.
        debugLogger?.logPermission(request: request, response: response, policy: policy.rawValue)
        return response
    }

    // MARK: - Shared helpers

    /// Defer a permission request to the user (alwaysAsk / acceptEdits-non-edit).
    /// Records the pending continuation and returns when the user resolves it,
    /// OR — if a `budget` is set and the user doesn't resolve in time — auto-
    /// rejects as `cancelled` after the budget elapses (#606).
    ///
    /// **The race + lifecycle:** the single `CheckedContinuation` is resumed
    /// EXACTLY once by one of three racers:
    ///   1. `resolve(optionId:)` — the user clicked Approve/Reject.
    ///   2. `cancelAllPending()` — full session teardown (drains everything).
    ///   3. `timeOut(toolCallId:)` — the budget timer elapsed first.
    /// All three racers do `state.pending.removeValue(forKey:)` (or
    /// `removeAll()`) UNDER the lock before resuming. Whichever wins pulls the
    /// entry out, so the others find nothing — `CheckedContinuation` cannot be
    /// resumed twice (see `docs/skills/swift-concurrency-pro/SKILL.md`
    /// `bug-patterns`: "Continuation resumed twice → restructure so only one
    /// path reaches the continuation"). The detach-timer form is the committed
    /// approach — a `withTaskGroup` sketch where a child task awaits
    /// `group.next()` on the same group does not compile under Swift 6.0 strict
    /// concurrency (non-Sendable + mutating access).
    ///
    /// **Why a `Task` and not a `TaskGroup`:** awaiting `group.next()` from
    /// inside one of the group's own child tasks is a data race (the group is
    /// non-`Sendable` and `next()` is mutating). The detached-timer form below
    /// preserves the existing `removeValue`-then-resume discipline verbatim and
    /// compiles cleanly. See `plans/acp-permissions.md` §4.1 note #5.
    private static func deferPermission(
        request: RequestPermissionRequest,
        lock: PortableLock<LockedState>,
        budget: Duration?
    ) async -> RequestPermissionResponse {
        let toolCall = request.toolCall
        let toolName = Self.toolName(for: toolCall)
        let inputSummary = Self.toolSummary(for: toolCall)
        return await withCheckedContinuation { (continuation: CheckedContinuation<RequestPermissionResponse, Never>) in
            // #606: arm the auto-reject timer when a budget is set. nil means
            // interactive chat (unbounded — the UI is the release valve).
            let timer: Task<Void, Never>? = budget.map { b in
                Task { [toolCallId = request.toolCall.toolCallId] in
                    do {
                        try await Task.sleep(for: b)
                    } catch {
                        // CancellationError — expected when resolve() /
                        // cancelAllPending() cancelled the timer first.
                        // Cooperative lifecycle event, not a hidden failure
                        // (§3 house-rule carve-out in plans/acp-permissions.md).
                        return
                    }
                    // Budget elapsed before the user resolved → auto-reject.
                    // `timeOut` mirrors `resolve`: removeValue under the lock,
                    // then resume. If the user/teardown already won, the entry
                    // is gone — `timeOut` no-ops.
                    Self.timeOut(toolCallId: toolCallId, lock: lock)
                }
            }
            lock.withLock { state in
                state.pending[request.toolCall.toolCallId] = Pending(
                    options: request.options,
                    toolName: toolName,
                    inputSummary: inputSummary,
                    continuation: continuation,
                    timer: timer)
            }
            DebugLog.agent("ACPBackend: deferring toolCallId=\(request.toolCall.toolCallId) (\(request.options.count) options) budget=\(budget.map { "\($0.components.seconds)s" } ?? "nil")")
        }
    }

    /// #606: auto-reject a pending request when its budget elapses. Mirrors
    /// `resolve(optionId:)`: pulls the pending entry out of the map UNDER the
    /// lock (so a concurrent `resolve`/`cancelAllPending` that already won the
    /// race finds nothing here — `guard let drained` no-ops), then resumes the
    /// continuation as `cancelled` AFTER the lock is released (the existing
    /// discipline — never resume under the lock, it can deadlock or trap on a
    /// sync re-entrant call). The removed `timer` is returned but not cancelled
    /// here (it's the running task itself — self-cancellation is a no-op).
    private static func timeOut(
        toolCallId: String,
        lock: PortableLock<LockedState>
    ) {
        let drained = lock.withLock { state -> (CheckedContinuation<RequestPermissionResponse, Never>, Task<Void, Never>?)? in
            guard let pending = state.pending.removeValue(forKey: toolCallId) else { return nil }
            return (pending.continuation, pending.timer)
        }
        guard let (cont, _) = drained else {
            // resolve() or cancelAllPending() already won the race — nothing to do.
            return
        }
        DebugLog.agent("ACPBackend: permission budget exceeded — auto-reject toolCallId=\(toolCallId)")
        cont.resume(returning: RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true)))
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
        let resolved: (CheckedContinuation<RequestPermissionResponse, Never>, Task<Void, Never>?)? = lock.withLock { state in
            // Find the pending request that offers this option (a request is
            // identified by toolCallId; the UI passes the chosen option id).
            for (toolCallId, pending) in state.pending where pending.options.contains(where: { $0.optionId == optionId }) {
                state.pending.removeValue(forKey: toolCallId)
                // #606: cancel the auto-reject timer — the user won the race.
                // Without this, the timer fires later, hits the now-empty map
                // look-up in `timeOut`, and no-ops (harmless but wasteful).
                return (pending.continuation, pending.timer)
            }
            return nil
        }
        guard let (continuation, timer) = resolved else { return false }
        timer?.cancel()
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
        let drained = lock.withLock { state -> [(options: [PermissionOption], continuation: CheckedContinuation<RequestPermissionResponse, Never>, timer: Task<Void, Never>?)] in
            let pending = state.pending
            state.pending.removeAll()
            return pending.map { (toolCallId, value) in (value.options, value.continuation, value.timer) }
        }
        // #606: cancel every armed timer BEFORE resuming the continuation so no
        // stray timer task fires after teardown (its `timeOut` would no-op
        // against the emptied map anyway, but cancelling is the cleaner lifecycle).
        for item in drained {
            item.timer?.cancel()
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

    /// A renderable tool name for a permission request. Delegates to
    /// `ToolCallRendering` (shared with `ACPEventTranslator`) — issue #426.
    /// Returns nil when rendering produces nothing (the delegate's Pending
    /// struct uses String? for these optional display fields).
    private static func toolName(for call: ToolCallUpdate) -> String? {
        let name = ToolCallRendering.toolName(for: call)
        return name.isEmpty ? nil : name
    }

    /// A one-liner summary for a permission request — the file path or command
    /// being changed. Delegates to `ToolCallRendering` — issue #426.
    private static func toolSummary(for call: ToolCallUpdate) -> String? {
        let summary = ToolCallRendering.toolSummary(for: call)
        return summary.isEmpty ? nil : summary
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
