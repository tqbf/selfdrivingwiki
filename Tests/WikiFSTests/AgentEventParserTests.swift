import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for the tolerant `claude -p --output-format stream-json` NDJSON parser.
/// The fixture lines are REAL shapes captured from the installed CLI (2.1.178), so
/// the parser is verified against the actual event schema — `system`/`init`,
/// `assistant` text + `tool_use` blocks, `user`/`tool_result`, the final `result`,
/// and a garbage line — not a guess. A malformed/partial line must never crash; it
/// falls back to `.raw`.
struct AgentEventParserTests {

    // MARK: - Recognized events

    @Test func systemInitCarriesModel() {
        let line = #"{"type":"system","subtype":"init","model":"claude-opus-4-8[1m]","cwd":"/private/tmp","tools":["Bash","Read"]}"#
        #expect(AgentEventParser.parse(line: line) == .systemInit(model: "claude-opus-4-8[1m]"))
    }

    @Test func systemInitFallsBackToGenericModelWhenMissing() {
        let line = #"{"type":"system","subtype":"init","cwd":"/private/tmp"}"#
        #expect(AgentEventParser.parse(line: line) == .systemInit(model: "claude"))
    }

    @Test func assistantTextBlockBecomesAssistantText() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll run that command."}]}}"#
        #expect(AgentEventParser.parse(line: line) == .assistantText("I'll run that command."))
    }

    @Test func assistantToolUseBlockSummarizesBashCommand() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hello from wikifs","description":"Print hello"}}]}}"#
        #expect(
            AgentEventParser.parse(line: line)
                == .toolUse(name: "Bash", inputSummary: "echo hello from wikifs")
        )
    }

    @Test func assistantReadToolUseSummarizesPath() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/mount/index.md"}}]}}"#
        #expect(
            AgentEventParser.parse(line: line)
                == .toolUse(name: "Read", inputSummary: "/mount/index.md")
        )
    }

    @Test func userToolResultStringContentBecomesToolResult() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01X","is_error":false,"content":"hello from wikifs"}]}}"#
        #expect(
            AgentEventParser.parse(line: line)
                == .toolResult(isError: false, summary: "hello from wikifs")
        )
    }

    @Test func userToolResultErrorIsFlagged() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01X","is_error":true,"content":"command not found"}]}}"#
        #expect(
            AgentEventParser.parse(line: line)
                == .toolResult(isError: true, summary: "command not found")
        )
    }

    @Test func userToolResultArrayContentIsFlattened() {
        // The wire allows tool_result.content as an array of text blocks too.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01X","content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}]}}"#
        #expect(
            AgentEventParser.parse(line: line)
                == .toolResult(isError: false, summary: "line one\nline two")
        )
    }

    @Test func resultEventCarriesFinalTextAndErrorFlag() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"done","num_turns":2,"duration_ms":6390}"#
        #expect(AgentEventParser.parse(line: line) == .result(isError: false, text: "done"))
    }

    @Test func resultErrorIsFlagged() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"the run failed"}"#
        #expect(AgentEventParser.parse(line: line) == .result(isError: true, text: "the run failed"))
    }

    @Test func messageStopParsesToMessageStop() {
        // The per-turn boundary event emitted after each interactive response.
        let line = #"{"type":"message_stop"}"#
        let event = AgentEventParser.parse(line: line)
        #expect(event == .messageStop)
        // It carries no renderable text and is filtered from the transcript (it
        // is the turn-boundary signal, not content).
        #expect(event?.plainText == "")
        #expect(event?.isInternalTranscriptEvent == true)
    }

    // MARK: - Tolerance: garbage, partials, unmodeled types

    @Test func garbageLineFallsBackToRaw() {
        let line = "this is not json at all {"
        #expect(AgentEventParser.parse(line: line) == .raw(line))
    }

    @Test func truncatedJSONLineFallsBackToRaw() {
        // A partial flush that ends mid-object must not throw.
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"te"#
        #expect(AgentEventParser.parse(line: line) == .raw(line))
    }

    @Test func emptyLineIsSkipped() {
        #expect(AgentEventParser.parse(line: "") == nil)
        #expect(AgentEventParser.parse(line: "   \n") == nil)
    }

    @Test func unmodeledEventTypesAreSkipped() {
        // status, rate_limit_event, post_turn_summary, and non-text-delta
        // stream_events carry no line of their own — they return nil rather than
        // cluttering the feed. (Text deltas ARE modeled — see
        // `contentBlockTextDeltaBecomesAssistantTextDelta` below, issue #121.)
        for line in [
            #"{"type":"stream_event","event":{"type":"content_block_start"}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{"}}}"#,
            #"{"type":"rate_limit_event"}"#,
            #"{"type":"system","subtype":"status"}"#,
            #"{"type":"system","subtype":"post_turn_summary"}"#,
        ] {
            #expect(AgentEventParser.parse(line: line) == nil)
        }
    }

    // MARK: - Partial-message streaming (issue #121)

    @Test func contentBlockTextDeltaBecomesAssistantTextDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"he"}}}"#
        #expect(AgentEventParser.parse(line: line) == .assistantTextDelta("he"))
    }

    @Test func emptyTextDeltaIsSkipped() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":""}}}"#
        #expect(AgentEventParser.parse(line: line) == nil)
    }

    @Test func assistantWithNoRenderableBlockIsSkipped() {
        // A well-formed assistant event whose only block is an unmodeled kind
        // (a `thinking` block — common on Query runs) is SKIPPED, not dumped as raw:
        // its envelope carries usage/stop_reason noise that would clutter the feed,
        // and the modeled text/tool_use events already carry the renderable content.
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"…"}],"stop_reason":null,"usage":{"input_tokens":2}}}"#
        #expect(AgentEventParser.parse(line: line) == nil)
    }

    // MARK: - Subagent fan-out (Opus→Sonnet)

    @Test func taskStartedBecomesSubagentDelegation() {
        // Real shape captured from the --agents smoke test (CLI 2.1.178): the system
        // `task_started` event carries subagent_type + description.
        let line = #"{"type":"system","subtype":"task_started","task_id":"a25","subagent_type":"ingest-worker","description":"Write the Calvin Cycle page","task_type":"local_agent"}"#
        #expect(
            AgentEventParser.parse(line: line)
                == .subagent(subagentType: "ingest-worker", description: "Write the Calvin Cycle page", isCompletion: false)
        )
    }

    @Test func taskNotificationCompletedBecomesSubagentCompletion() {
        let line = #"{"type":"system","subtype":"task_notification","task_id":"a25","status":"completed","summary":"Wrote Calvin Cycle"}"#
        #expect(
            AgentEventParser.parse(line: line)
                == .subagent(subagentType: "subagent", description: "Wrote Calvin Cycle", isCompletion: true)
        )
    }

    @Test func taskUpdatedIntermediateIsSkipped() {
        // The intermediate status patch is noise; only start + terminal notification
        // are surfaced.
        let line = #"{"type":"system","subtype":"task_updated","task_id":"a25","patch":{"status":"completed"}}"#
        #expect(AgentEventParser.parse(line: line) == nil)
    }

    @Test func agentToolUseSummarizesSubagentTypeAndDescription() {
        // The delegation tool itself (the CLI names it `Agent`).
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"ingest-worker","description":"Write the Calvin Cycle page","prompt":"…"}}]}}"#
        #expect(
            AgentEventParser.parse(line: line)
                == .toolUse(name: "Agent", inputSummary: "ingest-worker: Write the Calvin Cycle page")
        )
    }

    // MARK: - ToolInputSummary

    @Test func toolInputSummaryFallsBackToSortedKeyValueForUnknownTool() {
        let input: [String: JSONValue] = ["beta": .string("2"), "alpha": .string("1")]
        #expect(ToolInputSummary.summarize(name: "MysteryTool", input: input) == "alpha=1 beta=2")
    }

    @Test func toolInputSummaryElidesLongCommands() {
        let long = String(repeating: "x", count: 200)
        let summary = ToolInputSummary.summarize(name: "Bash", input: ["command": .string(long)])
        #expect(summary.count <= ToolInputSummary.maxLength)
        #expect(summary.hasSuffix("…"))
    }

    @Test func toolInputSummaryEmptyForNoInput() {
        #expect(ToolInputSummary.summarize(name: "Bash", input: nil) == "")
        #expect(ToolInputSummary.summarize(name: "Bash", input: [:]) == "")
    }

    // MARK: - AgentEvent.plainText (Copy Transcript export)

    @Test func plainTextUserText() {
        #expect(AgentEvent.userText("hello").plainText == "You:\nhello")
    }

    @Test func plainTextSystemInit() {
        #expect(AgentEvent.systemInit(model: "claude").plainText == "Started · claude")
    }

    @Test func plainTextAssistantText() {
        #expect(AgentEvent.assistantText("some prose").plainText == "some prose")
    }

    @Test func plainTextToolUseWithSummary() {
        #expect(AgentEvent.toolUse(name: "Bash", inputSummary: "ls").plainText == "Bash  ls")
    }

    @Test func plainTextToolUseWithoutSummary() {
        #expect(AgentEvent.toolUse(name: "Bash", inputSummary: "").plainText == "Bash")
    }

    @Test func plainTextToolResultOk() {
        #expect(AgentEvent.toolResult(isError: false, summary: "done").plainText == "done")
    }

    @Test func plainTextToolResultError() {
        #expect(AgentEvent.toolResult(isError: true, summary: "").plainText == "Error: (error)")
    }

    @Test func plainTextSubagentStart() {
        #expect(
            AgentEvent.subagent(subagentType: "source-reader", description: "reading paper", isCompletion: false)
                .plainText == "source-reader reading — reading paper"
        )
    }

    @Test func plainTextSubagentDone() {
        #expect(
            AgentEvent.subagent(subagentType: "source-reader", description: "", isCompletion: true)
                .plainText == "source-reader digested"
        )
    }

    @Test func plainTextResult() {
        #expect(AgentEvent.result(isError: false, text: "all good").plainText == "Result:\nall good")
    }

    @Test func plainTextResultEmpty() {
        #expect(AgentEvent.result(isError: true, text: "").plainText == "Failed")
    }

    @Test func plainTextRaw() {
        #expect(AgentEvent.raw("garbage line").plainText == "garbage line")
    }

    // MARK: - endsGeneration predicate (per-turn boundary logic)

    @Test func endsGenerationTrueForResultAndMessageStop() {
        // The two events that end a generation: the terminal `.result` (session
        // end) and the per-turn `.messageStop`.
        #expect(AgentEvent.endsGeneration(.result(isError: false, text: "done")))
        #expect(AgentEvent.endsGeneration(.result(isError: true, text: "")))
        #expect(AgentEvent.endsGeneration(.messageStop))
    }

    @Test func endsGenerationFalseForEverythingElse() {
        // Prose, tool calls, tool results, subagent lifecycle, raw lines, user
        // text, and init never end a generation.
        #expect(!AgentEvent.endsGeneration(.systemInit(model: "claude")))
        #expect(!AgentEvent.endsGeneration(.assistantText("prose")))
        #expect(!AgentEvent.endsGeneration(.toolUse(name: "Bash", inputSummary: "ls")))
        #expect(!AgentEvent.endsGeneration(.toolResult(isError: false, summary: "ok")))
        #expect(!AgentEvent.endsGeneration(.subagent(subagentType: "x", description: "y", isCompletion: false)))
        #expect(!AgentEvent.endsGeneration(.raw("garbage")))
        #expect(!AgentEvent.endsGeneration(.userText("hi")))
    }
}
