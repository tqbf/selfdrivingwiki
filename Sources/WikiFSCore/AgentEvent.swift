import Foundation

/// The structured reason a turn failed — surfaced to the user via
/// `AgentEvent.turnFailed` and persisted in `chat_messages.event_json` so it
/// survives reload. (`ACPBackendError` is the engine-layer error that gets
/// mapped into this at the `turnEndEvents` seam.) (#422)
public enum TurnFailureReason: Sendable, Equatable, Codable {
    /// The turn went silent — no `session/update` notification arrived for
    /// `idleSeconds`. The turn was cancelled; the user can retry.
    case stalled(idleSeconds: TimeInterval)
    /// The turn exceeded the hard ceiling duration. The turn was cancelled.
    case ceilingExceeded(totalSeconds: TimeInterval)
    /// The ACP subprocess returned an error (prompt failure, auth, etc.).
    case agentError(String)

    /// A plain-English description for the UI banner and `plainText` rendering.
    public var description: String {
        switch self {
        case .stalled(let idle):
            return "The agent was idle for \(Int(idle))s and was cancelled."
        case .ceilingExceeded(let total):
            return "The agent exceeded the maximum turn duration (\(Int(total))s) and was cancelled."
        case .agentError(let message):
            return message
        }
    }

    /// A short label for the banner's `<strong>` heading.
    public var label: String {
        switch self {
        case .stalled:
            return "Turn timed out."
        case .ceilingExceeded:
            return "Turn ceiling exceeded."
        case .agentError:
            return "Agent error."
        }
    }
}

/// One rendered line of a `claude -p --output-format stream-json` run
/// (`plans/llm-wiki.md` Phase C — "`claude -p` orchestration", which anticipates
/// One rendered line of an ACP agent stream
/// (`plans/llm-wiki.md` Phase C — agent orchestration, which anticipates
/// `stream-json` "for a richer tool-call view"). The UI renders an ordered list of
/// these live, so a run's activity is visible as it happens instead of a silent
/// panel that "just sits there waiting for claude to do nothing".
///
/// This is the typed projection of the raw NDJSON: `AgentEventParser` decodes ONLY
/// the fields we render and is tolerant — any line it doesn't recognize (including
/// a malformed/partial one) becomes `.raw`, so a bad line never crashes a run.
/// `Codable` (synthesized) because persisted chat history stores each event
/// verbatim as JSON in `chat_messages.event_json` — the history view then
/// re-renders through the exact same typed pipeline as the live transcript.
public enum AgentEvent: Equatable, Sendable, Codable {
    /// A user turn sent into an interactive agent session.
    case userText(String)

    /// The `{"type":"system","subtype":"init"}` event — the run has started. Carries
    /// the resolved model so the UI can show what's working.
    case systemInit(model: String)

    /// A block of assistant prose (`assistant` message → `text` content block).
    case assistantText(String)

    /// A block of agent reasoning/"thinking" — the model's chain-of-thought,
    /// distinct from regular assistant prose. Surfaced from ACP's
    /// `agentThoughtChunk` (issue #391) and from the CLI's `thinking` content
    /// blocks. Rendered as a collapsible, dimmed/italic box in the transcript
    /// so it's visible without dominating the conversation flow.
    case thinking(String)

    /// One incremental chunk of agent reasoning (`stream_event` →
    /// `content_block_delta` → `thinking_delta`, or ACP `agentThoughtChunk`).
    /// Never stored in `AgentLauncher.events` directly — `AgentLauncher` merges
    /// each delta into the in-progress `.thinking` row (or starts one), mirroring
    /// the `.assistantTextDelta` → `.assistantText` coalescing (issue #121).
    /// Not rendered on its own; treated as internal like `.assistantTextDelta`.
    case thinkingDelta(String)

    /// One incremental chunk of assistant prose (`stream_event` →
    /// `content_block_delta` → `text_delta`), emitted only when the run requests
    /// `--include-partial-messages`. Never stored in `AgentLauncher.events` directly —
    /// `AgentLauncher` merges each delta into the in-progress `.assistantText` row (or
    /// starts one) so the transcript keeps its "one row per turn" shape while still
    /// growing incrementally (issue #121). Not rendered on its own; treated as
    /// internal/not-directly-renderable like `.messageStop`.
    case assistantTextDelta(String)

