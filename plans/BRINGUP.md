# WikiFS bring-up plan

A 4-phase path from the current skeleton to v0, derived from
[`plans/INITIAL.md`](INITIAL.md). Each phase ends at a state you can
**demonstrate**, not just compile. The 7 milestones in `INITIAL.md` (M0–M6)
map onto these four phases.

> **Phase 0 — App skeleton — ✅ done.** SwiftPM build environment, signing,
> launching SwiftUI window. See `progress/` (2026-06-15) and
> `plans/build-environment.md`. Everything below is remaining work.
>
> **Provisioning (the Apple incantations) — done up front.** Per the user's
> call (2026-06-15), the cert / App Group / File Provider portal setup in
> [`plans/signing.md`](signing.md) is being completed *before* Phase 1 coding,
> to de-risk Phase 2. Steps 1–5 there are self-contained (no app code needed);
> profile-embedding (steps 6–7) lands with the Phase 2 extension.

| Phase | Theme | INITIAL.md milestones | Demo at the end |
| --- | --- | --- | --- |
| **1** | Local wiki | rest of M0 + M1 | A usable standalone Markdown wiki, persisted in SQLite |
| **2** | Filesystem projection | M2 + M3 | `cat "$WIKI/pages/by-title/Home--"*.md` returns live content |
| **3** | Verify & stay fresh | M4 + M5 | The v0 definition-of-done loop: copy path → read → edit → re-read updates |
| **4** | Agent-facing wiki | M6 + post-v0 generated views | An agent runs `find`/`grep` over `$WIKI_ROOT` and reads indexes |

---

## Phase 1 — Local wiki (data + editor)

Make WikiFS a real, usable wiki in its own window. No File Provider yet —
prove the data model and editing loop first, because everything downstream is
a projection of this.

**Covers:** the unfinished part of M0 (SQLite store, page model, create/list/
select) plus all of M1 (sidebar, `TextEditor`, preview, autosave, rename).

### Deliverables
- **SQLite store** behind the `WikiStore` protocol from `INITIAL.md` §3
  (`listPages` / `getPage` / `createPage` / `updatePage` / `deletePage`).
  Schema from §3 (`pages`, plus `attachments`, `page_links` created now even if
  unused). Pragmas: `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout=5000`.
- **Page model** — `WikiPage` / `WikiPageSummary`, `PageID` (use a sortable id
  so `by-created-date` views are cheap later — ULID-style or UUIDv7).
- **Sidebar** — `NavigationSplitView` list of pages, `+ New Page`, selection,
  rename, delete (context menu + `.swipeActions`).
- **Editor + preview** — `TextEditor(text:)` for the body; preview pane renders
  `AttributedString(markdown:)`. Debounced autosave (300–750ms after typing
  stops; immediate on page switch and on app backgrounding — see SWIFTUI-RULES
  §3.5 "read state at the latest possible moment").
- **Empty state** — `ContentUnavailableView` when no page is selected
  (SWIFTUI-RULES §7.1).

### Acceptance (from INITIAL.md M0 + M1)
- Create a page named `Home`, type Markdown, see the preview update.
- Quit and relaunch — the page and its body persist.

