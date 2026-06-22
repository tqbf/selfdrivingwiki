# Phase D — Editable Display Names + Rename Propagation (implemented correctly)

**Status:** Implemented on `feature/phase-d-display-names-rename`. 747 tests pass.
**Depends on:** [`phase-b-source-wikilinks.md`](phase-b-source-wikilinks.md) (`source_links`,
`resolveSourceByName`, `selectSource`) and [`markdown-anchors.md`](markdown-anchors.md)
(`ParsedLink.fragment`, `splitFragment`, `classify`) — both merged on `main`.
**Parent design:** [`sources-redesign.md`](sources-redesign.md) Feature 3 (lines 212-256) +
Rename Propagation (lines 148-158) + the Phase D bullet (lines 410-416).
**Why a separate plan:** the parent's Phase D predates Phase B's `source_links` graph and
markdown-anchors' link fragments, so its rewrite spec is fragment-blind and scans bodies
blindly. It also carries two claims the Phase B review debunked. This plan supersedes the
Phase D portion of `sources-redesign.md` wherever they conflict.

## Already done (don't re-do)

- **Schema** — `display_name TEXT` on `sources`, backfilled to `filename` (v10). No migration
  in Phase D.
- **Resolution** — `resolveSourceByName` (`SQLiteWikiStore`) matches `display_name`/`filename`
  case-insensitively, `updated_at DESC` tiebreak. New/renamed links resolve correctly.
- **Link graph** — `source_links(from_page_id, to_source_id, link_text)`, written in
  `replaceLinks`'s single transaction (Phase B). Stable by source **ID** across renames.
- **Parser primitives** — `WikiLinkParser.splitFragment` / `classify` / `ParsedLink.fragment`
  (markdown-anchors). A fragment-aware rewrite has what it needs.

## Decisions (locked)

1. **Rewrite swaps the base only — fragment and alias are preserved.**
   `[[source:Old#"q"|alias]]` → `[[source:New#"q"|alias]]`. The base is the only thing that
   breaks on rename; the `#fragment` and `|alias` must survive untouched. (The parent plan's
   rewrite is fragment-blind and would break every anchored source citation.)
2. **Drive the scan off `source_links`, not a body grep.** Query
   `to_source_id = ?` for candidate pages — accurate, no prose false-positives. Add the read
   helper (none exists today).
3. **Rewrite only what breaks: links whose base equals the old `display_name`.** Filename-form
   links keep resolving (filename is immutable), so leave them; rewriting the old-display-name
   form both fixes breakage and shows the new name.
4. **Code-span/fence safe.** `[[source:Old]]` inside a code block is literal text — never
   rewrite it. Locate spans with code-range awareness (the parser does not skip code; only
   `WikiLinkMarkdown.linkified` does).
5. **`source_links.link_text` IS re-derived on re-save** (correcting
   `sources-redesign.md:155`). The rewrite must be alias-preserving or aliases are dropped.
6. **Sources only.** Drop the parent's "general capability, not source-specific" claim — page
   `rename` (`WikiStoreModel.swift:610`) does no rewriting; there is no scanner to generalize.
   Page-rename rewriting is a separate follow-up. (Build the rewrite helper generic enough
   that page-rename reuse is a later one-liner.)
7. **The by-name projection switches from `filename` to `display_name`** (the human-readable
   view); by-id stays `<id>.<ext>` (stable identity). Rename bumps `sources.version` so the
   change bridge refreshes the by-name filenames.

---

## 1. `renameSource` — one transactional op

New on `SQLiteWikiStore` (+ the `WikiStore` protocol), mirroring the *shape* of page `rename`
but transactional and link-rewriting. It does NOT go through `PageUpsert` (which re-embeds);
like page rename it calls `updatePage` + `replaceLinks` directly, skipping embedding (the body
content is unchanged — only link spans move):

