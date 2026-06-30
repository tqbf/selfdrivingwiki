# Project Memory wiki — the Self Driving Wiki's own development memory, maintained headlessly by agents

> **Status:** Proposed (not started).
> **Depends on:** [`llm-wiki.md`](llm-wiki.md) (the `wikictl` write path and the
> agent ingest model this builds on), [`wikictl-file-reads.md`](wikictl-file-reads.md)
> (read-via-SQLite, write-via-`wikictl`), [`search-fts5-hybrid.md`](search-fts5-hybrid.md)
> (the FTS5 + per-chunk vec index that fires on every `page upsert` — the recall engine).

## Goal — dog-food the wiki as project memory

Use the wiki's own core to **maintain a living wiki of this project's own
development**, completely headlessly — no SwiftUI app, no File Provider mount, just CLI
and the same `claude -p` agent the app's ingest uses. Not a one-off rendering of a
folder: a **Project Memory** wiki, built from the whole development knowledge corpus and
**both consulted and extended by agents during normal work**.

The recursion is the point. This app is a *self-driving wiki* — an LLM authors and
maintains its content. Its own development should be driven by a wiki it maintains. That
closes the dog-food loop: we use the thing we built, on the corpus we know best, as the
memory layer for building it further.

The job is **idempotent and re-runnable daily**: ingest only corpus files that are new
or changed since the last run, capture the supersession relationships the corpus already
contains, and **never clobber memory that agents wrote by hand**.

## The memory thesis

Today the handoff is "read [`PLAN.md`](../PLAN.md) then [`PROGRESS.md`](../PROGRESS.md)"
— a 33 KB curated index plus a 272 KB reverse-chronological log. That is *linear
reading*, not *recall*. The corpus already has latent structure: `PLAN.md` is an index,
`PROGRESS.md` is a dated log, plans supersede each other, `ISSUES.md` records
decisions-we-chose-to-live-with. The wiki turns that corpus into **addressable memory**:
ask "why is the File Provider mount read-only" and get a cited answer from the relevant
page instead of grepping a quarter-megabyte log. The shipped hybrid FTS5 + per-chunk vec
search (`#91`) is the recall engine; `wikictl search` / `page get` is the recall API.

## The corpus — source classes

The scope is the **full markdown corpus**, not just `plans/`. The corpus is
heterogeneous, so ingest is **class-aware** — a 272 KB linear log is not ingested like a
47-doc design set. Every class reuses the same write primitives (`page upsert`,
`index set`, `log append`) and `[[wikilink]]` cross-referencing.

| Class | Sources | Ingest semantics |
| --- | --- | --- |
| **Spine** | [`PLAN.md`](../PLAN.md), [`PROGRESS.md`](../PROGRESS.md), [`ISSUES.md`](../ISSUES.md) | `PLAN.md` → seed the index + a Roadmap/Status page; `PROGRESS.md` → milestone/feature pages + `log append` entries; `ISSUES.md` → known-issues pages |
| **Design** | `plans/*.md` (47) | one page each; supersession captured (see below) |
| **Agreement** | [`AGENTS.md`](../AGENTS.md)/[`CLAUDE.md`](../CLAUDE.md), [`SWIFTUI-RULES.md`](../SWIFTUI-RULES.md) | rule / reference pages |
| **Reference** | [`README.md`](../README.md), [`docs/hybrid-search.md`](../docs/hybrid-search.md), `docs/skills/*` | overview + reference pages |

The Design path is the original plans-only design, now one class among four. Supersession
examples the corpus already contains: [`phase-b-source-wikilinks.md`](phase-b-source-wikilinks.md)
supersedes the Phase B portion of [`sources-redesign.md`](sources-redesign.md);
[`tab-context-menu-rebuild.md`](tab-context-menu-rebuild.md) supersedes the deleted
`multi-tab-editor.md`; [`textual-to-wkwebview.md`](textual-to-wkwebview.md) replaces the
Textual reader; search evolved `semantic-search → source-semantic-search →
search-fts5-hybrid`.

## Background — what already works, and the gaps