### Decisions to make first
- **SQLite access layer.** Wrap the system `SQLite3` C API directly (no
  third-party dep) vs. adopting GRDB.swift. Default: hand-wrapped `SQLite3` to
  stay dependency-free (swiftui-pro: don't add frameworks without asking).
  Confirm before pulling in GRDB.
- **Database location.** Application Support is simplest for a standalone app,
  but Phase 2 needs the App Group container
  (`~/Library/Group Containers/group.org.sockpuppet.wiki/WikiFS.sqlite`; see
  `plans/signing.md` — note the group is `…wiki`, not `…wikifs`).
  **Recommendation:** put the DB at the App Group path *now* so Phase 2 is a
  drop-in — but see the signing caveat in Phase 2 before committing.

### Risks
- Stale-snapshot autosave (SWIFTUI-RULES §3.5) — read the live body at save
  time, don't capture it at view init.
- `@Observable` store + `ForEach` identity — key rows by `PageID`, never by
  instance (SWIFTUI-RULES §3.4).

---

## Phase 2 — Filesystem projection (File Provider)

The differentiator: expose the SQLite wiki as a read-only filesystem tree that
Unix tools can walk. SQLite stays the source of truth; the filesystem is a
generated projection.

**Covers:** M2 (extension target, domain registration, static root + README +
directories) and M3 (SQLite-backed page files under `pages/by-id` and
`pages/by-title`).

### Deliverables
- **File Provider extension target** — a second bundled product
  (`NSFileProviderReplicatedExtension`). `build.sh` grows an `.appex` assembly
  + embed step; `Package.swift` / build wiring gains the extension. Document in
  `plans/build-environment.md`.
- **Read-only `WikiReadStore`** (INITIAL.md §3) shared by app + extension:
  `listFilesystemChildren` / `metadata` / `contents`. Short-lived read
  connections in the extension; writes stay in the main app.
- **Domain registration** on first launch (`com.example.wikifs.default`,
  display name "WikiFS").
- **Stable item identity** (INITIAL.md §6) — virtual ids (`root`, `readme`,
  `pages-by-id`, `page-by-id:<id>`, …); paths are presentation, never identity.
- **Enumerators** for `root`, `pages`, `pages-by-id`, `pages-by-title`
  (paginated). Read-only capabilities — reject create/delete/rename/modify.
- **Content fetching** — static `README.md`; page bytes rendered from SQLite;
  deterministic title→filename escaping with `--<short-id>` suffix
  (INITIAL.md §5 filename rules).

### Acceptance (from INITIAL.md M2 + M3)
```sh
cd "$WIKI_PATH"
ls && cat README.md
find pages
cat "pages/by-title/Home--"*.md   # live SQLite content
```

### Decisions / risks (call these out early — they gate the whole phase)
- **Signing — local-only, so a *free* Apple Development cert is enough.**
  App Groups + File Provider are managed entitlements that macOS validates at
  launch, so **ad-hoc (`-`) signing won't work** here (unlike Phases 0–1).
  But this is the *only* signing escalation needed: **no Developer ID, no
  notarization** — those are distribution-only. Prerequisites:
  1. Install the `Apple Development: Thomas Ptacek (7F2QE7P59D)` cert in the
     login keychain (team `KK7E9G89GW` is already in the `Makefile`).
  2. Create/extend the App ID with **App Groups** + **File Provider**
     capabilities and generate a **development** provisioning profile.
  3. Embed the profile(s) in the app + `.appex` at sign time — wire
     `PROVISION_PROFILE` (already plumbed through `Makefile`/`build.sh`) to copy
     `embedded.provisionprofile` into each bundle.
  Doing this also retroactively enables the App Group DB path from Phase 1, so
  there's no DB migration.
  > Decided 2026-06-15: keep the File Provider design. Exercising the File
  > Provider API is a **core goal of this project** (it's a POC of that API),
  > so the zero-entitlement "plain-folder export" alternative is rejected
  > outright — not a fallback. The free-cert signing cost is accepted as
  > intrinsic to the project.
- **Concurrent SQLite** — WAL mode + short read connections in the extension
  (INITIAL.md §10).
- **File size for metadata** — `getattr` needs sizes; cache page body byte
  length on save (store it, or compute and cache by DB version).

---

## Phase 3 — Verify & stay fresh (the v0 finish line)

Close the loop that `INITIAL.md` §12 calls "the whole point of v0": a user
copies a path, verifies it in Terminal, edits in the app, and sees the change
on disk.

**Covers:** M4 (path button + verification UI) and M5 (change signaling).

### Deliverables
- **Path button(s)** (INITIAL.md §7) — `Copy Unix Path` asks
  `NSFileProviderManager` for the user-visible root URL (never hardcode it),
  copies `url.path`, and displays it. Plus a copyable verification block
  (`cd … && find . && cat pages/by-title/Home--*.md`). Optional `Reveal in
  Finder` / `Open Terminal Here`.
- **Versioning + change signaling** (INITIAL.md §6, §10) — every edit
  increments `pages.version`; `contentVersion = version`,
  `metadataVersion = hash(title, updated_at, version)`. On save, signal the
  changed item / enumerator so the next Terminal read materializes fresh bytes.

### Acceptance (INITIAL.md M4 + M5 + §12 definition of done)
1. Create `Home`, type a body.
2. Click `Copy Unix Path`; in Terminal `cd "$PATH"` and `cat pages/by-title/Home--*.md` → body appears.
3. Edit `Home` in the app, save.
4. `cat` again → updated content appears.

### Risks
- **Read-after-write staleness** — File Provider caches materialized files.
  Mitigate with explicit version bumps + `signalEnumerator`; for the Phase 4
  agent launch, optionally force a sync step first (INITIAL.md §10).
- **Path stability** — always ask the manager for the URL at click time; pass
  it dynamically (never persist a hardcoded path).

---

## Phase 4 — Agent-facing wiki

Make the projection a first-class agent input and launch agents against it.

**Covers:** M6 (agent launch) plus the post-v0 generated views from
INITIAL.md §5 and §8.

### Deliverables
- **Generated index files** (INITIAL.md §5) — `manifest.json`,
  `indexes/pages.jsonl`, `indexes/links.jsonl`; generated on demand and cached
  by DB version. Wiki-link parsing (`[[Page Title]]`) populating `page_links`
  and `links.jsonl` (INITIAL.md §4 v1).
- **Extra views** (INITIAL.md §8, optional) — `pages/by-created-date`,
  `by-updated-date`; `tags.jsonl` / `backlinks.jsonl` / `attachments.jsonl`.
- **Agent launcher** (INITIAL.md §8) — spawn a `Process` with
  `WIKI_ROOT=<file-provider-root>` in its environment; capture stdout/stderr in
  the app. Treat the wiki as read-only input.

### Acceptance (INITIAL.md M6)
- App launches an agent with `WIKI_ROOT` set; the agent runs `find` / `cat` /
  `grep` over the tree and sees Markdown pages + JSONL indexes.

### Risks
- **Boring formats only** (INITIAL.md §8) — Markdown / JSON / JSONL / raw
  attachments; never require the agent to understand app internals.
- **Index freshness** — regenerate/caches keyed on DB version so a stale index
  never ships to an agent.

---

## Sequencing notes

- Phases are strictly ordered: each depends on the prior. Phase 3 is the
  **v0 ship gate** (INITIAL.md §12); Phase 4 is the agent extension on top.
- **Resolve signing before Phase 2** — install the *free* Apple Development
  cert (no Developer ID / notarization needed for local-only) and a dev
  provisioning profile. It unblocks App Groups *and* the File Provider
  extension, and retroactively lets Phase 1's DB live in the shared container
  without a migration.
- Per `SWIFTUI-RULES` §9, every phase ends with a **live run**, not just a
  green `make check`. Record each phase in `progress/`.
- Per `CLAUDE.md`: run `swiftui-pro` before/after each UI chunk,
  `typography-designer` when setting type, `macos-design` for layout. PRs are
  fine; never merge to `main`.
