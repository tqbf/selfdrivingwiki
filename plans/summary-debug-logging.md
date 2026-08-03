# Chat Summary Pipeline Debug Logging

## Problem
User sees raw sentences instead of LLM summaries in chat outline.

## Pipeline Flow
AgentLauncher.sendInteractiveMessage (turn end, :3059) -> flushTranscript (:3065) -> fireMessageSummarySink (:3239) -> AgentOperationRunner.summarizePendingMessages (:505) -> MessageSummarizer -> WikiStoreModel.updateMessageSummary (:4049) -> GRDBWikiStore UPDATE (:6099)

View reads it in ChatDetailView.chatOutlineEntries (:605) where cached ?? ChatSummary.summaryExtract(...) — cache wins, truncation is fallback.

## Two Modes
- **Default (empty pin)**: pure first-sentence truncation, NO LLM. 'Raw sentences' is expected output.
- **Model (non-empty pin)**: real one-shot ACP LLM session with inline prompt.

Gated on config.stageProviderIds['summarizer']

## Debug Log Locations

### 1. AgentOperationRunner.summarizePendingMessages (~line 505-531)
- TOP of method: mode, pin, pending count
- Store torn down skip
- No pending messages skip

### 2. AgentOperationRunner.runModelSummarization (~line 558-580)
- Profile resolve fail (already logged)
- MessageSummarizer returns nil
- Summary success

### 3. MessageSummarizer.modelSummary (~line 97-151)
- Start model mode
- ACP start fail (already logged)
- Turn fail (already logged)
- **Model output empty** (currently unlogged)
- Success

### 4. AgentLauncher.fireMessageSummarySink (~line 3239-3242)
- Called with chatID
- Skipped when no activeChatID

### 5. ChatDetailView.chatOutlineEntries (~line 605-655)
- Cache hit vs fallback

## Changes
- All logs use DebugLog.ingest or DebugLog.chat
- No logic changes
- Build verification: `make prompts && swift build`
- Test verification: `swift test`