The core is already driveable without the app: `wikictl` writes straight to a wiki's
`<ulid>.sqlite` in the App Group container and reads are instant SoT reads; the app and
the File Provider mount are a GUI convenience. Today `wikictl` covers `page
upsert/get/list/delete`, `index set`, `log append`, `search`, and the `source` family.

Three facts shape this plan:

1. **`wikictl` cannot create a wiki** (no `wiki create`). Everything a `create` needs is
   already public in `WikiFSCore` (`WikiDescriptor.make`, `SQLiteWikiStore(databaseURL:)`
   which auto-runs `bootstrapSchema()` and seeds `system_prompt` + `wiki_index`,
   `WikiRegistry.load/add/save`, `DatabaseLocation.appGroupContainerDirectory()`). New
   content goes in via `page upsert`; we add one small subcommand to mint the wiki itself.
   No File Provider code is involved (`WikiManager`'s `registerDomain` closure stays nil).

2. **The wiki cannot represent supersession structurally.** A `WikiPage` is flat
   (`id/title/slug/body_markdown/version`), `page_links` stores **untyped** wikilinks, and
   frontmatter is minimal (see [`page-body-contract.md`](page-body-contract.md): `title` +
   `date`). So supersession lives as prose + `[[wikilinks]]` in page bodies and in the
   curated index — not as queryable data. A structured `superseded_by` column would be a
   schema migration; out of scope here.

3. **The corpus is heterogeneous**, so ingest must be class-aware (the table above) rather
   than one-size. The original doc proved the Design-class path; the other classes reuse the
   same primitives.

## Decision

- **Ingest method:** LLM agent synthesis — drive the same `claude -p` engine the app's
  ingest uses (`WikiOperation` / `OperationCommand` / `IngestPlan`), headlessly, one file
  at a time, with a per-class prompt branch.
- **Identity:** a **"Project Memory"** wiki.
- **Sources:** the full markdown corpus, ingested class-aware.
- **Order:** **design docs** process in git introduction order, oldest first, so a
  superseding plan is always ingested after the page it supersedes already exists
  (supersession becomes a simple back-annotation). Spine / agreement / reference docs are
  **living singletons** — re-ingested whenever their blob changes, order-independent.
- **Supersession capture:** prose + `[[wikilinks]]` + a curated `index.md` "Supersession
  History" section. No schema change.
- **Incrementality:** a **corpus manifest stored inside the wiki** (keyed by git blob SHA)
  lets daily re-runs skip unchanged files and pick up edits.
- **Bidirectional:** a recall + record convention (Phase 4) so dev agents both read from
  and write development memory back into the wiki — not only the daily batch.

## Phase 1 — `wikictl wiki create` / `wiki use` subcommands

The only app change. Mirrors the existing `WikiCtlCore` library + thin executable split
(logic out of the executable, so it's unit-testable).

### `Sources/WikiCtlCore/ArgumentParser.swift`

- Add to `Command`: `case create(displayName: String)` and `case use`.
- Add `"wiki"` to the top-level dispatch (beside `page`/`source`), routing to a new
  `parseWikiCommand` accepting `create --name <X>` and `use` (throw `.usage` on a missing
  name or unknown subcommand).
- Add to `usageText`:
  ```
  wiki create --name <display-name>      create a new empty wiki, print its id
  wiki use [--wiki <id|name>]            make a wiki most-recently-used (active on next app launch)
  ```
- `create` is special — it does **not** require `--wiki`/`WIKI_DB` (there is no existing
  wiki to select). Special-case it before the selector requirement. `use` takes `--wiki <sel>`.

### `Sources/WikiCtlCore/WikiCreateCommand.swift` (new)

Pure, container-injected logic mirroring `PageCommand.swift`:

- `create(displayName:containerDirectory:)` → `WikiDescriptor.make(displayName:)`, open
  `SQLiteWikiStore(databaseURL:)` once to create + bootstrap the DB, then `WikiRegistry.load
  → add → save`. Returns the descriptor.
- `use(selector:containerDirectory:)` → resolve the selector to an id (via the existing
  `WikiResolver`), `WikiRegistry.load → touch(id:) → save`. This bumps MRU; the app opens
  `WikiRegistry.mostRecentlyUsed` at launch (`WikiManager.bootstrap` → `openActive`), so MRU
  is the only lever to surface a specific wiki.

### `Sources/wikictl/main.swift`

- Handle `.create` **before** the `resolver.descriptor(forSelector:)` step. Use
  `resolver.containerDirectory`. Print the **new ULID to stdout** (one line,
  machine-readable) and a human line to stderr, so scripts can do
  `WIKI_ID=$(wikictl wiki create --name "Project Memory")`. Do not seed a Home page — the
  agent writes the index + pages; `wiki_index` is already seeded by the store bootstrap.
- Handle `.use` via `WikiCreateCommand.use`.

### `Tests/WikiFSTests/`

- Arg-parse tests: `wiki create --name X` → `.create("X")`; missing name throws `.usage`;
  `wiki use --wiki Y` parses (matches the existing parser-test style).
- Integration test: run `WikiCreateCommand.create` against a temp container; assert
  `<ulid>.sqlite` exists, `wikis.json` contains the descriptor, reopening the store lists
  zero pages with a seeded `wiki_index`; then `use` bumps `mostRecentlyUsed`.

Build is unchanged: `swift build` → `.build/debug/wikictl`; `./build.sh`/`make` also copy
it to `./build/wikictl`.

> **Caveat:** a *running* app discovers wikis via the registry at `bootstrap`; a wiki
> created headlessly won't appear (or get its FP domain registered) until the app reloads
> the registry / relaunches. Irrelevant for the headless pipeline; only matters for browsing
> it in the GUI (Phase 4 handles that via `make run-memory`).

## Phase 2 — Incremental pipeline `scripts/build-project-memory.sh`

A new portable bash script (`#!/usr/bin/env bash`; standalone), designed to be re-run any
time, over the **full corpus** (not just `plans/`):

1. **Build** `wikictl` (`swift build`), resolve `WIKICTL=.build/debug/wikictl`.
2. **Ensure the wiki exists.** Resolve `--wiki "Project Memory"`; if absent,
   `WIKI_ID=$("$WIKICTL" wiki create --name "Project Memory")`. Export `WIKI_DB`, and put
   `wikictl`'s dir on `PATH` for the agent.
3. **Read the corpus manifest** (Phase 3) from the wiki:
   `"$WIKICTL" --wiki "Project Memory" page get --title "Ingest Manifest"` → `relpath →
   blobSha` map. Empty/absent on a fresh wiki.
4. **Compute the delta** over the **full corpus file set** (the source-class table), not just
   `plans/*.md`. Content identity is `git hash-object "<file>"` (working-tree blob SHA —
   catches an edited `PROGRESS.md`, a re-grounded plan, a rule-sheet tweak). A file is in the
   delta if its path is absent from the manifest **or** its blob SHA differs. Empty delta →
   print "up to date" and exit 0 (zero `claude` calls — a cheap daily no-op).
5. **Order the delta.** **Design docs** oldest-first by git add-date
   (`git log --diff-filter=A --follow --format='%aI' -- "$f" | tail -1`, sorted ascending;
   same-day ties fall back to commit order). Spine / agreement / reference docs are
   order-independent singletons. The design-doc ordering is what makes supersession capture work.
6. **Ingest each delta file in order** via one `claude -p` invocation per file (mirrors the
   app's one-source-at-a-time ingest). Each invocation receives the file path, its **class**
   (so the prompt branches), [`PLAN.md`](../PLAN.md) as the supersession reference, the Phase 3
   prompt, `WIKI_DB`, and `wikictl` on `PATH`. The agent reads the file from the working tree,
   calls `wikictl page list`/`page get` to see what exists, and writes via `page upsert` /
   `index set` / `log append`. On success, update the in-memory manifest with the new blob SHA.
7. **Persist the manifest** (Phase 3) and run one **curate pass** (`claude -p`): rebuild
   `index.md` (current-pages catalog seeded from `PLAN.md`'s doc map + a `## Supersession
   History` section, excluding the manifest page), verify supersession banners are
   bidirectional, quick link sanity check. **Curate touches only corpus-derived pages** (see
   the boundary rule in Phase 4).

Modes: default appends incrementally to `Project Memory`; `--fresh` re-creates the wiki for
a clean rebuild (new wiki ⇒ empty manifest ⇒ full ingest). Scheduling is the user's choice —
the script is a plain idempotent command, so a launchd `StartCalendarInterval` plist, a cron
entry, or a Claude Code routine can run it daily (documented, not built).

## Phase 3 — Corpus manifest + supersession + class-aware prompt

### Manifest (incremental state, stored in the wiki)

State lives **inside the wiki** as a page titled `Ingest Manifest`, body = a fenced
```json``` block mapping `relpath → { blobSha, commitISO, ingestedAt }`. Rationale:
self-contained and portable (travels with the `<ulid>.sqlite`, survives machine moves,
resettable by deleting the page) and needs **no new primitives** — read with `page get
--title "Ingest Manifest"`, write with `page upsert --title "Ingest Manifest" --body-file -`.
Keyed by `git hash-object` blob SHA so both new (absent key) and changed/re-grounded
(differing SHA) files are re-ingested; unchanged files are skipped. The curate pass excludes
it from the index. A manifest entry whose file no longer exists (e.g. `multi-tab-editor.md`,
already removed) is left in place — its page is historical and likely already superseded;
optionally `log append` a note. No destructive removal.

### Supersession convention (unchanged)

When a file supersedes/replaces an earlier one (cross-check the file's own text **and**
`PLAN.md`'s index annotations):

- On the **older** page, prepend:
  `> **Superseded by [[New Page]]** — <date>, per [[New Page]]. Retained for historical context.`
- On the **newer** page, add `**Replaces [[Old Page]]**`.
- Add a row to the index's `## Supersession History` (`Old → New (date, reason)`).

Because design docs are processed oldest→newest, the older page always exists by the time a
superseding plan is ingested, so the back-annotation is just `page get` + edit + `page upsert`.

### Class-aware ingest prompt (`scripts/project-memory-prompt.md`, new)

One prompt with a per-class branch:

- **Design** — write a page (title from the H1, body = synthesized problem/approach/status
  with `[[wikilinks]]`), capture supersession as above. (The original plans-only behavior.)
- **Spine** — `PLAN.md` → seed the index + a Roadmap/Status page; `PROGRESS.md` → milestone /
  feature pages + a `log append` entry per gate; `ISSUES.md` → one known-issue page each.
- **Agreement / Reference** — rule pages (`AGENTS.md`, `SWIFTUI-RULES.md`) and reference pages
  (`README.md`, `docs/hybrid-search.md`, `docs/skills/*`), cross-linked.

All classes write via `wikictl` (`page upsert` / `index set` / `log append`) and log each
ingest: `wikictl log append --kind ingest --title "<file>"`.

## Phase 4 — Makefile targets + the bidirectional loop

### Targets

Two new `.PHONY` targets (matching the existing `run`/`install` style):

- **`make memory-ingest`** — `./scripts/build-project-memory.sh`. The long-running,
  `claude`-driven, daily-safe target (Phase 2).
- **`make run-memory`** — launch the app already showing the Project Memory wiki:
  1. Ensure the wiki exists (create if `wikictl --wiki "Project Memory" page list` fails).
  2. `wikictl wiki use --wiki "Project Memory"` — bump it to MRU.
  3. `make install` — build + copy to `/Applications` + register app + FP extension.
  4. `open "$(INSTALLED_APP)"` — the app bootstraps, registers domains, opens the MRU wiki.

  Depends on `install` (like `run`), with `wiki use` between install and open. Keep
  `memory-ingest` separate so launching is fast. Document both in `help`.

### The bidirectional convention (what makes it *memory*, not a rendering)

- **Recall.** Add a short section to [`AGENTS.md`](../AGENTS.md): before starting work, query
  the Project Memory wiki (`wikictl --wiki "Project Memory" search --query …` / `page get
  --title …`) — augmenting today's "read `PLAN.md` then `PROGRESS.md`" with semantic recall.
- **Record.** After completing work, agents record development memory:
  - **Canonical** changes (a new plan, a `PROGRESS.md` entry) land in **git markdown first** —
    git stays the source of truth — and the next `memory-ingest` folds them into the wiki. No
    divergence.
  - **Wiki-native** memory (a decision "chose X over Y", a cross-cutting gotcha, a concept
    page) is written **directly** via `wikictl page upsert` / `log append`. This is the same
    write path the app's ingest already uses — now exercised by dev agents.
- **The boundary rule (correctness).** The idempotent re-ingest and curate pass operate **only
  on corpus-derived pages** (those with a `relpath` in the manifest). Agent-authored pages have
  no corpus `relpath`, so they fall outside the delta and the curate rebuild and are **never
  clobbered**. This is the property that makes bidirectional safe.

## Out of scope

- **Structured supersession** — a `superseded_by` column at a schema migration, frontmatter
  projection, a `wikictl page supersede` command, and a reader badge would make supersession
  queryable but touches the schema, the File Provider markdown projection
  ([`page-body-contract.md`](page-body-contract.md)), and the reader UI. Stays prose + links +
  index.
- **Git/PR rationale mining** — sources are scoped to the markdown corpus. Mining commit
  messages and PR bodies as a development-rationale stream is a deliberate **future extension**,
  not this pass.
- **Wiki-as-source-of-truth** — git markdown stays canonical for git-belonging content; the
  wiki is the memory / synthesis layer, reconciled by idempotent re-ingest. Adding sources via
  `wikictl` (so corpus files could be first-class sources rather than read from the working
  tree) is likewise out of scope.

## Ripple edits (beyond this doc)

- [`PLAN.md`](../PLAN.md) — update the doc-index row for this renamed doc; reflect the Project
  Memory framing.
- [`AGENTS.md`](../AGENTS.md) — add the recall/record convention section.
- `Makefile` `.PHONY` + `help` — the two new targets.
- New scripts created during execution: `scripts/build-project-memory.sh`,
  `scripts/project-memory-prompt.md`.

## Verification

1. **Unit/build:** `swift build` clean; `swift test` passes incl. the new `wiki create` /
   `wiki use` parse + integration tests.
2. **Helper smoke test:** `ID=$(.build/debug/wikictl wiki create --name "Project Memory-test")`
   prints a ULID; `.build/debug/wikictl --wiki "$ID" page list` succeeds (empty); confirm
   `~/Library/Group Containers/group.org.sockpuppet.wiki/$ID.sqlite` and a new `wikis.json`
   entry exist.
3. **Subset across classes first** (before the full corpus): ingest one design-doc pair
   (`sources-redesign.md`, then `phase-b-source-wikilinks.md`), one spine doc (`PROGRESS.md`),
   one reference doc (`docs/hybrid-search.md`):
   - The sources-redesign page contains a `Superseded by [[…]]` banner; the Phase-B page
     contains `Replaces [[…]]`; the index shows `## Supersession History` with the pair.
   - A `PROGRESS`-derived milestone page and a hybrid-search reference page exist.
4. **Full run**, then spot-check the known clusters (tab system, reader, the search trilogy)
   and at least one page per class.
5. **Incremental / daily behavior:**
   - Re-run with no changes → prints "up to date", **zero** `claude` calls, exit 0.
   - Touch one corpus file, re-run → **only that one** re-ingests (blob-SHA mismatch); the
     manifest page updates; others untouched.
   - `page get --title "Ingest Manifest"` reflects current SHAs.
6. **Recall demo:** `wikictl --wiki "Project Memory" search --query "why is the mount
   read-only"` returns the relevant page; `page get` shows a cited answer.
7. **Record + boundary demo:** write an agent-authored page (`wikictl page upsert --title
   "Decision: X over Y"`); re-run `make memory-ingest` with no corpus change → the decision
   page is **untouched** (not in the manifest, not clobbered by curate). Proves the
   bidirectional boundary rule.
8. **Launch target:** `make run-memory` builds/installs the app, makes Project Memory the MRU,
   and opens it — confirm the app launches **showing the Project Memory wiki** and its pages +
   supersession banners render. `make memory-ingest` runs the pipeline standalone.
