# Plan: Sandbox toggle + independent Ask/Edit chat sessions

Re-expose the sandbox as a Settings toggle that governs the toggle-gated agents,
make `~/.claude` writable whether sandboxed or not, and replace the single Query
chat with **two independent, persistent sessions** — **Ask** (read-only) and
**Edit** (can write the wiki) — each with its own button and its own tab, both
able to be open at once. Switching between them never restarts a session.

## Decisions (confirmed with user)

- **Ask is always sandboxed** read-only — its "cannot edit the wiki" guarantee is
  physical, not prompt-only. The global toggle governs the **main agent** and
  **Edit** only. (Already how `selectQuerySandbox` behaves — preserve it.)
- **`.claude` writes** allowed for both `~/.claude/` (subtree) and `~/.claude.json`
  (file), in both the full and read-only profiles.
- **Two sessions, serialized.** Ask and Edit are separate persistent sessions in
  separate tabs; only one *generates* at a time (the existing serial spawn slot
  stays). No concurrent streaming — that was explicitly deferred.
- **Delete the dead credential-seeding code** (no longer optional).

## Context (verified, incl. subagent map)

- The app already runs **two** `AgentLauncher` instances (`agentLauncher`,
  `queryLauncher`) as flat `@State` in `WikiFSApp` — multi-instance is an
  established pattern. All launcher state is flat/single-session (no session id).
- **Spawn slot = hard serial cap of 1** across ingest/lint/query
  (`AgentLauncher.swift:247–306`); the subagent reports ingest+query already
  contend, i.e. it is shared, not per-instance. This is what makes "two sessions,
  serialized" cheap.
- `QueryConversationView` is mounted once via `WikiDetailView`'s
  `switch store.selection` `.query` branch — not a tab today. The tab system
  (`EditorTab`, `tabs[]`, `activeTabID`) dedupes on `WikiSelection`, so two tabs
  require two distinct `WikiSelection` cases.
- Edit lock is a single `store.isAgentRunning` Bool; the read-only Ask session
  never touches it (`onTurnBoundary`/`onLock` are no-ops when `!allowWikiEdits`),
  so one-Ask + one-Edit is lock-safe under serialization.
- `SandboxConfig{enabled=false}` persists to `sandbox-config.json`; `fb8b20d`
  removed only its UI. `seedSandboxCredentials`/`relocatedCredentialPlan` are dead.

---

## Step 1 — Allow `.claude` writes in the seatbelt (req 3)

Add to **both** `generate` and `generateReadOnly`, using the `HOME` param both
invocations already define:
```
(allow file-write* (subpath (string-append (param "HOME") "/.claude")))
(allow file-write* (literal (string-append (param "HOME") "/.claude.json")))
```
- **Files:** `Sources/WikiFSCore/SandboxProfile.swift`. Canonicalize `HOME` if needed.
- **AC:** Both profiles contain the two rules; a sandboxed run writes
  `~/.claude/projects/**` and `~/.claude.json` without EPERM; writes elsewhere
  still denied. Profile-text tests updated.

## Step 2 — Re-add the sandbox toggle to Settings (req 1, req 2)

Add an `enabled` toggle to the Agent settings tab, load/persist via
`SandboxConfig.load/save(from: containerDirectory)` (same `.onChange` immediate-save
pattern). No `extraAllowedPaths` editor (defer).
- **Files:** `Sources/WikiFS/AgentCommandSettingsView.swift`.
- **AC:** Toggling writes `enabled` to `sandbox-config.json`; ON → main agent +
  Edit spawn under `sandbox-exec`, OFF → unsandboxed. No spawn path bypasses the gate.

## Step 3 — Split the session backbone: `.ask`/`.edit` + a second launcher

Replace the single `.query` `WikiSelection` case with `.ask` and `.edit`. Add a
second query launcher so each session owns its transcript/process state: in
`WikiFSApp`, `queryLauncher` → `askLauncher` + `editLauncher`, threaded to
`WikiDetailView`, whose `switch` routes each case to `QueryConversationView` with
its launcher. Split the `.query` branch in `EditorTab` title/icon.
- **Files:** `WikiSelection.swift`, `EditorTab.swift`, `WikiFSApp.swift`,
  `WikiDetailView.swift`.
- **Watch-item:** confirm the spawn slot is shared across launcher instances (per
  the subagent, ingest+query already contend); if it is per-instance, promote it
  to a shared serial gate so Ask/Edit/ingest still serialize.
- **AC:** Opening Ask and Edit yields two distinct, coexisting tabs; switching
  between them restarts neither; only one generates at a time.

## Step 4 — Two buttons + per-session mode; remove checkbox & restart logic (req 4)

Add **Ask** and **Edit** buttons that open the respective selection/tab. In
`QueryConversationView`, take `mode` from the mounting selection instead of
`@State allowWikiEdits`; delete the checkbox `Toggle` and the
`restartQueryConversation`-on-change path. Wire `mode.allowsEdits` into
`startQueryConversation(allowWikiEdits:)`, the editing banner, and the
prompt/sandbox selection (already keyed on `allowWikiEdits`).
- **Files:** `QueryConversationView.swift`, the sidebar/launch buttons,
  `AgentOperationRunner.swift` (drop the now-unused restart path).
- **AC:** Ask tab cannot edit (read-only prompt + forced read-only seatbelt);
  Edit tab can (DB-writable when sandbox ON, unsandboxed when OFF); no checkbox;
  banner shows only in Edit; **no session restart anywhere**. Existing query tests pass.

## Step 5 — Delete dead credential-seeding machinery (cleanup)

Remove `seedSandboxCredentials`, `relocatedCredentialPlan`, the
`seededCredentialFile` field + its `finish()` cleanup, and any `.claude-config`
references — `.claude` is directly writable now and `CLAUDE_CONFIG_DIR` is unset.
- **Files:** `Sources/WikiFS/AgentLauncher.swift`, related tests.
- **AC:** Compiles without them; runs still authenticate via the real
  `~/.claude/.credentials.json`; no test references the removed symbols.

---

## Definition of done

- All four requirements met: settings toggle persisted (1); every toggle-gated
  agent honors it, Ask always read-only sandboxed (2); both profiles allow
  `~/.claude/` + `~/.claude.json` (3); Ask/Edit are independent persistent
  sessions in two tabs with two buttons, Ask physically unable to write (4).
- `swift build` clean; existing tests pass; profile + chat tests updated.
- Manual: Ask and Edit open as two tabs simultaneously; switching restarts
  neither; Edit edits a page (sandbox ON), Ask cannot; a sandboxed session writes
  its transcript under `~/.claude/projects` without EPERM.
- No regression to the unsandboxed default path.