    /// The agent invoked a tool (`assistant` message → `tool_use` content block).
    /// `inputSummary` is a concise human-readable rendering of the tool's input
    /// (e.g. a `Bash` command, a `Read` path) so the line reads like
    /// `Bash  wikictl page upsert --title "…"`.
    case toolUse(name: String, inputSummary: String)

    /// A tool finished (`user` message → `tool_result` content block). `summary` is
    /// the (possibly truncated) result text; `isError` flags a failed tool.
    case toolResult(isError: Bool, summary: String)

    /// A subagent delegation lifecycle event (`{"type":"system",
    /// "subtype":"task_started" | "task_completed"}`), emitted when the Opus curator
    /// fans out to a Sonnet `source-reader` digester via the Task/Agent tool.
    /// Surfacing these makes the Opus→Sonnet fan-out visible in the panel as distinct
    /// rows rather than an opaque `Agent` tool call. `subagentType` is the worker name
    /// (`source-reader`); `description` is the curator's one-line task label;
    /// `isCompletion` distinguishes the start row from the finish row.
    case subagent(subagentType: String, description: String, isCompletion: Bool)

    /// The terminal `{"type":"result"}` event — the run's final answer/report.
    /// `isError` is the run-level error flag.
    case result(isError: Bool, text: String)

    /// A `{"type":"message_stop"}` event — marks the end of one turn in an
    /// interactive session. This is the **backend-synthesized turn-boundary
    /// marker**: every `AgentBackend` impl MUST yield `.messageStop` at each
    /// turn end. The CLI backend gets it from Claude's `message_stop` wire line
    /// (emitted after every response when running with `--input-format
    /// stream-json` + `--output-format stream-json`); a future direct-API
    /// backend synthesizes it on per-turn stream completion. It is the
    /// turn-boundary signal: the agent finished its response and is waiting for
    /// the next user input. Without it, the only completion signal is `.result`,
    /// which fires at session end — so `isGenerating` would stay `true` forever
    /// between turns and the per-turn edit lock would never release.
    /// Not rendered in the transcript (filtered by `isInternalTranscriptEvent`).
    case messageStop

    /// A turn ended abnormally — timed out, hit the ceiling, or the ACP
    /// subprocess returned an error. Distinct from `.raw` (undecodable debug
    /// residue): this is a structured failure the user needs to see and that
    /// must survive reload. The companion `.messageStop` that follows it
    /// releases the generation gate. (#422)
    case turnFailed(reason: TurnFailureReason)

    /// A line we didn't model (an unrecognized event type, or a malformed/partial
    /// line). Carries the raw text verbatim so nothing is silently swallowed.
    case raw(String)

    /// A plain-text, copy-friendly rendering of this event — no icons, colors, or
    /// layout. Used by the "Copy Transcript" affordance so the styled feed's
    /// contents can be copied out as plain text (the styled `LazyVStack` can't be
    /// drag-selected across rows in SwiftUI).
    public var plainText: String {
        switch self {
        case .userText(let text):
            return "You:\n\(text)"
        case .systemInit(let model):
            return "Started · \(model)"
        case .assistantText(let text):
            return text
        case .thinking(let text):
            return "Thinking:\n\(text)"
        case .thinkingDelta:
            return ""  // internal — merged into `.thinking` before it's rendered
        case .assistantTextDelta:
            return ""  // internal — merged into `.assistantText` before it's rendered
        case .toolUse(let name, let inputSummary):
            return inputSummary.isEmpty ? name : "\(name)  \(inputSummary)"
        case .toolResult(let isError, let summary):
            let body = summary.isEmpty ? (isError ? "(error)" : "(ok)") : summary
            return isError ? "Error: \(body)" : body
        case .subagent(let subagentType, let description, let isCompletion):
            let verb = isCompletion ? "digested" : "reading"
            return description.isEmpty
                ? "\(subagentType) \(verb)"
                : "\(subagentType) \(verb) — \(description)"
        case .result(let isError, let text):
            let label = isError ? "Failed" : "Result"
            return text.isEmpty ? label : "\(label):\n\(text)"
        case .messageStop:
            return ""  // internal — not rendered
        case .turnFailed(let reason):
            return "\(reason.label) \(reason.description)"
        case .raw(let line):
            return line
        }
    }

