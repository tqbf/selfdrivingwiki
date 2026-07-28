---
timestamp: 2026-06-16T143126Z
title: "2026-06-16 — LLM Wiki Phase D: the schema — DONE ✅ (gate passed)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-16 — LLM Wiki Phase D: the schema — DONE ✅ (gate passed)

## Progress


Branch `llmwiki/phase-d-schema` (stacked on `llmwiki/phase-c-claude-ops`).
Implements `plans/llm-wiki.md` Phase D: replaces the stub `SystemPrompt.defaultBody`
with the real wiki-maintainer schema, and slims the operation `-p` prompts now that
the schema is delivered every run via `--append-system-prompt`. **Cheap, mostly
prose — no new views, no migration changes.**

**Verified (live gate — user created the wiki; orchestrator verified via Bash; real `make clean && make install`, real-signed, fresh wiki `GateD`)**
- **Byte-identity ✅:** a freshly-created wiki's `CLAUDE.md` ≡ `AGENTS.md` ≡ the
  seeded `system_prompt` row body — all `sha256 f3174a5b…`, **5362 bytes**, the
  new "# Wiki Maintainer Instructions" schema (read raw via `writefile` to avoid
  the `sqlite3`-CLI trailing-newline artifact). The projection serves the same
  body under both names, as in the post-v0 system-prompt gate.
- **Agent reads it ✅:** a real `claude -p` launched with the new schema as
  `--append-system-prompt` named the FULL `wikictl` surface from its instructions
  alone — `page list/get/upsert/delete`, `index set`, `log append --kind …`.
- **Migration ✅:** the new wiki seeds the new schema; an EXISTING wiki
  (`GateCFresh`) is **unaffected** — still the old 762-byte stub (no `wikictl`),
  exactly as required (only `defaultBody`, the v2→3 seed + projection fallback,
  changed; no path rewrites an existing row).
