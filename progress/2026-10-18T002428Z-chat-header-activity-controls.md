---
timestamp: 2026-10-18T002428Z
title: Chat detail header absorbs the floating Activity menu
branch: feature/chat-header-diagnostics-controls
status: complete
---

# Chat detail header absorbs the floating Activity menu

## Progress

While a chat answered or queued, `ChatDetailControlsView` floated an
ellipsis-circle Activity menu at the top right of the chat detail. The
icon overlapped the transcript during every run. The menu is gone. Its
controls now live in the chat header's expanded button row, next to the
existing Reveal Debug Folder button:

- Show Full Activity stays a toggle. It swaps the transcript for the raw
  activity view. The raw activity view shows a Show Transcript button in
  its top right corner, which replaces the menu as the way back.
- Copy Diagnostics and Write Redacted Diagnostics JSONL keep their
  actions and help text.
- The Ended / Exited N status shows as a label in the row.
- The small answering spinner from the old cluster is gone. The
  transcript already shows a thinking indicator.

Gating is unchanged. `ChatDetailPresentation.showsDebugControls` still
decides when the run diagnostics appear (answering or queued). Write
JSONL still needs the run's own debug folder URL. Reveal Debug Folder
keeps its separate path through
`ChatDetailPresentation.debugFolderButtonHelpText` and
`ChatDetailView.currentDebugFolderURL`.

`ChatDetailControlsView.swift` is deleted. `ChatDetailView` no longer
overlays a ZStack over the content. `ChatHeaderSectionView` grew the
`runDiagnosticsControls` cluster and the matching inputs.

## Verification

- `make build` — the app compiles and signs.
- `make test` — the full `swift test --parallel` suite passes.
- `rg ChatDetailControlsView Sources Tests` — no references remain.
- No manual UI run happened. The operator should check the expanded
  header row during a live chat and the Show Transcript path in the raw
  activity view.