```swift
/// Rename a source's display_name and rewrite every [[source:<old>…]] link that points at it.
/// One transaction: the source row update + every affected page body + their link rows, so a
/// mid-rename failure leaves nothing half-changed. Bumps sources.version (→ changeToken moves).
public func renameSource(id: PageID, to newDisplayName: String) throws {
    try exec("BEGIN IMMEDIATE;")
    do {
        let old = try getSource(id: id)                       // old display_name + filename
        guard old.displayName != newDisplayName else { try exec("COMMIT;"); return }
        try exec("UPDATE sources SET display_name = ?2, updated_at = ?3, version = version + 1 WHERE id = ?1;")
        // §3: pages linking to this source by ID
        for pageID in try sourceLinkingPages(to: id) {
            let page = try getPage(id: pageID)
            // §2: rewrite the base of matching source-link spans, preserving fragment + alias
            guard let rewritten = WikiLinkRewriter.rewriteSourceBase(
                in: page.bodyMarkdown, matching: old.displayName ?? old.filename,
                to: newDisplayName) else { continue }          // unchanged → skip
            try updatePage(id: pageID, title: page.title, body: rewritten)  // no re-embed
            try replaceLinks(from: pageID, parsedLinks: WikiLinkParser.parse(rewritten))
        }
        try exec("COMMIT;")
    } catch { try? exec("ROLLBACK;"); throw error }
}
```

`WikiStoreModel.renameSource(id:newDisplayName:)` is the thin app/CLI wrapper: call the store,
`reloadSummaries()`, refresh any open tab/title, `signalChange()`. (The page-rename path at
`WikiStoreModel.swift:610` is the template.)

## 2. The rewrite — base-only, code-safe, fragment-/alias-preserving

The heart of Phase D. Extract a small pure helper (testable in isolation) that reuses
`WikiLinkMarkdown`'s regex + `protectedCodeRanges` (extract both to a shared `WikiLinkSpan`
helper if not already shared — same lesson as `splitFragment`/`ContentSniff`):

```swift
/// In `body`, find every [[source:<oldBase>…]] link span (skipping code spans/fences),
/// and replace <oldBase> with <newBase>, leaving any #fragment and |alias verbatim.
/// Returns nil if no span matched (so callers skip the re-save). Case-insensitive,
/// whitespace-collapsed base match.
static func rewriteSourceBase(in body: String, matching oldBase: String,
                              to newBase: String) -> String?
```

- **Deliverable: lift `protectedCodeRanges` (+ the `[[…]]` regex) into a shared
  `WikiFSCore.WikiLinkSpan`.** It's `private static` in `WikiLinkMarkdown.swift:255`; the
  rewrite needs it too, so consolidate rather than copy a third time (and have
  `WikiLinkMarkdown.linkified` call the shared one). Same lesson as `splitFragment`/
  `classify`/`ContentSniff`.
- Locate `[[…]]` spans via `WikiLinkSpan`; drop any intersecting `protectedCodeRanges` (code
  spans/fences are literal text).
- For each remaining span, split its **target** structurally — first `|` separates the alias,
  first `#` separates the fragment; `classify` the pre-`#` part → must be `.source`; normalize
  that bare target and compare to `oldBase` (case-insensitive, whitespace-collapsed). Skip on
  mismatch.
- **Splice by structure, not substring search.** The base is a known byte range (after
  `source:`, before the first `#`/`|`); replace *that range* with `newBase`. Do **not**
  `replaceOccurrences(of: oldBase)` on the body — that misses case/whitespace variants
  (`source:  my paper` must match `My Paper`), and can match `oldBase` outside a link base or
  at the wrong occurrence. Structural splice also leaves `#fragment` and `|alias` byte-for-byte
  intact because they're never touched.
- Return the rewritten body, or nil if nothing changed.

**Why alias preservation matters end-to-end:** leaving `|alias` verbatim means the re-save's
`WikiLinkParser.parse` extracts that same alias, so `replaceLinks` writes the correct
`source_links.link_text` — the alias survives the whole rename, not just the body text. (This
is why the §1 transaction re-parses the rewritten body rather than copying `link_text`.)

