---
timestamp: 2026-09-17T213000Z
title: Apple Intelligence summarizer — on-device titles and summaries
branch: feature/apple-intelligence-summarizer
status: implemented; build + full suite green
---

# Apple Intelligence summarizer

## Progress

Implemented `plans/apple-intelligence-summarizer.md`: chat titles and
per-message summaries can now run on the on-device Apple Intelligence model
(Foundation Models, `SystemLanguageModel`) instead of a one-shot ACP
subprocess. No provider, credential, sandbox scratch, lease, or entitlement
is involved. The deployment floor stays macOS 26.0.

1. **Mode encoding.** `MessageSummarizer.Mode` gained
   `case appleIntelligence`, selected when the `"summarizer"` stage pin
   equals the new reserved `ProviderID.appleIntelligence`
   (`"apple-intelligence"`). The stage pin stays the single mode signal
   (§5.1 invariant). A look-alike id stays Model mode.
2. **Engine.** New `AppleIntelligenceSummarizer` (WikiFSEngine) wraps one
   `LanguageModelSession` per call behind an injectable `Engine` closure.
   The title and summary prompts are shared with the ACP path through new
   pure helpers (`MessageSummarizer.titlePrompt` / `summaryPrompt`), so both
   paths send byte-identical turns. Titles run through `sanitizeTitle`. A
   named 60-second timeout races every turn in a throwing task group; a
   timeout cancels the call and returns nil.
3. **Routing.** `AgentProviderSummaryPreparation` gained `.appleIntelligence`
   (no token — nothing to release). `AgentProviderRuntime` gained two init
   seams (`appleIntelligenceEngine`, `isAppleIntelligenceAvailable`) with
   production defaults, an availability gate in `prepareSummarization()`, and
   the `appleIntelligenceSummary`/`appleIntelligenceTitle` service pair
   (protocol defaults return nil so existing fakes compile unchanged).
4. **Degradation.** Unavailable Apple Intelligence returns the Default
   truncation preparation with one log line. A nil summary (empty reply,
   error, timeout) degrades to the truncation summary; a nil title falls back
   to the provisional title. `SummarizerDegradationContractTests` now pins the
   AI runner's nil branch in both hosts.
5. **Hosts.** `DaemonChatHost` and `AgentOperationRunner` each gained an
   `.appleIntelligence` branch plus `runAppleIntelligenceSummarization`.
   `refreshChatTitle` shares its write-back and fallbacks between the Model
   and AI modes. AI summaries persist as `ChatMessageSummaryKind.model`.
6. **Settings.** `StageProviderModelPicker` shows an "Apple Intelligence
   (on-device)" row for the summarizer stage, hides the model picker in AI
   mode, and resolves the reserved pin to a new
   `StageProviderSelectionState.pinnedAppleIntelligence` state (not
   `pinnedMissing`, so no false "provider no longer exists" warning).

## Evidence

- `make build` passes with `-warnings-as-errors` (Swift 6.4, macOS 27 SDK,
  macOS 26 deployment floor).
- `swift test --filter` over `AppleIntelligenceSummarizerTests`,
  `MessageSummaryTests`, `AgentProviderRuntimeTests`,
  `SummarizerDegradationContractTests`, `StageProviderModelPickerTests`:
  all pass. One earlier `make test` run flagged `WikiFSCoreTests` with zero
  assertion lines; the target passed fully in isolation and the full
  `make test` re-run passed ("✓ tests pass"), so it was a runner flake.
- New tests: prompt parity with the ACP path, title sanitization, nil
  contracts (empty input, empty reply, thrown error, timeout), availability
  gating both ways at the runtime, engine routing, no-backend-resource
  assertion when degraded, picker resolution for the reserved pin.

## Notes for the operator

- Select it in Settings: Summarizer stage → "Apple Intelligence (on-device)",
  or pin `"summarizer": "apple-intelligence"` in the agent-providers sidecar.
- Rows degraded to truncation summaries keep them, the same as the ACP path
  today; new turns use Apple Intelligence once it is available.
- Out of scope by plan: Private Cloud Compute, vision attachments, Dynamic
  Profiles, the `fm` CLI, and the Python SDK.
