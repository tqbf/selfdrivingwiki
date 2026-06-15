# WikiFS

A native macOS SwiftUI wiki with a SQLite backend and a File Provider–backed
filesystem projection, so the wiki can be inspected by Unix tools and agents
(`find`, `cat`, `grep`) from Terminal.

**Core goal:** this project is also a proof-of-concept of the macOS **File
Provider API**. The File Provider extension is essential, not optional — it is
*not* to be replaced with a plain-folder export, even though that would avoid
the (free, local-only) signing requirement. App runs locally only; no
Developer ID / notarization is needed.

This file is the **master index**. Deep docs live in `plans/`. Day-to-day
progress lives in `PROGRESS.md`. To get a future agent up to speed:
**read `PLAN.md` and `PROGRESS.md`.**

## Documentation index

| Doc | What it covers |
| --- | --- |
| [`plans/INITIAL.md`](plans/INITIAL.md) | Original full product/architecture plan (milestones, schema, File Provider design, definition of done). Source of truth for *what we're building*. |
| [`plans/BRINGUP.md`](plans/BRINGUP.md) | The 4-phase bring-up plan from skeleton to v0 (groups INITIAL.md's M0–M6). Source of truth for *the order we build in*. |
| [`plans/build-environment.md`](plans/build-environment.md) | How the app is built: SwiftPM + `build.sh` + `Makefile`, signing, icon generation, app-bundle layout. Source of truth for *how we build and run*. |
| [`plans/file-provider.md`](plans/file-provider.md) | File Provider extension build + the 5 hard-won gotchas (entry-point recursion, entitlements⊆profile, user-enable toggle, /Applications, keychain). Proven by the 2026-06-15 spike. Read before Phase 2. |
| [`plans/signing.md`](plans/signing.md) | The Apple cert / App Group / File Provider provisioning checklist (manual portal). Do this before Phase 2. Source of truth for *the Apple incantations*. |
| [`SWIFTUI-RULES.md`](SWIFTUI-RULES.md) | Hard-won SwiftUI/macOS rules. Apply when writing or reviewing any view. |
| [`CLAUDE.md`](CLAUDE.md) | Working agreement (docs, skills to use, PR rules). |

## Status

See `PROGRESS.md` for the running log. Current: **Phase 1 (M0+M1) — DONE ✅.**
A usable standalone SQLite-backed Markdown wiki — sidebar, editor, live preview,
debounced autosave, persistence — verified on the running app and at the SQLite
layer. On branch `phase-1-local-wiki` (unmerged; the pipeline stacks each phase
branch and keeps `main` pristine). **Next: Phase 2 — File Provider projection.**

## Milestones (from `plans/INITIAL.md`)

- **M0 — App skeleton** ✅ build environment + launching SwiftUI window.
- **M1 — Markdown editor** ✅ sidebar page list, `TextEditor`, preview, autosave, SQLite persistence.
- **M2 — File Provider domain** extension target, domain registration, static root + `README.md`.
- **M3 — SQLite-backed page files** `pages/by-id`, `pages/by-title`, content from SQLite.
- **M4 — Path button** `Copy Unix Path`, verification commands in-app.
- **M5 — Change signaling** edits increment version; Terminal reads see updates.
- **M6 — Agent launch** spawn agent with `WIKI_ROOT` env pointing at the projection.

## Build quick reference

```sh
make          # debug build → build/WikiFS.app
make run      # build + launch
make check    # compile-only gate (no bundle/sign)
make help     # all targets
```

Full detail: [`plans/build-environment.md`](plans/build-environment.md).