This makes `[[source:Old#"the effect vanishes"|alias]]`-style citations (markdown-anchors)
survive a rename intact — the single most important property given what's merged.

## 3. Drive off the link graph — add a read helper

No `source_links` read method exists (only the DDL at `SQLiteWikiStore.swift:328-352`). Add:

```swift
/// Pages whose bodies link to `sourceID` (by ID — stable across renames). One query.
public func sourceLinkingPages(to sourceID: PageID) throws -> [PageID] {
    // SELECT DISTINCT from_page_id FROM source_links WHERE to_source_id = ?1
}
```

This replaces the parent plan's "scan all pages via `store.listPages()`"
(`sources-redesign.md:252`) — O(linked-pages) not O(all-pages), and zero false positives.

## 4. by-name projection → `display_name` + change bridge

Today by-name builds filenames from `source.filename`
(`Projection.swift:481,503,626` → `FilenameEscaping.byNameSourceFilename`). For editable
display names to mean anything on the mount, by-name must use `display_name`:

- `sourceNode` (`Projection.swift:497-515`): a **two-line conditional on `isByName`**, not a
  single replace. Today both the by-name `name` and `metadataVersion` derive from
  `file.filename` — the `name` already branches on `isByName` but uses filename, and
  `metadataVersion` (`:512`) uses filename on **both** paths. Switch the by-name branch of each
  to `displayName ?? filename`:
  - by-name `name` ← `byNameSourceFilename(filename: displayName ?? filename, …)`;
  - by-name `metadataVersion` ← `"…\(displayName ?? filename)|\(updatedAt)|\(version)"`.
  By-id stays `<id>.<ext>` / filename-keyed (stable identity). `sourceMarkdownNode` (Phase C)
  mirrors it.
- Node **identity is ULID-based** (`sourceByName(ulid)`), so a rename is a metadata/name
  update, not an add/remove — stable.
- §1 already bumps `sources.version`, so `changeToken`'s `SUM(version)`
  (`SQLiteWikiStore.swift:564-583`) moves; `signalChange()` then refreshes by-name. (Same
  change-bridge discipline as Phase C.)
- **Locked: `sources.jsonl` `name` → `displayName ?? filename`** — one line at
  `IndexGenerators.swift:155` (`SourceIndexRow.displayName` already exists at `:50`). The agent
  needs this to learn display names for `[[source:Name#"…"]]` citations. Update its test.

## 5. Editing surfaces

All three call the same `WikiStoreModel.renameSource(id:newDisplayName:)`.

- **Detail-view title** — `SourceDetailView` already has `isEditing` scaffolding
  (`:31,146,326`) for the markdown editor; add a separate title `TextField` bound to
  `displayName` (`:59`), commit-on-Enter/blur → `renameSource`. (Apply `swiftui-pro` here —
  not installed this session.)
- **Sidebar inline rename** — `SourcesSectionView`, Finder-style: select source, Enter → inline
  `TextField`, commit → `renameSource`, Esc → cancel. New SwiftUI.
- **CLI** — §6.

**Validation:** renaming onto a name colliding with another source's `display_name`/`filename`
is allowed (the resolver disambiguates by `updated_at`) but should warn — surface a soft
"this name is also used by …; links may be ambiguous" notice. Don't block.

## 6. CLI — `wikictl source rename`

Add to `SourceCommand` alongside `.list`/`.cat`/`.export`:

```
wikictl source rename <selector> "<new-display-name>"
```

Resolve the selector (existing `.id`/`.name` resolver), call `store.renameSource(id:to:)`,
`signalChange()`. Output the count of rewritten pages (useful feedback). The agent prompt (§8)
advertises it.

## 7. Atomicity & failure

