---
timestamp: 2026-06-16T135648Z
title: "2026-06-16 — Phase C gate fix: skip-permissions + layout-up-front + `TREE.md` — DONE ✅ (folded into the Phase C gate pass below)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-16 — Phase C gate fix: skip-permissions + layout-up-front + `TREE.md` — DONE ✅ (folded into the Phase C gate pass below)

## Progress


The first live Phase-C gate FAILED with two real defects (still DRAFT — re-gate
pending). Fixing exactly these on `llmwiki/phase-c-claude-ops`:

1. **Every command the agent issued was rejected → ZERO output.** The
   `--allowedTools 'Bash(wikictl:*) Bash(cat:*) …'` allowlist can't statically
   verify a command containing a `$WIKI_ROOT`/`$WIKI_DB` shell expansion or a
   compound command, so the CLI demanded approval — and in `-p` (non-interactive)
   mode there is no approval prompt, so the run was dead on arrival (no page, no
   log, no index bump). The allowlist is fundamentally incompatible with the
   env-var paths the whole design depends on. **Fix:** dropped the `--allowedTools`
   pair, now pass **`--dangerously-skip-permissions`** — the "frictionless mode"
   fallback `plans/llm-wiki.md` sanctions (app is local, un-sandboxed,
   user-initiated; the agent only has `wikictl` + read-only shell intent). Verified
   accepted by the installed CLI (2.1.178 — a real `-p … --dangerously-skip-permissions`
   run reports `permissionMode":"bypassPermissions"`). Everything else on the argv
   is unchanged.
2. **The agent burned ~6 turns probing for basic structure** (`ls`, `env`,
   `mount`, `wikictl --help`) because it had no map. **Fix, two parts:**
   - **In-prompt layout (load-bearing).** `WikiOperation.prompt` is now
     `prompt(wikiRoot:)` and leads with a concrete map: the **resolved absolute
     `WIKI_ROOT`** (passed in — not `$WIKI_ROOT` for the agent to expand, which is
     exactly what the permission system choked on AND what made it hunt), the fixed
     `pages/by-{title,id}` + `files/by-{name,id}` + `index.md`/`log.md`/`TREE.md`/
     `manifest.json`/`indexes/*.jsonl` layout, the `wikictl` cheatsheet (incl. the
     exact `printf '%s' "<body>" | wikictl page upsert --title T --body-file -`
     form), and that `wikictl` is on PATH + already targets the wiki via `$WIKI_DB`
     (so do NOT pass `--wiki`). For Ingest, the **chosen source's resolved absolute
     path** is injected so the agent reads it immediately instead of hunting.
   - **`TREE.md` at the wiki root** — a new read-only projection (`WikiTreeRenderer`,
     pure) served exactly like `log.md`/`index.md` (new container id `tree-md`, root
     child, working-set re-emit, `contents`). It is the same orientation map,
     largely STATIC (the projection layout is fixed) plus two cheap live counts
     (pages, files). Versioned by `changeToken()` like `log.md` — NOT a separate
     token term: the only thing that moves is the two counts, and those move with
     the same page/file folds the token already tracks, so a token-versioned node
     re-fetches precisely when the counts can change. Prompts reference it ("full
     layout is in `TREE.md`").

**KEPT exactly as-is** (they work — they're how we SAW the failure): the streaming
activity panel, `AgentEvent`/`AgentEventParser`, the backend `run.jsonl`/
`run.stderr.log`, the per-wiki edit lock, the change-bridge live refresh, and the
`claude` PATH preflight.

**Tests/build.** `OperationCommandTests` updated: argv now asserts
`--dangerously-skip-permissions` (no `--allowedTools`); the prompt builder is
asserted to lead with the layout + resolved `WIKI_ROOT` + cheatsheet + (Ingest)
the resolved source path. New `WikiTreeRendererTests` covers the layout/cheatsheet
content, the live counts (incl. singular/plural), and determinism. `make test`
green at **184**; `make` produces a clean signed bundle.

(Original Phase-C build notes below — the parts about `--allowedTools` are
superseded by the skip-permissions switch above.)

## Verification

Historical verification remains in the progress record above.
