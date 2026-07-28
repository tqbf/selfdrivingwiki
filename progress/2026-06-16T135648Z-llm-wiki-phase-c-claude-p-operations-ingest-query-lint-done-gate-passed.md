---
timestamp: 2026-06-16T135648Z
title: "2026-06-16 — LLM Wiki Phase C: `claude -p` operations (Ingest / Query / Lint) — DONE ✅ (gate passed)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-16 — LLM Wiki Phase C: `claude -p` operations (Ingest / Query / Lint) — DONE ✅ (gate passed)

## Progress


Branch `llmwiki/phase-c-claude-ops` (stacked on `llmwiki/phase-b-index-log`).
Implements `plans/llm-wiki.md` Phase C: generalizes the v0 agent launcher into
three discrete `claude -p` operations scoped to the active wiki, the per-wiki
edit lock, and the live-sidebar refresh during a run. The deterministic seams
(prompt/command/env construction, PATH preflight, edit-lock state machine) are
unit-tested; the real agent run was verified live. This phase took **three
gate-driven course-corrections** (the two entries above + this one are the
sub-stories): (1) the streaming UI + backend logs were missing → built them
(without live visibility the agent "just sits there"); (2) the least-privilege
`--allowedTools` allowlist rejected EVERY command (it can't match a command
containing the `$WIKI_ROOT`/`$WIKI_DB` expansion, and `-p` has no approval
prompt) → switched to `--dangerously-skip-permissions` + inject the wiki layout
up front (`TREE.md` + in-prompt map) so the agent acts instead of probing; (3)
ingested `[[wiki-links]]` rendered as dead text in the preview → made them
clickable/navigable.

**Verified (live gate — user drove the app UI, orchestrator verified via Bash; real `make clean && make install`, real-signed, on a freshly-created wiki `GateCFresh`)**
- **Ingest (structural pass):** a real `claude -p` Ingest of `photosynthesis.txt`
  took the wiki from **1 page → 6** (Photosynthesis + Chloroplast, Chlorophyll,
  Light-Dependent Reactions, Calvin Cycle), appended an **`ingest` log row**,
  rewrote **`index.md` (v2→v3)**, and built a **9-edge `[[link]]` graph**
  (`page_links` + `indexes/links.jsonl`) — all written via `wikictl`, the
  read-only mount untouched. The gate is structural (the agent is
  non-deterministic), and all three required artifacts (≥1 page, ≥1 log entry,
  index changed) landed.
- **Query:** returns a cited answer in the panel + a `query` log row.
- **Live streaming + backend logs:** the activity panel showed real tool-call
  rows (`printf … | wikictl page upsert`, etc.), assistant text, and the green
  terminal result **as they streamed**; **4 `run.jsonl`** backend logs captured
  the full NDJSON event stream (system init → assistant → tool_use → tool_result
  → result) under `~/Library/Caches/WikiFS-agent/<uuid>/`, with `run.stderr.log`
  sibling and a "Reveal Log" button.
- **Edit lock:** the in-app editor was read-only with the "Agent is updating the
  wiki…" banner for the run's duration and re-enabled on completion (per-wiki).
- **Clickable wiki-links:** in the preview, `[[Photosynthesis]]` etc. render as
  accent links and navigate to the target page on click; unresolved links render
  dimmed + inert. (On-disk/mount bytes stay literal `[[…]]`.)
- **Tests 161 → 207** across the phase (operations seams, `AgentEvent` parser,
  `WikiTreeRenderer`, `WikiLinkMarkdown` linkifier + navigation), all green and
  deterministic — also fixed three pre-existing same-millisecond ULID-ordering
  flakes (log order; duplicate-title resolve; link order) surfaced along the way.

**Carry-forward to Phase D:** the operation `-p` prompts currently INLINE the
schema (layout + `wikictl` cheatsheet + read-after-write rule) as a stopgap,
because today's `system_prompt`/`CLAUDE.md` is still the Phase-D stub. Phase D
puts the real schema in `CLAUDE.md`; the `-p` prompts should then slim down to
just the per-op task (the inline preamble becomes the duplication to remove).

**Flag surface confirmed (claude-api skill + installed CLI `2.1.178`)**
- `claude --help` confirms `-p`/`--print`, `--append-system-prompt <prompt>`,
  `--allowedTools` ("Comma or space-separated list of tool names"), and
  `--output-format text|json|stream-json`.