    /// The turn-boundary predicate: `true` for the two events that mark the end
    /// of a generation turn — `.result` (the terminal event at session end) and
    /// `.messageStop` (the per-turn boundary in an interactive session).
    ///
    /// This is the **backend-synthesized turn-boundary contract**: every
    /// `AgentBackend` impl MUST yield `.messageStop` at each turn end (the CLI
    /// backend gets it from the wire; a future direct-API backend synthesizes it
    /// on per-turn stream completion). The launcher keys its generation-gate
    /// release, edit-lock release, and transcript flush off this predicate — so
    /// a backend that fails to synthesize `.messageStop` strands the edit lock
    /// and the spinner.
    ///
    /// Everything else — prose, tool calls, tool results, subagent lifecycle,
    /// raw lines — leaves a generation in progress. See
    /// `AgentLauncher.setGenerating`. Pure and unit-testable without a live
    /// process. Codable-safe: `.messageStop` is `isPersistable == false`
    /// (`ChatModels.swift`), so it is never written to `event_json` — keeping
    /// the case name unchanged means zero migration for existing rows.
    public static func endsGeneration(_ event: AgentEvent) -> Bool {
        if case .result = event { return true }
        if case .messageStop = event { return true }
        return false
    }

    /// True for tool-use and tool-result events (issue #381). Used to filter
    /// tool calls from the transcript when `hideToolCalls` is enabled.
    public var isToolCall: Bool {
        switch self {
        case .toolUse, .toolResult: return true
        default: return false
        }
    }

    /// Fold a stream of raw events into display rows: consecutive
    /// `.assistantTextDelta` chunks accumulate into ONE `.assistantText` row,
    /// and the final `.assistantText` for a streamed block replaces the
    /// accumulated row instead of duplicating it; thinking deltas are
    /// coalesced the same way. This is the same merge
    /// `AgentLauncher.mergeOrAppend` applies to its live `events` array —
    /// any OTHER consumer of the raw stream (queue transcripts, rehydrated
    /// histories) must apply it too, or a streamed reply renders as one row
    /// per word-fragment.
    public static func mergingStreamDeltas(_ events: [AgentEvent]) -> [AgentEvent] {
        var merged: [AgentEvent] = []
        var isStreamingRow = false
        var isStreamingThinkingRow = false
        for event in events {
            switch event {
            case .assistantTextDelta(let delta):
                if isStreamingRow, case .assistantText(let existing) = merged.last {
                    merged[merged.count - 1] = .assistantText(existing + delta)
                } else {
                    merged.append(.assistantText(delta))
                    isStreamingRow = true
                }
                isStreamingThinkingRow = false
            case .assistantText:
                if isStreamingRow, case .assistantText = merged.last {
                    merged[merged.count - 1] = event
                } else {
                    merged.append(event)
                }
                isStreamingRow = false
                isStreamingThinkingRow = false
            case .thinkingDelta(let delta):
                if isStreamingThinkingRow, case .thinking(let existing) = merged.last {
                    merged[merged.count - 1] = .thinking(existing + delta)
                } else {
                    merged.append(.thinking(delta))
                    isStreamingThinkingRow = true
                }
                isStreamingRow = false
            case .thinking:
                if isStreamingThinkingRow, case .thinking = merged.last {
                    merged[merged.count - 1] = event
                } else {
                    merged.append(event)
                }
                isStreamingThinkingRow = false
                isStreamingRow = false
            default:
                merged.append(event)
                isStreamingRow = false
                isStreamingThinkingRow = false
            }
        }
        return merged
    }
}

/// Tolerant line-at-a-time parser for ACP agent NDJSON streams.
/// the fields the UI renders and falls back to `.raw` for anything it can't map —
/// a partial flush, a future event type, or outright garbage never throws.
///
/// Built against the REAL event schema captured from the installed CLI (2.1.178),
/// not a guess: a `system`/`init` event, `assistant` messages whose `content` holds
/// `text` and `tool_use` blocks, `user` messages whose `content` holds
/// `tool_result` blocks, and a final `result` event with `is_error`. Partial-message
/// `stream_event` → `content_block_delta` → `text_delta` chunks are surfaced as
/// `.assistantTextDelta` (issue #121 — the interactive chat path needs them to
/// stream incrementally instead of buffering); other bookkeeping types
/// (`rate_limit_event`, `system`/`status`, non-text-delta `stream_event`s) are still
/// NOT surfaced.
public enum AgentEventParser {
    /// Parse one NDJSON line into an `AgentEvent`. Never throws: an empty line
    /// returns `nil` (skip it); anything that fails to decode into a known shape
    /// returns `.raw(line)`.
    public static func parse(line rawLine: String) -> AgentEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        guard
            let data = line.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else {
            return .raw(line)
        }