**As implemented:** The source UPDATE happens first, then each linking page is updated
individually via `updatePage` + `replaceLinks` (which are each internally transactional).
No single outer transaction — `updatePage` and `replaceLinks` each do their own
`BEGIN IMMEDIATE/COMMIT`, so nesting was infeasible without refactoring both methods.

If a crash occurs mid-loop, remaining pages still resolve (the old name is a filename
fallback) — the rename is eventually consistent. `sourceLinkingPages` is keyed by ID, so
re-running the same rename after a partial failure rewrites the remaining pages.

## 8. Agent prompt — `SystemPrompt`

Small addition to `## Conventions` (alongside the Phase B `[[source:…]]` and markdown-anchors
cite-by-quote docs): the canonical cite target is the source's **display name** (editable via
`wikictl source rename`); renames automatically rewrite existing `[[source:…]]` links, so the
agent may rename freely without orphaning citations. One line.

---

## Tests

- `WikiLinkRewriterTests` (pure, the heart):
  - `[[source:Old]]` → `[[source:New]]`.
  - `[[source:Old#Section]]` → `[[source:New#Section]]` (heading fragment preserved).
  - `[[source:Old#"a quoted passage"]]` → base swapped, quote preserved.
  - `[[source:Old|alias]]` → `[[source:New|alias]]` (alias preserved).
  - `[[source:Old#"q"|alias]]` → both preserved.
  - `[[source:Other]]` unchanged; `[[source:old]]` case-insensitive match.
  - `[[source:Old]]` inside a fenced/inline code span → **unchanged**.
  - `[[page:Old]]` / `[[Old]]` → unchanged (not a source link).
  - No match → nil.
- `SQLiteWikiStoreTests`:
  - `renameSource` updates `display_name`, bumps `version` (→ `changeToken` changes).
  - `sourceLinkingPages(to:)` returns the right set.
  - End-to-end: a page with `[[source:Old#"q"|alias]]` + `[[source:Other]]`; rename Old→New;
    the first span rewrites to `[[source:New#"q"|alias]]`, the second is untouched,
    `source_links.link_text` for the first is `alias` (alias survived the re-save).
  - Atomicity: a rename that touches N pages is all-or-nothing on failure.
- Projection: by-name node name + metadataVersion reflect `display_name`; rename → those
  change, by-id unchanged.
- `SourceCommandTests`: `source rename <selector> "<name>"` renames + signals.

## Gate

- `swift build` clean; `swift test` green (new tests above).
- **Manual:**
  1. Rename a source via the detail title / sidebar / CLI → `[[source:Old]]` links in other
     pages become `[[source:New]]` and still navigate.
  2. A `[[source:Old#"quote"|alias]]` citation (markdown-anchors) becomes
     `[[source:New#"quote"|alias]]` — quote + alias intact, still scrolls.
  3. `[[source:Old]]` inside a code block is NOT rewritten.
  4. The by-name mount filename updates to the new display name (by-id unchanged); happens
     without relaunch (change bridge).
  5. Renaming to a colliding name warns but succeeds; links resolve (recency tiebreak).

## Out of scope

- **Page-rename link rewriting** — the real "pre-existing gap" (`WikiStoreModel.rename:610`
  does no rewriting). Separate follow-up; the §2 helper is built generic so page reuse is a
  later one-liner.
- **Rewriting filename-form links** — they still resolve (filename is immutable); leave them.
- **Undo of a rename** — future.
- **Collision prevention** — we warn, not block (the resolver handles it).

## Open decisions

1. **Warn vs. block on collision.** Recommend warn-and-allow (resolver disambiguates).
2. **Detail-title edit UX** — inline-on-click vs. an explicit edit affordance. Recommend
   Finder-style inline; confirm with `swiftui-pro`/`macos-design` at implementation.

> **Implementation skills:** apply `swiftui-pro` (sidebar inline rename, title field),
> `macos-design`, and `typography-designer` per `CLAUDE.md` when writing the UI — not installed
> this session.