- **Streaming is now load-bearing, not polish.** A plain `claude -p` emits almost
  nothing until the final result, so the operations panel sat blank for the whole
  run — "you just sit there waiting for claude to do nothing", undebuggable. We now
  always pass `--output-format stream-json --verbose --include-partial-messages`.
  `--help` (and a real captured run) confirm `--verbose` is REQUIRED with
  `stream-json` in print mode, and `--include-partial-messages` is accepted (it
  adds token-level `stream_event` deltas).
- **Real event shapes captured from the installed binary** (a live
  `claude -p 'say hi' --output-format stream-json --verbose --include-partial-messages`
  run, NDJSON, one per line): a `{"type":"system","subtype":"init",…,"model":…}`
  event; `{"type":"assistant","message":{"content":[{type:"text"|"tool_use",…}]}}`;
  `{"type":"user","message":{"content":[{type:"tool_result","is_error":…,"content":…}]}}`;
  and the terminal `{"type":"result","is_error":…,"result":…}`. The bookkeeping
  types we DON'T render — `system/status`, `rate_limit_event`, the
  `--include-partial-messages` `stream_event` deltas, `system/post_turn_summary` —
  were all observed and are intentionally skipped (the complete `assistant`/`user`
  events carry the same content cleanly).
- Validated the EXACT combination parses on the real binary (no unknown-flag
  error). The space-separated `Bash(<cmd>:*)` allowlist form is what the installed
  CLI accepts.

**Added (deterministic, unit-tested — `WikiFSCore`)**
- **`WikiOperation`** — a PURE enum (`ingest(sourcePath:)` / `query(question:)` /
  `lint`) that renders each operation's OWN self-sufficient `-p` prompt. Because
  the per-wiki `system_prompt` is still the Phase-D stub, each prompt spells out
  the `wikictl` workflow (write via `page upsert`, record via `log append`,
  rewrite via `index set`, **read-back via `page get`** since the mount lags ~5s)
  and reminds the agent the mount is read-only + `WIKI_DB` already selects the
  wiki (so it must NOT pass `--wiki`). Ingest names all four write steps (≥1
  summary page, entity/concept pages, rewrite `index.md`, append `log.md`); Query
  asks for a cited answer; Lint asks for the health report + a `log append`.