        switch envelope.type {
        case "system" where envelope.subtype == "init":
            return .systemInit(model: envelope.model ?? "claude")

        // Subagent fan-out: the curator delegating to a Sonnet digester emits a
        // `task_started` (the delegation begins) and a terminal `task_notification`
        // (the worker finished). Surface both so the Opus→Sonnet fan-out is visible.
        // `task_updated` is an intermediate status patch we skip (the notification
        // already conveys completion).
        case "system" where envelope.subtype == "task_started":
            return .subagent(
                subagentType: envelope.subagentType ?? "subagent",
                description: envelope.description ?? envelope.summary ?? "",
                isCompletion: false)

        case "system" where envelope.subtype == "task_notification" && envelope.status == "completed":
            return .subagent(
                subagentType: envelope.subagentType ?? "subagent",
                description: envelope.summary ?? envelope.description ?? "",
                isCompletion: true)

        case "assistant":
            // An assistant event with no renderable text/tool_use block (e.g. a
            // thinking-only or signature block) is well-formed but carries nothing
            // to show — SKIP it rather than dumping its whole JSON envelope as a
            // `.raw` row. `.raw` is reserved for lines that fail to decode at all.
            return assistantEvent(from: envelope)

        case "user":
            return toolResultEvent(from: envelope)

        case "result":
            return .result(isError: envelope.isError ?? false, text: envelope.result ?? "")

        case "message_stop":
            return .messageStop

        case "stream_event":
            return streamEventDelta(from: envelope)

        default:
            // Unmodeled event types (status, rate_limit_event, post_turn_summary, …)
            // are not rendered as their own lines.
            return nil
        }
    }

    /// Map a `stream_event` envelope to a text or thinking delta. Only
    /// `content_block_delta` → `text_delta` and `thinking_delta` are modeled —
    /// other inner event kinds (`message_start`, `content_block_start`/`_stop`,
    /// `input_json_delta` for streamed tool input, `message_delta`) carry nothing
    /// the transcript renders, so they fall through to `nil` same as any other
    /// unmodeled line.
    private static func streamEventDelta(from envelope: Envelope) -> AgentEvent? {
        guard let inner = envelope.event, inner.type == "content_block_delta",
              let delta = inner.delta,
              let text = delta.text, !text.isEmpty
        else { return nil }
        switch delta.type {
        case "text_delta":
            return .assistantTextDelta(text)
        case "thinking_delta":
            return .thinkingDelta(text)
        default:
            return nil
        }
    }

    // MARK: - Content-block mapping

    /// Map an `assistant` envelope to the FIRST renderable content block (text or
    /// tool_use). One stream-json `assistant` event carries a single content block
    /// in practice, so taking the first is correct and keeps the mapping simple.
    private static func assistantEvent(from envelope: Envelope) -> AgentEvent? {
        guard let blocks = envelope.message?.content else { return nil }
        for block in blocks {
            switch block.type {
            case "text":
                let text = (block.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                return .assistantText(text)

            case "thinking":
                // The model's chain-of-thought reasoning (extended thinking /
                // interleaved thinking). Surfaced as `.thinking` for a collapsible
                // dimmed rendering (issue #391). `thinking` blocks carry their text
                // in the same `text` field as regular prose.
                let text = (block.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                return .thinking(text)

            case "tool_use":
                let name = block.name ?? "tool"
                return .toolUse(name: name, inputSummary: ToolInputSummary.summarize(name: name, input: block.input))

            default:
                continue
            }
        }
        return nil
    }

    /// Map a `user` envelope to the first `tool_result` block.
    private static func toolResultEvent(from envelope: Envelope) -> AgentEvent? {
        guard let blocks = envelope.message?.content else { return nil }
        for block in blocks where block.type == "tool_result" {
            return .toolResult(
                isError: block.isError ?? false,
                summary: block.content?.text ?? ""
            )
        }
        return nil
    }
}

// MARK: - Tolerant decoding shapes

extension AgentEventParser {
    /// The union of fields we read across every event type. Every field is optional
    /// so a line missing any of them still decodes — that tolerance is what lets the
    /// parser map partial/unfamiliar lines without throwing.
    private struct Envelope: Decodable {
        let type: String
        let subtype: String?
        let model: String?
        let message: Message?
        let result: String?
        let isError: Bool?
        // Subagent (Task) lifecycle fields — present on `system`/`task_*` events.
        let subagentType: String?
        let description: String?
        let status: String?
        let summary: String?
        // Present on `stream_event` lines: the nested partial-message event.
        let event: StreamEvent?

        enum CodingKeys: String, CodingKey {
            case type, subtype, model, message, result, description, status, summary, event
            case isError = "is_error"
            case subagentType = "subagent_type"
        }
    }

    /// The `event` payload of a `stream_event` line — `{"type":"content_block_delta",
    /// "delta":{"type":"text_delta","text":"…"}}` is the only shape we render;
    /// other inner types decode with `delta == nil` and are ignored by the caller.
    private struct StreamEvent: Decodable {
        let type: String
        let delta: Delta?

        struct Delta: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct Message: Decodable {
        let role: String?
        let content: [ContentBlock]?
    }

    private struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let name: String?
        let input: [String: JSONValue]?
        let isError: Bool?
        /// `tool_result.content` is a string in practice but the wire allows a block
        /// array too; `StringOrBlocks` flattens both to plain text.
        let content: StringOrBlocks?

        enum CodingKeys: String, CodingKey {
            case type, text, name, input, content
            case isError = "is_error"
        }
    }
}

/// A `tool_result.content` that may arrive as a bare string OR as an array of
/// `{type:"text", text:"…"}` blocks. `.text` flattens either to a single string so
/// the parser doesn't care which shape the CLI emitted.
struct StringOrBlocks: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else if let blocks = try? container.decode([TextBlock].self) {
            text = blocks.compactMap(\.text).joined(separator: "\n")
        } else {
            text = ""
        }
    }

    private struct TextBlock: Decodable {
        let text: String?
    }
}

