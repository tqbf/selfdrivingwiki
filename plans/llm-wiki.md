# LLM Wiki — WikiFS as a self-maintaining knowledge base

**What this adds.** Turns WikiFS from a hand-edited wiki into the
[LLM Wiki pattern](../problems/): an LLM (`claude -p`) *writes and maintains* the
wiki — ingesting raw sources, authoring summary/entity/concept pages,
cross-linking, and keeping a curated index + chronological log current. The human
curates sources and asks questions; the agent does the bookkeeping. WikiFS is the
"Obsidian" in the pattern (the live viewer) and the storage; `claude -p` is the
maintainer.

A user keeps **many** wikis, not one — a personal wiki, a research wiki, a
per-book wiki, a work wiki — each an independent knowledge base with its own
sources, schema, pages, index, and log. Multi-wiki is foundational here (Phase 0),
not an afterthought; v0 was single-wiki and everything below is wiki-scoped.

This doc is the source of truth for *what we're adding and in what order*. Read
`PLAN.md` then `PROGRESS.md` first; read this before starting Phase 0.

## How the pattern maps onto what we already have

The pattern's three layers already exist in WikiFS — only the wiki's **write
path** is missing.

| Pattern layer | WikiFS today | Work |
| --- | --- | --- |
| **Raw sources** (immutable) | `files/` ingestion — verbatim bytes in SQLite, read-only under `files/by-{id,name}` | none — done |
| **The schema** (`CLAUDE.md`/`AGENTS.md`) | `system_prompt` singleton projected read-only at root as both names | rewrite the *content* (Phase D) |
| **The wiki** (LLM authors it) | `pages/` projected **read-only** + generated `indexes/*.jsonl`, `manifest.json` | **the agent can't write it** — Phases A–C |
| Ops: Ingest / Query / Lint | `AgentLauncher` spawns `zsh -lc <cmd>` with `WIKI_ROOT`, streams output | claude -p operations (Phase C) |
| `index.md` / `log.md` | machine `indexes/*.jsonl` only | curated `index.md` + append-only `log.md` (Phase B) |

## Core architecture: read via the mount, write via `wikictl`

The POC's non-negotiable invariant is **the File Provider mount is read-only;
SQLite is the source of truth.** The pattern needs the LLM to continuously
*write* the wiki. We do **not** resolve this by making the File Provider writable
(huge `createItem`/`modifyItem` write-back effort that dissolves the invariant
that is the point of the POC). Instead we split the two directions:

- **Read path = the File Provider mount.** The agent (and Finder/the app) browse
  with `find`/`grep`/`cat`. Unchanged — this is the POC showcase.
- **Write path = `wikictl`**, a new CLI that writes straight to the same App
  Group SQLite. The mount stays read-only; SoT stays SQLite; writes simply never
  go through the filesystem.

```
  claude -p ──reads──>  WIKI_ROOT mount (read-only)   ──projects── SQLite
        │                                                            ▲
        └──writes──>  wikictl  ──writes──>  SQLite (App Group DB) ───┘
                          │
                          └── Darwin notification ──> app: refresh UI + signalChange()
```

Two consequences this design must handle (below): the app has to **learn about
external writes** (to refresh its sidebar and signal the File Provider), and the
agent's **read-after-write** within a run must dodge the ~5 s mount-refresh lag.

## Many wikis: one DB + one File Provider domain per wiki

A user has **N independent wikis**. Each is fully self-contained:

- **One SQLite DB per wiki** — its own `<wiki>.sqlite` in the App Group
  container. The existing schema is unchanged; the per-wiki singletons
  (`system_prompt`, `wiki_index`) are just rows in *that wiki's* DB, so no
  `wiki_id` columns and no per-query filtering. A wiki is a single portable,
  git-able file; deleting one = drop the file + remove its domain.
- **One `NSFileProviderDomain` per wiki** — each mounts at its own
  `~/Library/CloudStorage/WikiFS-<name>` in Finder's sidebar. `NSFileProviderManager`
  is built for multiple domains; this leans *harder* into the File Provider API
  than v0 did (v0 registered exactly one domain).
- **A registry** — the set of wikis (id, display name, DB filename, domain
  identifier, created/last-used). Smallest form: a `wikis.json` (or a tiny
  registry DB) in the App Group container. The app reads it to populate the
  switcher and to register each domain on launch.

**Extension wiring (the crux):** the File Provider extension is instantiated
**per domain**. `init(domain:)` receives the `NSFileProviderDomain`; its
`identifier` is the key that maps domain → which `<wiki>.sqlite` to open. The
Phase-2 projection logic is otherwise unchanged — it just opens the DB the domain
points at instead of the single hardcoded path.

**Everything downstream is wiki-scoped:**