- **Prompt de-duplication ✅:** the ~30-line `toolingPreamble` (layout +
  `wikictl` cheatsheet + read-after-write rule) is GONE from the `-p` prompts —
  each op now carries just the task + the resolved `WIKI_ROOT` (+ Ingest's source
  path / Query's question), relying on `CLAUDE.md` (via `--append-system-prompt`)
  for the schema. The exact seam the user flagged during Phase C.
- 211 → **221** tests (also fixed the last same-millisecond ULID flake), all green.

**What changed**
- **`SystemPrompt.defaultBody` is now the real maintainer schema** (`WikiFSCore/
  SystemPrompt.swift`) — addressed to the maintaining agent ("You maintain this
  wiki…"), tight and skimmable. Documents: the **layout** (`pages/by-{title,id}`,
  immutable `files/by-{name,id}`, `index.md`/`log.md`/`TREE.md`, `indexes/*.jsonl`,
  `manifest.json`, `CLAUDE.md`≡`AGENTS.md`); **conventions** (page titling,
  `[[wiki links]]`/`[[Target|alias]]`, summarize-don't-discard, entity vs concept
  page shapes, citing sources by their `files/…` path); **tooling** — the full
  `wikictl` command reference (`page list/get/upsert/delete`, `index set`,
  `log append`), **write via `wikictl` NEVER the filesystem** (mount is read-only),
  `wikictl` on PATH + targets the wiki via `WIKI_DB` (do NOT pass `--wiki`), and the
  **read-after-write rule** (read back via `wikictl page get` because the mount lags
  ~5s); **workflows** — the Ingest/Query/Lint playbooks in order; **sources** — raw
  `files/` may be PDFs/images, use the `Read` tool (PDF text first, images
  separately). This IS each wiki's per-wiki `CLAUDE.md`/`AGENTS.md`; the user
  co-evolves it in-app.
- **Slimmed the operation `-p` prompts** (`WikiOperation.swift`). The Phase-C
  `toolingPreamble` (layout map + `wikictl` cheatsheet + read-after-write rule) is
  REMOVED — that content now lives only in the system prompt, delivered every run via
  `--append-system-prompt`. Each prompt is now the per-op task + the per-run facts
  the schema can't contain: the resolved absolute `WIKI_ROOT` and (Ingest) the
  source's absolute path / (Query) the question. E.g. Ingest is now "Follow the
  Ingest workflow from your instructions… WIKI_ROOT: `<abs>` Source: `<abs>/…`". DRY
  against the schema — no second copy of the layout/cheatsheet to drift.
- **Migration UNCHANGED — verified, not disturbed.** The v2→3 seed and the
  projection fallback both reference the same `defaultBody` constant, so changing the
  constant seeds NEW wikis with the new schema while leaving EXISTING wikis untouched
  (the seed runs only inside `if version < 3` at table-creation; there is no code
  path that rewrites an existing `system_prompt` row to the default). A new test
  (`existingSystemPromptRowIsNotOverwrittenOnReopen`) pins this. `CLAUDE.md`≡
  `AGENTS.md`≡seeded body still holds structurally (both projection nodes serve
  `systemPromptDocument().body`, which returns the seeded `defaultBody`).

**Also in this phase — hardened File Provider domain registration (Phase D gate
finding).** During the Phase D gate a freshly-created wiki ("GateD") did NOT mount
until the app was relaunched, with NO error shown. The create→register→mount code
path was logically correct (`WikiManager.createWiki` → `registerDomain` →
`FileProviderSpike.registerDomain` → `NSFileProviderManager.add(domain)`, the same
call launch uses), but registration was **brittle and silent under a busy/churned
`fileproviderd`**: a single `add(domain)` that swallowed any error into an
unsurfaced `status` string and never verified/retried/nudged. Hardened
`FileProviderSpike.registerDomain(id:displayName:)` WITHOUT changing its injected
shape:
- **Surfaces failures** — a real `add` error is now `print`ed to the console AND
  kept in `status` (never buried); already-exists stays benign (the verify below
  confirms presence).
- **Verifies + bounded retry** — after each `add` it confirms the domain actually
  appears in `NSFileProviderManager.domains()`; if a busy daemon didn't take it, it
  backs off (~0.6 s async sleep — never blocks the main actor) and retries, up to 3
  attempts, then fails LOUDLY (console + `status`) and returns `false`.
- **Nudges initial enumeration** — on a verified add it signals the new domain's
  `.rootContainer` + `.workingSet` enumerator (the same `signalEnumerator` path
  `signalChange` uses, scoped to THIS domain) so the daemon materializes the root
  promptly instead of waiting for an external trigger — this is what makes the mount
  appear right after create.
The decision arithmetic (registered? / retry? / failed?) is extracted into a PURE,
unit-tested `WikiFSCore/DomainRegistrationPolicy` (mirroring `PathPreflight`) so the
FileProvider-importing `FileProviderSpike` stays thin side-effect glue. Idempotent +
safe to call repeatedly (launch calls it per wiki via `registerAllDomains`, create
once); the `WIKIFS_REENUMERATE` one-shot remove+re-add hatch is preserved.
`DomainRegistrationPolicyTests` (10) covers exact-match membership, the
retry-while-attempts-remain / fail-after-max decision table, and full-loop
simulations (registers on the final attempt; fails when the domain never appears).
**Guaranteed by the code:** on a healthy-but-momentarily-busy daemon, create→mount
is immediate (verify+retry+nudge) and any real failure is loud + self-healing rather
than silent. **Still daemon-dependent:** a fully *wedged* replica (the `ISSUES.md`
churned-domain case) is NOT rescued by retry — it needs a domain teardown — and the
exact end-to-end timing can't be proven without a clean (un-churned) `fileproviderd`.

**Tests/build.** Updated `OperationCommandTests` to the slimmed prompt shape: each
prompt now carries the resolved `WIKI_ROOT` and defers to "the … workflow from your
instructions", and the inline layout map / `wikictl` cheatsheet / read-after-write /
`--wiki` reminders are asserted GONE. New `SystemPromptTests` pin the schema content
(names every `wikictl` command, the layout, conventions, workflows, the PDF/Read
note) and the migration invariant (existing row not overwritten). **Also fixed the
last same-millisecond ULID flake** (`PageUpsertTests.upsertByTitleResolvesDuplicate
ToLowestULID` assumed creation order == ULID order; `ULID.generate()` is NOT
monotonic within a ms, so it now derives the expected lowest id from the actual ids
— matching the fix already applied to `WikiLinkNavigationTests`/`WikiLinkStoreTests`).
`make test` → **221/221 green** (211 schema-phase + 10 `DomainRegistrationPolicyTests`);
`make` produces a clean signed bundle (app + appex + `wikictl`, real identity).

**Notes / what the independent verifier should watch (the Phase-D gate)**
- The new default is **byte-identical** across a wiki's `CLAUDE.md` and `AGENTS.md`
  and matches the seeded DB body (use a freshly-created wiki; one-shot
  `WIKIFS_REENUMERATE=1` may be needed to surface the files on an already-materialized
  domain).
- A fresh `claude -p` launched against a NEW wiki reads the schema as its system
  prompt and **can name the `wikictl` commands** (`claude` on PATH; macOS-26 TCC
  prompt re-fires on a re-signed install).
- Migration seeds new wikis with the new schema; **existing wikis are unaffected**.

## Verification

Historical verification remains in the progress record above.
