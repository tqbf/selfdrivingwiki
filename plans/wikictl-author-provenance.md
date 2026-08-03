# wikictl author provenance (issue #397)

**Status:** implemented.

## Problem

Pages have provenance fields (`created_by`, `last_edited_by`, #131) surfaced in
frontmatter. The in-app editor sets them (`author: "user"`), but `wikictl page
upsert` — the command agents actually run — never passed `author:`, so it
defaulted to `nil` (`PageUpsert.upsert`'s `author` parameter). Every agent-created
or agent-edited page had no provenance, indistinguishable from a pre-#131 row.

## Fix

Wire an `author` string through the `wikictl` write path and inject it "for free"
from the spawning session so agents don't have to remember to pass it.

### Layers

1. **CLI flag + env var (`WikiCtlCore`).**
   - `ArgumentParser.Command.upsert` gains `author: String? = nil`.
   - `parsePageCommand` reads `--author <string>`.
   - `WIKI_AUTHOR` env var auto-applies in `main.swift`'s env step (renamed
     `applyEnv`) when `--author` is not explicitly passed — mirrors the existing
     `WIKI_WORKSPACE` injection. Explicit `--author` wins over the env var.
   - Usage text updated.

2. **`PageCommand.Action.upsert` gains `author: String? = nil`**, threaded to
   `PageUpsert.upsert(author:)`. The workspace write branch (`workspaceWritePage`)
   does not yet carry author (staging path; provenance lands on merge — deferred).

3. **Spawn-time injection (`WikiFSEngine`).**
   - `AgentLauncher.run` (one-shot: ingest/lint/query) injects
     `env.WIKI_AUTHOR = "agent:<kind>"` (e.g. `agent:ingest`).
   - `AgentLauncher.startInteractiveQuery` (chat) injects
     `env.WIKI_AUTHOR = "chat:<chatID>"` when a chatID is present — so
     `created_by`/`last_edited_by` points back to the originating conversation.
   - `ACPBackend.resolveSpawnConfig` expands `env.`-prefixed providerHints into
     the child environment (existing convention), so `wikictl` sees `WIKI_AUTHOR`.

### Provenance value shape

- Chat-driven: `chat:<chatID>` (resolves via `[[chat:…]]`).
- Standalone runs: `agent:<kind>` (`agent:ingest` / `agent:lint` / `agent:query`).
- Explicit override: whatever the caller passes to `--author`.

Workspace writes (`--workspace`) record the version on `page_versions` but
`last_edited_by` there is out of scope; provenance flows to `pages` on merge.

## Tests

- Parser: `--author` parsed; absent → nil. (`AgentCASTests`/`WikiCtlCommandTests`)
- Env routing: `WIKI_AUTHOR` applied by `applyEnv`; explicit `--author` wins.
- End-to-end: `PageCommand.run(.upsert(..., author: "chat:X"))` → page's
  `created_by`/`last_edited_by` == `"chat:X"`.
- Launcher injection unit-tested via the `env.WIKI_AUTHOR` providerHint.