- **`OperationCommand`** — the PURE `claude -p` argv/env/cwd builder, the
  load-bearing testable seam. `build(...)` assembles:
  `claude -p <prompt> --output-format stream-json --verbose
  --include-partial-messages --append-system-prompt <wiki's system_prompt>
  --allowedTools '<allowlist>'` with **env** `WIKI_ROOT=<live mount>` +
  `WIKI_DB=<wiki ULID>` +
  `PATH=<Helpers dir>:<inherited PATH>` (so the agent's `wikictl` calls resolve),
  **cwd** = a per-run writable scratch dir (NOT the read-only mount, decision #4).
  `allowedTools` = `Bash(wikictl:*) Bash(find:*) Bash(cat:*) Bash(grep:*)
  Bash(printf:*) Read Grep Glob` (least privilege: wikictl writes + read-only
  shell + read tools; `printf` for the stdin-piped `--body-file -` writes).
- **`AgentEvent` + `AgentEventParser` + `ToolInputSummary`** (NEW, PURE,
  unit-tested) — the typed projection of the stream-json NDJSON. `parse(line:)`
  decodes ONE line → `.systemInit(model:)` / `.assistantText(String)` /
  `.toolUse(name:inputSummary:)` / `.toolResult(isError:summary:)` /
  `.result(isError:text:)`, and is deliberately TOLERANT: an empty line → `nil`;
  any line that fails to decode (garbage, a mid-object partial flush) →
  `.raw(line)` rather than throwing; unmodeled event types (`stream_event`
  deltas, `system/status`, `rate_limit_event`, `post_turn_summary`) and
  renderable-content-free `assistant` blocks (e.g. `thinking`-only) → `nil`. So a
  bad/unfamiliar line never crashes or drops the run. `ToolInputSummary` renders a
  concise one-liner per `tool_use` (Bash → its command, Read/Write/Edit → the
  path, Glob/Grep → the pattern, else a sorted `key=value` join), elided at 120
  chars — so the feed reads `Bash  wikictl page upsert --title "…"` not a JSON
  blob. Built against the REAL captured shapes, not a guess.
- **`PathPreflight`** — pure `resolve(executable:onPath:fileExists:)` first-hit
  PATH search + `resolveOnLoginShell()` (a real `zsh -lc 'echo $PATH'` hop, since
  the GUI app's process PATH lacks `/opt/homebrew/bin`). Surfaces a clear in-UI
  error if `claude` isn't resolvable instead of a cryptic spawn failure.
- **`EditLock`** — `@MainActor @Observable` per-wiki lock state machine (decision
  #6): `lock(wikiID:)` / `unlock(wikiID:)`, keyed by ULID, **re-entrant via a
  count** (two ops on one wiki don't unlock each other early), stray-unlock
  clamped at zero. (The app drives the lock through `WikiStoreModel` directly —
  `EditLock` is the tested standalone state machine for the per-wiki contract.)

**Added / changed (app — `WikiFS`)**
- **`AgentLauncher` generalized + made observable** from a free-form `zsh -lc
  <cmd>` to
  `run(operation:wikiID:wikiRoot:systemPrompt:wikictlDirectory:onLock:onUnlock:)`:
  runs the PATH preflight, builds the per-run scratch dir under Caches, assembles
  the command via `OperationCommand.build`, spawns `claude`. **The stdout
  `readabilityHandler` now does double duty**: it tees every raw byte to the
  per-run `run.jsonl` log AND feeds bytes through a line buffer (carrying over a
  partial trailing line until its newline arrives, so the parser only ever sees
  complete NDJSON) → `AgentEventParser` → a published
  `private(set) var events: [AgentEvent]` the UI renders live, all on the main
  actor. It also keeps a `rawTranscript` mirror and separate `stderr`. The
  no-`waitUntilExit` model is preserved — completion arrives via
  `terminationHandler`, which drains any trailing partial line, closes the log
  handles, releases the edit lock (`onUnlock`), and records the exit status, so a
  killed/crashed agent still re-enables editing. Exposes `preflightError`,
  `runningKind`, `exitStatus`, and `logFileURL` for the UI. `resolveClaude` is
  injectable for tests.
- **Backend logs (the user-required "fully reconstructable after the fact").**
  Each run's scratch dir holds `run.jsonl` (every raw stream-json byte, unparsed)
  and a sibling `run.stderr.log` (claude's diagnostics). The scratch dir is now
  PERSISTED (not deleted on termination) so a finished run can be replayed;
  `logFileURL` surfaces `run.jsonl` so the UI can reveal it in Finder.
- **`HelpersLocation`** — resolves the `wikictl` dir to prepend to the agent's
  PATH: the signed bundle's `Contents/Helpers` first, then `build/` and the
  running-exe dir for dev (`swift run`). Confirmed live: the embedded+signed
  `wikictl` resolves on PATH and honors `WIKI_DB`.
- **Edit lock wired into the model.** `WikiStoreModel.beginAgentRun()` flushes
  pending edits then sets `isAgentRunning` (editor → read-only, autosave PAUSED —
  both `scheduleAutosave` and `systemPromptChanged` early-return while running, so
  an in-app save can't clobber the agent's `wikictl` writes). `endAgentRun()`
  clears the flag, `reloadFromStore()`s the sidebar, and reloads the open
  document's draft from the (agent-rewritten) source. The live change-bridge
  `reloadFromStore` is UNAFFECTED by the lock, so the sidebar still fills in as the
  agent's writes land mid-run. `currentSystemPromptBody()` exposes the singleton
  for `--append-system-prompt`.
- **UI (macos-design + typography-designer + swiftui-pro).** `OperationsView`
  replaces the old "Run Agent" sheet: a segmented Ingest/Query/Lint picker, an
  Ingest source picker (over the wiki's ingested files → its `files/by-id/…`
  mount path via the shared `FilenameEscaping`), a Query text box, a Lint button,
  the live activity panel, and the PATH-preflight error.
- **`AgentActivityView` (NEW) — the live transcript.** Replaces the old "raw blob"
  console: an auto-scrolling `LazyVStack` over `launcher.events`, one row per typed
  event — a `tool_use` row is an SF Symbol (terminal/doc/pencil/magnifyingglass per
  tool) + monospaced name + concise input summary; assistant text is body prose;
  the terminal result is distinct (green `checkmark.seal` / red
  `exclamationmark.octagon` by `is_error`); a spinner + "Starting <kind>…"
  placeholder shows while a run has started but emitted nothing yet, so the panel
  is NEVER staring at nothing. Auto-scroll animates a scroll OFFSET to a
  zero-height bottom anchor (`onChange(of: events.count)`) — never inserts/removes a
  structural view (SWIFTUI-RULES §1.1); rows derive purely from their `AgentEvent`
  (§3.1); semantic Dynamic-Type fonts (§5.1); no cached formatters in `body`. A
  stderr "Diagnostics" sub-panel surfaces claude's stderr when non-empty, and the
  footer's **"Reveal Log"** button opens `run.jsonl` in Finder. The raw transcript
  stays available via `launcher.rawTranscript` for debugging.
- `AgentRunBanner` ("Agent is updating the wiki…") sits above both
  editors — **always-mounted, height-animated** per SWIFTUI-RULES §1.1 (no
  structural transition), Reduce-Motion-aware; both detail views `.disabled` while
  `store.isAgentRunning`. Semantic Dynamic-Type fonts throughout. Toolbar button
  renamed "Maintain Wiki" (`sparkles`). Obsolete `AgentLauncherView` removed.
- Tests: 135 → **180** (+45). `OperationCommandTests` (updated: argv now asserts
  `-p`, the `--output-format stream-json --verbose --include-partial-messages`
  streaming flags, `--append-system-prompt`, `--allowedTools` in exact order, plus
  a dedicated `streamJSONRequiresVerbose` check; allowlist scope,
  `WIKI_ROOT`/`WIKI_DB` env, Helpers-dir PATH prepend, scratch-cwd-not-mount,
  base-env inheritance, every-kind builds; the three prompts name their `wikictl`
  steps + read-after-write rule + `do NOT pass --wiki`; PATH preflight
  found/missing/order/absolute/empty). **`AgentEventParserTests` (NEW, ~19)** —
  each event type from REAL captured sample lines (system/init w/ + w/o model,
  assistant text, Bash/Read `tool_use` summaries, string + array `tool_result`,
  success + error `result`); tolerance (garbage → `.raw`, truncated mid-object →
  `.raw`, empty/whitespace → `nil`, unmodeled types → `nil`, renderable-free
  assistant → `nil`); `ToolInputSummary` (unknown-tool sorted `key=value`,
  long-command elision, empty input). `EditLockTests` (8, unchanged).
  `make test` → **180 green, all deterministic** (the prior log-ordering flake was
  fixed in `38aeb6f` — `ts+rowid` ordering); `make` clean signed bundle (app +
  appex + `wikictl`, real identity).
- **End-to-end live smoke (this session).** Drove the FULL pipeline against the
  installed `claude 2.1.178`: built the real `OperationCommand` argv, spawned
  `claude -p`, teed raw stdout to `run.jsonl`, line-buffered through the real
  `AgentEventParser`. Result: parsed `systemInit(model: "claude-opus-4-8[1m]")` →
  `assistantText("PONG")` → `result(isError:false, text:"PONG")`, and `run.jsonl`
  populated (7,917 bytes). The activity stream AND the backend log both populate
  on a real run. (Smoke harness was temporary; removed after the run.)

**The EXACT command each op builds** (env + cwd shown):
```
cd <Caches>/WikiFS-agent/<uuid>  \   # writable scratch (also holds run.jsonl +
                                     #   run.stderr.log); NOT the read-only mount
  env WIKI_ROOT=<live mount> WIKI_DB=<wiki ULID> \
      PATH=<WikiFS.app/Contents/Helpers>:<inherited PATH> \
  <resolved claude> -p "<operation prompt>" \
    --output-format stream-json --verbose --include-partial-messages \
    --append-system-prompt "<this wiki's system_prompt body>" \
    --allowedTools 'Bash(wikictl:*) Bash(find:*) Bash(cat:*) Bash(grep:*) Bash(printf:*) Read Grep Glob'
```

**Notes / carry-forward**
- **The prior log-ordering flake is FIXED** (`38aeb6f` — `log.md` now orders by
  `ts+rowid`, not the ULID `id`). The whole suite (180) is deterministic.
- **Gate is STRUCTURAL** (agent is non-deterministic): on a FRESHLY-CREATED wiki,
  drop a real source → Ingest → ≥1 new summary page + ≥1 `log.md` entry +
  `index.md` changed (all visible on the mount); a Query returns a cited answer; a
  Lint produces a report; the editor is read-only during a run and re-enabled
  after. `claude` must be on the login-shell PATH. macOS-26 TCC prompt re-fires on
  a re-signed install (Phase 0 carry-forward).
- **The verifier must ALSO confirm the streaming observability** (the whole point
  of this enhancement): during a run the operations panel shows live tool-call
  rows + assistant text streaming in (NOT a blank box until the end), and a
  backend `run.jsonl` log is written under the run's scratch dir
  (`<Caches>/WikiFS-agent/<uuid>/run.jsonl`, revealable via "Reveal Log"),
  containing the raw stream-json for after-the-fact replay.

## Verification

Historical verification remains in the progress record above.
