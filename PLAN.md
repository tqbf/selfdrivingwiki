# WikiFS

**What this is.** A native macOS SwiftUI wiki backed by SQLite, mirrored
read-only onto the filesystem by a **File Provider extension** so the same
content can be browsed by Unix tools and agents (`find`, `cat`, `grep`) under
`~/Library/CloudStorage/WikiFS-WikiFS`. You edit in the app; the mount reflects
every change. It also ingests dropped files (verbatim bytes under `files/`) and
projects a singleton agent system prompt as `CLAUDE.md` + `AGENTS.md` at the
root. Runs locally only — free, local dev signing; no Developer ID / notarization.

**Core goal (non-negotiable).** This is a proof-of-concept of the macOS **File
Provider API**. The extension is essential, not optional — do **not** replace it
with a plain-folder export, even though that would dodge the signing requirement.

**Where to find things.**

- **This file (`PLAN.md`)** — the master index: the doc map below, milestone
  status, and the build quick-reference.
- **`PROGRESS.md`** — the running log, newest first: what was built each step and
  the evidence each gate passed. *To get a future agent up to speed, read
  `PLAN.md` then `PROGRESS.md`.*
- **`plans/`** — the deep design docs (architecture, build, File Provider,
  signing); see the table below for which is which.
- **`ISSUES.md`** — known limitations we've chosen to live with.
- **`SWIFTUI-RULES.md`** / **`CLAUDE.md`** — coding rules and the working
  agreement (docs to keep, skills to use, PR rules).

## Documentation index

| Doc | What it covers |
| --- | --- |
| [`plans/INITIAL.md`](plans/INITIAL.md) | Original full product/architecture plan (milestones, schema, File Provider design, definition of done). Source of truth for *what we're building*. |
| [`plans/llm-wiki.md`](plans/llm-wiki.md) | **Next major effort:** turning WikiFS into a self-maintaining LLM Wiki — **many** wikis (one SQLite DB + one File Provider domain each), with `claude -p` authoring/maintaining each one by writing via a new `wikictl` CLI (read via the mount, write via the CLI). Locked decisions, components, and the Phase 0 → A–D plan. Read before Phase 0. |
| [`plans/BRINGUP.md`](plans/BRINGUP.md) | The 4-phase bring-up plan from skeleton to v0 (groups INITIAL.md's M0–M6). Source of truth for *the order we build in*. |
| [`plans/build-environment.md`](plans/build-environment.md) | How the app is built: SwiftPM + `build.sh` + `Makefile`, signing, icon generation, app-bundle layout. Source of truth for *how we build and run*. |
| [`plans/file-provider.md`](plans/file-provider.md) | File Provider extension build + the 5 hard-won gotchas (entry-point recursion, entitlements⊆profile, user-enable toggle, /Applications, keychain). Proven by the 2026-06-15 spike. Read before Phase 2. |
| [`plans/signing.md`](plans/signing.md) | The Apple cert / App Group / File Provider provisioning checklist (manual portal). Do this before Phase 2. Source of truth for *the Apple incantations*. |
| [`SWIFTUI-RULES.md`](SWIFTUI-RULES.md) | Hard-won SwiftUI/macOS rules. Apply when writing or reviewing any view. |
| [`CLAUDE.md`](CLAUDE.md) | Working agreement (docs, skills to use, PR rules). |
| [`ISSUES.md`](ISSUES.md) | Known limitations we've chosen to live with (with context to revisit), e.g. the ~5s replicated-File-Provider read-after-write window. |

## Status

See `PROGRESS.md` for the running log. Current: **🎉 v0 DONE ✅ — all four
phases gate-passed (M0–M6).** A native macOS SwiftUI wiki, SQLite-backed,
projected read-only onto the filesystem via a File Provider extension, kept
fresh on edit, and traversable by an agent launched with `WIKI_ROOT`. Delivered
across four stacked, **unmerged** branches off a pristine `main`
(`phase-1-local-wiki` → `phase-2-file-provider` → `phase-3-verify-fresh` →
`phase-4-agent-wiki`) — review and merge locally. See `PROGRESS.md` for each
gate's evidence and the known v0 gaps.

**Post-v0 features** (also stacked, unmerged):

- `phase-5-file-ingest` — drag a file in to **ingest** it (raw bytes + metadata
  stored in a new `ingested_files` SQLite table, NOT a wiki page; surfaced
  read-only under `files/by-id` & `files/by-name`; removable "Files" list).
  Verified with a real 8 MB PDF served byte-identical from the mount.
- **System-prompt document** — a user-editable singleton "system prompt" (DB
  `system_prompt` table, v2→3 migration) projected **read-only at the wiki root
  as both `CLAUDE.md` and `AGENTS.md`** (identical bytes). Edited in-app via a
  pinned sidebar item. Code complete + unit-tested (69 tests); **live-mount gate
  pending**. See `PROGRESS.md`.

## Milestones (from `plans/INITIAL.md`)

- **M0 — App skeleton** ✅ build environment + launching SwiftUI window.
- **M1 — Markdown editor** ✅ sidebar page list, `TextEditor`, preview, autosave, SQLite persistence.
- **M2 — File Provider domain** ✅ extension target, domain registration, static root + `README.md`.
- **M3 — SQLite-backed page files** ✅ `pages/by-id`, `pages/by-title`, content from SQLite.
- **M4 — Path button** ✅ `Copy Unix Path`, verification commands in-app.
- **M5 — Change signaling** ✅ edits increment version; Terminal reads see updates (no relaunch).
- **M6 — Agent launch** ✅ spawn agent with `WIKI_ROOT` env pointing at the projection.

## Build quick reference

```sh
make          # debug build → build/WikiFS.app
make run      # build + launch
make check    # compile-only gate (no bundle/sign)
make help     # all targets
```

Full detail: [`plans/build-environment.md`](plans/build-environment.md).