- `wikictl` takes `--wiki <id>` (or `WIKI_DB` env) — it writes to that wiki's DB
  and posts a notification naming that wiki.
- `claude -p` runs against **one** wiki: `WIKI_ROOT` = that wiki's mount,
  `--append-system-prompt` = that wiki's `system_prompt`, `--wiki` passed through
  to `wikictl`.
- The change bridge keys reactions by wiki (which sidebar/domain to refresh).
- The edit-lock is per-wiki (locking one wiki's editor doesn't freeze the others).

The authoring loop (Phases A–D) is built **on top of** this foundation, so it is
wiki-scoped from inception with no retrofit.

## Locked decisions

From the workshop (2026-06-15):

0. **Many wikis = one DB + one FP domain each** (not a shared DB with `wiki_id`).
   Multi-wiki foundation lands **first** (Phase 0); Phases A–D build on it.

1. **Write path = `wikictl` CLI** (not an MCP server, not a writable FP). MCP can
   layer on later over the same core ops.
2. **Driving UX = discrete operations** — Ingest / Query / Lint as explicit
   actions, each a one-shot `claude -p`. Not a persistent chat pane (yet).
3. **Both `log.md` and a curated `index.md`** — agent maintains both per ingest.
4. **Agent cwd = a writable scratch dir, `WIKI_ROOT` env = the mount.** Not the
   mount itself (read-only; Claude Code needs a writable cwd for session/todo
   scratch). The agent is **not** chrooted/sandboxed — it just needs to run
   `wikictl`, see the tree under `$WIKI_ROOT`, and run read-only bash on it.
   Schema delivered via `--append-system-prompt` read from the `system_prompt`
   singleton (no `CLAUDE.md` copied onto the mount).
5. **Ingest = auto-apply, review after.** The agent runs to completion; the
   live-updating app *is* the diff; git is the undo. No propose-then-confirm, no
   `--resume` session machinery in v1.
6. **Lock in-app editing during an agent run** — the editor goes read-only (with
   a banner) while `claude -p` runs, to prevent the autosave-vs-agent clobber
   race. Re-enabled on completion.

## Components

### `wikictl` — the agent's hands

A new SwiftPM **executable target** depending on `WikiFSCore`. Takes `--wiki <id>`
(or a `WIKI_DB` env var) selecting which wiki's `<wiki>.sqlite` to open within the
App Group container — resolved through the same registry the app uses. Opens it
read-write via the literal App Group path the un-sandboxed app uses (no entitlement
needed; WAL + `busy_timeout=5000` already make a second writer process safe).
Ad-hoc signed is fine — it's launched by the un-sandboxed app.

Command surface (stdin/stdout, scriptable):

- `wikictl page list` — id, title, path per line (JSON or TSV).
- `wikictl page get --title X | --id Y` — prints the body. **Instant SoT read** —
  this is the read-after-write escape hatch (bypasses the ~5 s mount lag).
- `wikictl page upsert --title X [--id Y] --body-file -` — create-or-update;
  resolves title→id via `resolveTitleToID`; reparses `[[links]]` + `replaceLinks`
  in the same op; prints the resulting id.
- `wikictl page delete --id Y`.
- `wikictl log append --kind ingest|query|lint --title "…" [--note "…"]` —
  appends one dated row (Phase B).
- `wikictl index set --body-file -` — rewrites the curated index singleton (Phase B).

After every committing call, `wikictl` **posts a Darwin notification**
(`org.sockpuppet.wiki.changed`, carrying the wiki id) so the app can react.
`wikictl` never signals the File Provider itself — that stays the app's job
(single owner of FP signaling, per domain).

### Change bridge — app reacts to external writes

The app today only calls `signalChange()` from its own `onPageDidChange`. New: the
app **observes the Darwin notification**, reads the wiki id it carries, and for
*that* wiki:

1. rebuilds `summaries` from its store (sidebar updates live, if it's the wiki on
   screen), and
2. calls `signalChange()` on **that wiki's domain** (its mount refreshes within
   the usual ~5 s).

**Debounce** per wiki (~250 ms coalesce): a single ingest fires ~15 `wikictl`
calls in a burst; we don't want 15 sidebar rebuilds + 15 FP signals.

### Shared link-reparse refactor

"Upsert a page + reparse `[[links]]` + `replaceLinks`" currently lives inside
`WikiStoreModel.save()`. Lift it into a shared `WikiFSCore` operation so the app
*and* `wikictl` keep the link graph consistent **identically** (no second,
drifting implementation in the CLI).

### `log.md` — append-only chronological log (Phase B)

New `log` table (id ULID, ts, kind, title, note). Projected **read-only at root**
as `log.md`, rendered as grep-able lines:

```
## [2026-06-15] ingest | Article Title
## [2026-06-15] query  | "How does X compare to Y?"
```

