## Summary

Adds Paseo-style copy icon and "Worked for Xs" metadata footer to assistant chat responses, matching how Paseo's `TurnCopyButton` and `AssistantTurnFooter` work.

## Changes

### Copy icon (replaces text "Copy" button)

- Replaced the plain text "Copy" button with a lucide `Copy` SVG icon (15x15, `currentColor` stroke) on assistant chat bubbles
- On click, the icon swaps to a green `Check` icon for 1.5s (mirrors Paseo's `TurnCopyButton`)
- CSS restyled from text pill to a flexible icon button - transparent background, subtle `--code-bg` on hover, clean `currentColor` tint
- Added `aria-label="Copy"` for accessibility

### "Worked for Xs" footer with hover-swap

- Added a "Worked for Xs" duration label under each assistant response that swaps to the completion timestamp on hover (e.g. "2:34 PM") - matches Paseo's `AssistantTurnFooter`
- Pure CSS hover-swap (no JS): a hidden sizer reserves width, `.turn-duration` shows at 60% opacity, `.turn-timestamp` fades to 70% on hover

### Timing infrastructure

- `AgentLauncher` now tracks `eventTimestamps: [Date]` parallel to `events` - every append/replace in `mergeOrAppend`, `startInteractiveQuery`, and `sendInteractiveMessage` updates timestamps in lockstep; both reset sites clear it
- `AgentEvent` gained `isVisibleInTranscript(in:)` and `isInternalTranscriptEvent` (moved from `WikiFS` to `WikiFSCore`); old private `hasAssistantText` dedup helper consolidated
- `[AgentEvent]` extension refactored: `transcriptVisible` uses new `transcriptVisibleIndices` so parallel arrays (timestamps) can be filtered in lockstep
- `ChatView` computes `displayTimestamps` (live: `launcher.eventTimestamps`, persisted: `ChatMessage.createdAt`) and passes through `ChatTranscriptView` -> `ChatWebView`
- `ChatWebView` threads timestamps through the full rendering pipeline and computes duration via `workDuration(at:timestamps:)` - scans backwards for the previous non-nil timestamp

## Files changed

| File | Change |
|------|--------|
| `Sources/WikiFS/ChatWebView.swift` | Copy icon SVGs, CSS, JS handler; timestamp threading; footer HTML + CSS; formatDuration/formatTimestamp/workDuration |
| `Sources/WikiFSEngine/AgentLauncher.swift` | `eventTimestamps` array + parallel tracking in all event append/replace paths |
| `Sources/WikiFSCore/AgentEvent.swift` | `isInternalTranscriptEvent`, `isVisibleInTranscript(in:)`, `hasAssistantText` helper |
| `Sources/WikiFS/ChatTranscriptView.swift` | `transcriptVisibleIndices`, `timestamps` param, `hideToolCalls` mirror filter |
| `Sources/WikiFS/ChatView.swift` | `displayTimestamps` computed property, forwarded to transcript view |
| `Sources/WikiFS/AgentQueueView.swift` | Removed old `isInternalTranscriptEvent` extension (moved to `WikiFSCore`) |

## Testing

- `swift build` - clean, no new warnings
- `swift test` (fast tier) - all 2385 tests pass
- Activity-feed callers (`AgentQueueView`, `ActivityWindowView`) are unaffected - they pass no timestamps (defaults to `[]`), so no footers render
