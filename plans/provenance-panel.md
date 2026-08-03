# Provenance Panel — Run Names & Clickable Entries (#745)

## Problem
The Provenance panel showed the raw chat ULID (`chat:<ULID>`) for chat-driven
page edits and raw `agent:<kind>` for one-shot runs. The issue asks:

1. Show a human-readable run name (the chat title) instead of the raw ULID.
2. Make entries clickable — navigate to the source or the Activity window.

## Data Model
`PageOrigin` carries `agentName`, `agentKind`, `activityKind`, `plan`,
`externalRef`, `runTitle`, `savedAt`.

- **Chat-driven edits** (interactive chat via `startInteractiveQuery`):
  `agentName = "chat:<chatULID>"` → stamp via `WIKI_AUTHOR` env var.
- **One-shot runs** (ingest/lint/query via `launcher.run`):
  `agentName = "agent:<kind>"` (e.g. `agent:ingest`, `agent:lint`).

## Changes

### 1. `PageOrigin.runTitle` (new field)
Added `runTitle: String?` to `PageOrigin` — the chat's display title for
`chat:<id>` agents, resolved via a SQL subquery that JOINs the `chats` table
on the stripped chat ULID (`substr(a.name, 6)`). `nil` for non-chat agents or
deleted chats.

### 2. GRDBWikiStore SQL queries
`pageOrigin(pageID:)` and `pageEditHistory(pageID:)` now include a correlated
subquery:
```sql
(SELECT c.title FROM chats c
 WHERE c.id = substr(a.name, 6) AND a.name LIKE 'chat:%')
```
`pageOriginFrom(row:)` decodes position 8 as `runTitle`.

### 3. ProvenancePanel UI rewrite
- `agentLabel(_:)` now takes a `PageOrigin` (not raw name/kind strings):
  - `chat:<id>` with `runTitle` → show the chat title (not the ULID).
  - `chat:<id>` without `runTitle` → muted "Deleted chat" placeholder.
  - `agent:<kind>` → friendly label ("Ingestion" / "Lint" / "Query").
- `historyRow` is now clickable: `.contentShape(Rectangle())` +
  `.hoverRowBackground()` + `.onTapGesture { handleProvenanceTap(entry) }`.

### 4. Navigation
- `chat:<id>` → `store.openTab(.chat(PageID(id)))` — opens the chat tab.
- `agent:<kind>` → `openActivityWindow?()` via `@Environment`.
- Other → no-op.

### 5. Activity window environment bridge
- Added `openActivityWindow: (() -> Void)?` to `OpenWindowBridge`.
- Wired in `MenuBarItemController.init` → `showQueueWindow(for: .ingestion)`.
- Injected into SwiftUI environment via `ActivityWindowEnvironmentKey`.
- `appEnvironment(tracker:openActivityWindow:)` passes the closure at scene root.

## Files Modified
- `Sources/WikiFSCore/Core/PageOrigin.swift` — added `runTitle` field.
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift` — SQL subquery + decoder.
- `Sources/WikiFS/Pages/PageDetailView.swift` — ProvenancePanel rewrite.
- `Sources/WikiFS/Window/OpenWindowBridge.swift` — `openActivityWindow` closure.
- `Sources/WikiFS/Window/MenuBarItemController.swift` — wire the closure.
- `Sources/WikiFS/Window/WikiFSApp.swift` — inject into environment.
- `Sources/WikiFS/Environment/ActivityWindowEnvironmentKey.swift` — new file.

## Validation
- `make build && make test`
- `make run`: open a page with provenance; expand Provenance; entries show run
  names (not ULIDs); clicking navigates to the chat or Activity window.