So `grep "^## \[" log.md | tail -5` works, exactly as the pattern recommends.
`wikictl log append` writes a row.

### `index.md` — curated catalog (Phase B)

A **singleton agent-maintained doc**, modeled on the existing `system_prompt`
singleton (its own table row, versioned, folded into `changeToken()`). Kept out
of the `pages/` namespace and projected **read-only at root** as `index.md`. The
agent rewrites it wholesale via `wikictl index set` on each ingest. Distinct from
the machine `indexes/*.jsonl` (which stay as cheap programmatic nav).

### DB migrations

Two stepwise migrations slotted into the existing `bootstrapSchema()` ladder
(currently at `user_version 3`):

- **v3→4** — `log` table.
- **v4→5** — `wiki_index` singleton (`id INTEGER PRIMARY KEY CHECK(id=1)`,
  `body_markdown`, `updated_at`, `version`), seeded with an empty/default index.

`changeToken()` folds in both new versions (same reasoning as the `spVersion`
fold): editing only the index, or appending only a log entry, must still advance
the sync anchor or the projected `index.md`/`log.md` would never refresh. New
container ids added to the projection, the working set, and `signalChange()`.

### `claude -p` orchestration

The app spawns (via the existing `Process` plumbing, generalized from
`AgentLauncher`):

```
cd "$SCRATCH" && WIKI_DB=<wiki-id> claude -p "<operation prompt>" \
  --append-system-prompt "<this wiki's system_prompt body>" \
  --allowedTools 'Bash(wikictl:*) Bash(find:*) Bash(cat:*) Bash(grep:*) Read Grep Glob'
```