/// A minimal JSON value, just enough to render a `tool_use` input summary without
/// over-modeling every tool's schema. Decodes the scalar shapes a tool input uses
/// (string/number/bool) and collapses nested objects/arrays to a short marker.
public enum JSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object
    case array

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if (try? container.decode([JSONValue].self)) != nil {
            self = .array
        } else {
            self = .object
        }
    }

    /// The scalar rendered as a plain string, or nil for non-scalar values (which a
    /// summary should skip rather than print as `[object]`).
    public var scalarString: String? {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            // Render integers without a trailing `.0`.
            if value == value.rounded() { return String(Int(value)) }
            return String(value)
        case .null, .object, .array: return nil
        }
    }
}

/// Renders a concise, human-readable one-liner for a `tool_use` block's input, so
/// the activity feed reads like `Bash  wikictl page upsert --title "…"` rather than
/// a JSON blob. PURE and unit-tested: it special-cases the tools this app's agent
/// actually uses (`Bash` → command, `Read`/`Write`/`Edit`/`Glob` → path/pattern)
/// and falls back to a compact `key=value` join for anything else.
public enum ToolInputSummary {
    /// Maximum rendered length before eliding — keeps a single feed row readable.
    static let maxLength = 120

    public static func summarize(name: String, input: [String: JSONValue]?) -> String {
        guard let input, !input.isEmpty else { return "" }

        let summary: String
        switch name {
        case "Bash":
            summary = input["command"]?.scalarString ?? fallback(input)
        case "Read", "Write", "Edit":
            summary = input["file_path"]?.scalarString ?? fallback(input)
        case "Glob":
            summary = input["pattern"]?.scalarString ?? fallback(input)
        case "Grep":
            summary = input["pattern"]?.scalarString ?? fallback(input)
        // The delegation tool (the CLI names it `Agent`; `Task` is the historical
        // alias). Render `<subagent_type>: <description>` so a fan-out row reads like
        // `Agent  source-reader: Digest pages 1-20` instead of a JSON blob.
        case "Agent", "Task":
            let worker = input["subagent_type"]?.scalarString
            let detail = input["description"]?.scalarString ?? input["prompt"]?.scalarString
            summary = [worker, detail].compactMap { $0 }.joined(separator: ": ")
        default:
            summary = fallback(input)
        }
        return elide(summary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Deterministic `key=value` join for tools we don't special-case, sorted by key
    /// so the rendering is stable across runs.
    private static func fallback(_ input: [String: JSONValue]) -> String {
        input
            .compactMap { key, value in value.scalarString.map { "\(key)=\($0)" } }
            .sorted()
            .joined(separator: " ")
    }

    private static func elide(_ string: String) -> String {
        guard string.count > maxLength else { return string }
        return string.prefix(maxLength - 1) + "…"
    }
}
