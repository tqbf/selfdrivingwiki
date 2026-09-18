# Apple Intelligence summarizer (titles + one-line summaries)

Status: in implementation. Date: 2026-09-17.

## Goal

Use the on-device Apple Intelligence model (the Foundation Models framework,
`SystemLanguageModel`) to generate chat titles and per-message summaries. This
replaces the one-shot ACP subprocess for users who pin it. The app deployment
floor stays macOS 26.0, where the base Foundation Models API first ships.

## Background

Today `MessageSummarizer` has two modes. The mode comes STRICTLY from the
`stageProviderIds["summarizer"]` pin (chat-summary plan §5.1):

- **Default** — empty or absent pin. `ChatSummary.summaryExtract` truncates the
  first sentence. No model runs.
- **Model** — non-empty pin. A one-shot ACP session asks the pinned provider
  for a one-sentence summary or a chat title.

The ACP path needs a provider, a credential, a sandbox scratch world, and a
subprocess. The Foundation Models path needs none of these. It runs in process
and needs no entitlement.

WWDC26 rebuilt the on-device model and kept the base API stable
(`SystemLanguageModel`, `LanguageModelSession`, `respond(to:)`). The macOS 27
additions (Private Cloud Compute, vision, Dynamic Profiles) stay out of scope
here. See "Out of scope" below.

## Design

### Mode encoding: a third case, same single source of truth

`MessageSummarizer.Mode` gains `case appleIntelligence`. The stage pin stays
the only mode signal. `ProviderID` gains a reserved constant:

```swift
extension ProviderID {
    /// Reserved built-in: the in-process Apple Intelligence backend.
    public static let appleIntelligence = ProviderID(rawValue: "apple-intelligence")
}
```

The pin value does not name a configured provider. `provider(forStage:)` keeps
its old behavior for it: the generic resolver never sees it because the AI mode
builds no ACP snapshot. `MessageSummarizer.mode(for:)` returns
`.appleIntelligence` when the pin equals the reserved constant. This follows
the repo rule that the special case gets its own enum case, so every consumer
switches exhaustively and the compiler asks the question.

`AgentProviderSummaryPreparation` gains `case appleIntelligence` with no
payload. The case carries no token because there is no lease, scratch world, or
backend to retire.

### Routing and seams

`AgentProviderRuntime.prepareSummarization()` switches on the mode:

- `.defaultTruncation` — unchanged.
- `.appleIntelligence` — check availability, then return `.appleIntelligence`.
  When Apple Intelligence is not available, log the reason and return
  `.defaultTruncation`. This degrades to the Default mode, the same result the
  user gets with no pin.
- `.model` — unchanged sandbox path.

Two new seams enter the runtime init, with production defaults:

```swift
isAppleIntelligenceAvailable: @Sendable () -> Bool
appleIntelligenceEngine: AppleIntelligenceSummarizer.Engine
```

Tests inject fakes, the same pattern as `readConfiguration` and `makeBackend`.
Production code needs no change because both parameters default.

`AgentProviderServices` gains two methods. Protocol extensions return `nil` by
default, so existing fakes compile unchanged:

```swift
func appleIntelligenceSummary(text: String) async -> String?
func appleIntelligenceTitle(question: String, answer: String?) async -> String?
```

### The engine

`AppleIntelligenceSummarizer` is a new `WikiFSEngine` type. It holds one shape,
an injectable engine:

```swift
public struct Engine: Sendable {
    public let reply: @Sendable (_ systemPrompt: String, _ prompt: String) async throws -> String
}
```

The production engine creates one `LanguageModelSession` per call with the
system prompt as instructions, sends one `respond(to:)`, and returns
`response.content`. A named timeout (`Duration` constant, 60 seconds) races the
call with `Task.sleep` in a throwing task group. A timeout cancels the call,
logs, and returns nil.

Title and summary reuse the existing prompt text and cleanup:

- `MessageSummarizer` extracts its inline prompt assembly into pure helpers.
  `titlePrompt(question:answer:)` and `summaryPrompt(text:)` return nil for
  empty input. The ACP path calls the same helpers, so its prompt bytes do not
  change.
- Titles run through `sanitizeTitle` and the same provisional-title write-back
  as the ACP path.
- The `chat-title-task` system prompt (`PublicPrompts.chatTitleTask`) and the
  summary system prompt (`MessageSummarizer.modelSystemPrompt`) are reused
  unchanged.

### Degradation contract

The strict-tier contract extends to the AI path:

- A nil summary (empty reply, throw, timeout) degrades to the truncation
  summary. The row is never left silently unsummarized.
- A nil title falls back to the provisional title.
- Unavailable Apple Intelligence degrades to the Default mode at preparation
  time, with one log line that states the reason.
- Already-summarized rows are not retried. Rows degraded to truncation keep
  that summary, the same as the ACP path today.

AI summaries write `ChatMessageSummaryKind.model`. The kind records "made by a
model", not "made by ACP", and the persisted enum stays stable.

### Settings UI

`StageProviderModelPicker` shows an "Apple Intelligence" row for the
summarizer stage, tagged with the reserved id. The model picker hides in AI
mode, as it already does for the no-provider summary mode. The row appears only
for the summarizer stage. When the pin is set in the sidecar JSON, the picker
selects the row instead of reporting a missing provider.

### Hosts

`DaemonChatHost` and `AgentOperationRunner` each add one `.appleIntelligence`
branch:

- Summaries: mirror `runModelSummarization` without the preparation and
  release, and call `services.appleIntelligenceSummary(text:)`.
- Titles: `refreshChatTitle` resolves the title from
  `services.appleIntelligenceTitle(question:answer:)` and shares the write-back
  and fallback branches with the `.model` case.

## Test plan

- `MessageSummaryTests` extends the mode table: the reserved pin yields
  `.appleIntelligence`; an unknown pin still yields `.model`.
- New `AppleIntelligenceSummarizerTests` with an injected engine: prompt
  bytes match the ACP path, title cleanup runs, nil on empty input, nil on
  timeout.
- `AgentProviderRuntimeTests`: availability true returns
  `.appleIntelligence`; false returns `.defaultTruncation`; the service
  methods route through the injected engine.
- `SummarizerDegradationContractTests` extends to pin the nil branch of the AI
  runner in both hosts.

## Out of scope

- Private Cloud Compute (needs an entitlement and Small Business Program
  enrollment; this app is local-only with dev signing).
- Vision attachments, Dynamic Profiles, the `fm` CLI, the Python SDK, and the
  Evaluations framework.
- Renaming or re-titling chats that the user renamed by hand. The untouched
  provisional-title guard keeps this behavior.