Each run targets **one** wiki (decision #0): `WIKI_ROOT`/`WIKI_DB` and the schema
all come from the currently-selected wiki.

- **cwd** = a per-run writable scratch dir (e.g. under the app's caches);
  `WIKI_ROOT` env = that wiki's live mount resolved from the FP manager at click
  time; `WIKI_DB` selects the wiki for `wikictl`.
- **Schema** delivered with `--append-system-prompt` from *that wiki's*
  `system_prompt` singleton (decision #4) — no `CLAUDE.md` written onto the
  read-only mount.
- **Least privilege** (decision, recommended): `wikictl` + read-only shell +
  read tools. `find`/`cat`/`grep` scoped so the agent browses but can't write the
  filesystem. (A `--dangerously-skip-permissions` frictionless mode is available
  if the scoping proves annoying, but default to the allowlist.)
- **Streaming**: plain-text stdout/stderr through the existing pipe
  `readabilityHandler`s for v1 (the panel already does this). `--output-format
  stream-json` for a richer tool-call view is a later polish.
- **Preflight**: check `claude` is on the login-shell PATH before spawning;
  surface a clear error if not.

### Edit lock during a run

While `claude -p` is running, the in-app editor is **read-only** (banner: "Agent
is updating the wiki…"); autosave is paused. Re-enabled on `terminationHandler`.
Prevents the last-writer-wins clobber between in-app autosave and `wikictl`.

### The schema content (Phase D)

Replace today's stub `SystemPrompt.defaultBody` with a real maintainer schema:

- **Layout** — `pages/by-{title,id}`, `files/by-{name,id}` (raw sources, immutable),
  `index.md`, `log.md`, `indexes/*.jsonl`, `manifest.json`.
- **Conventions** — page titling, `[[wiki links]]`, summarize-don't-discard,
  entity/concept page shapes, citing sources by `files/` path.
- **Tooling** — the `wikictl` reference; **write via `wikictl`, never the
  filesystem** (the mount is read-only); **read-back what you just wrote via
  `wikictl page get`** (the mount lags ~5 s).
- **Workflows** — the Ingest / Query / Lint playbooks below.
- **Sources** — raw `files/` may be PDFs/images; use `Read` on them directly; for
  a PDF, read text first, then view referenced images separately if needed.

You co-evolve this in-app over time — it *is* the pattern's "schema" layer.

## Operations

- **Ingest.** Raw drop (existing) stores immutable bytes under `files/`. A new
  **"Ingest into wiki"** action then spawns `claude -p` pointed at that source
  path: it reads the source, writes a summary page, updates relevant
  entity/concept pages, rewrites `index.md`, appends to `log.md` — all via
  `wikictl`. Auto-applies; you watch the sidebar fill in live (decision #5).
- **Query.** A question box spawns `claude -p` with read tools (+ `wikictl` to
  optionally file the answer back as a page, so explorations compound). Returns a
  cited answer in the output panel.
- **Lint.** A button spawns `claude -p` to health-check: contradictions, stale
  claims, orphan pages, missing cross-references, concepts lacking a page. Report
  in the panel; optionally files findings as a page / log entry.

## Phases

Stacked, unmerged branches off the current line, like v0 / the post-v0 features.

- **Phase 0 — Many wikis (foundation).** A wiki **registry** (id, name, DB
  filename, domain id); `DatabaseLocation` generalized to per-wiki DB paths; the
  extension maps `domain.identifier` → `<wiki>.sqlite`; the app registers **one FP
  domain per wiki** and gains a switcher to **create / select / delete** wikis
  (each new wiki = fresh DB seeded with the default schema + a new domain). The
  existing single v0 wiki migrates into the registry as wiki #1. *Gate:* create a
  second wiki in-app → it mounts as its own `~/Library/CloudStorage/WikiFS-<name>`;
  pages written in wiki A never appear in wiki B's mount; both DBs are independent
  files; deleting a wiki removes its domain + file; v0 single-wiki content
  preserved as wiki #1.
- **Phase A — Write path + change bridge.** `wikictl` (page upsert/get/list/
  delete) + the shared link-reparse refactor + Darwin-notification → debounced app
  refresh + `signalChange()`. *Gate:* `wikictl page upsert` writes a page → app
  sidebar updates → mount reflects it (~5 s) → filesystem writes still rejected →
  link graph (`indexes/links.jsonl`) reflects `[[links]]` the CLI wrote. All
  deterministic (no agent yet).
- **Phase B — `log.md` + `index.md`.** v3→4 + v4→5 migrations; `log` table +
  `log append`; `wiki_index` singleton + `index set`; both projected read-only at
  root; `changeToken()` + signaling folds. *Gate:* appended entries show grep-able
  prefixes in `log.md`; `index set` rewrites root `index.md`; prompt-only/log-only
  edits advance the sync anchor (refresh proven, no relaunch).
- **Phase C — claude -p operations.** Generalize `AgentLauncher` into Ingest /
  Query / Lint actions spawning scoped `claude -p` from a scratch cwd with
  `--append-system-prompt`; stream output; **lock in-app editing** during a run;
  live sidebar refresh as `wikictl` writes land. *Gate (structural, not content —
  the agent is non-deterministic):* drop a real source → Ingest → ≥1 summary page
  + ≥1 `log.md` entry + `index.md` changed, all visible on the mount; a query
  returns an answer; lint produces a report; editor locked during the run.
- **Phase D — The schema.** Replace `SystemPrompt.defaultBody` with the real
  maintainer schema documenting layout, conventions, `wikictl`, the read-after-
  write rule, and the three workflows. (Cheap; lands with or right after C since
  it documents `wikictl`.)

**Skills per phase (per `CLAUDE.md`):** run `swiftui-pro` before/after any view or
model code (Phase 0 switcher, Phase A change-bridge, Phase C UI); `macos-design`
for the wiki switcher / sidebar (Phase 0) and the Ingest/Query/Lint UI + edit-lock
banner (Phase C); `typography-designer` for any new type in those views (Phases 0, C).

## Accepted limitations (default; some → `ISSUES.md`)

- **Burst signaling** coalesced by a ~250 ms debounce in the app's notification
  handler.
- **Non-deterministic agent** → Phase C gates are *structural* (a page + a log
  entry + an index change exist), never exact-content assertions. `wikictl` and
  the bridge are the deterministically-tested seams.
- **Kill-mid-ingest leaves partial state** (a page written, `index.md`/`log.md`
  not yet). Accepted for the POC — no cross-call transactionality. → `ISSUES.md`.
- **New root files** (`index.md`, `log.md`) need the one-shot
  `WIKIFS_REENUMERATE=1` launch on an already-materialized domain (same as
  `CLAUDE.md`/`files/`); fresh installs are fine.
- **Read-after-write ~5 s** on the mount (existing `ISSUES.md` item) — the agent
  sidesteps it with `wikictl page get`; documented in the schema.
- **Raw sources are bytes-only** (no extraction — Phase-5 scope). The agent reads
  PDFs/images via the `Read` tool directly from `files/`.

## Open risks to watch

- `claude -p`'s exact flag surface for `--append-system-prompt` / `--allowedTools`
  scoping (verify against the installed CLI version in Phase C; adjust the
  allowlist syntax as needed).
- Two-writer contention under a fast agent burst (WAL should hold; watch for
  `SQLITE_BUSY` past the 5 s timeout and back off in `wikictl`).
- **Per-domain registration limits / lifecycle** — many `NSFileProviderDomain`s
  at once (any practical cap? add/remove timing on create/delete-wiki), and
  whether each new domain needs its own one-shot `WIKIFS_REENUMERATE` settle on
  first mount. Verify on the multi-domain spike in Phase 0.
- **Wiki identity must be stable** — the domain identifier ↔ DB filename mapping
  has to survive rename (display name changes, identity doesn't). Use the wiki's
  ULID, never its display name, as the domain identifier / DB key.
