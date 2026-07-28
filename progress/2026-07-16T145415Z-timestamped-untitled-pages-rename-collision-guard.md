---
timestamp: 2026-07-16T145415Z
title: "2026-07-16 — Timestamped untitled pages + rename collision guard"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-16 — Timestamped untitled pages + rename collision guard

## Progress


**Implemented (branch `torpid-penguin`).** Two related changes to page-title
behavior:

1. **Timestamped default title.** Creating a new page with no explicit title
   (`model.newPage()` / `model.newPageInNewTab()`) now produces
   `"Untitled 2026-07-16 14:30:45"` instead of bare `"Untitled"`. This makes
   multiple new pages instantly distinguishable in the sidebar and avoids
   title collisions (which would otherwise silently duplicate-title, with
   wiki-links resolving to whichever page has the lowest ULID).
   - `WikiStoreModel.defaultUntitledTitle()` — a `public static` that formats
     `Date()` via a private `DateFormatter` (`"yyyy-MM-dd HH:mm:ss"`).
   - Default parameters on `newPage` and `newPageInNewTab` use it (can't use
     `Self.` — Swift forbids covariant `Self` in default args; explicit
     `WikiStoreModel.defaultUntitledTitle()` works).
   - Callers that pass explicit titles (Home page seeding, `wikictl`, tests)
     are unaffected.

2. **Rename collision guard.** `WikiStoreModel.rename(_:to:)` now checks
   whether another page already has the target title (case-insensitive,
   matching `resolveTitleToID` / wiki-link resolution) BEFORE writing. If a
   collision exists, the rename is blocked — the title stays unchanged, and
   `renameConflictingTitle` is set so views can show an alert.
   - `renameConflictingTitle: String?` — observable on the model; UI shows
     "Title Already Exists" alert in `PageDetailView` and `PagesContainerView`.
   - `clearRenameConflict()` — dismisses the alert state.
   - The check skips the page being renamed itself (`existingID != id`), so
     re-saving the same title is a no-op (not a false collision).
   - `WikiNameRules.sanitized` is applied before the collision check and before
     the write, so e.g. `A|B` is stored as `A-B` and compared consistently.

**Tests** (`Tests/WikiFSTests/PageTitleCollisionTests.swift`, 9 tests):
- `defaultUntitledTitleIncludesTimestamp` / `ChangesOverTime` — the formatter
  produces a parseable timestamp that differs across seconds.
- `newPageWithoutExplicitTitleGetsTimestamp` / `InNewTab` — end-to-end store
  round-trip gets a timestamped title.
- `renameToExistingTitleIsBlocked` / `CaseInsensitiveIsBlocked` — the rename
  doesn't change the title and surfaces the conflict.
- `renameToOwnTitleIsAllowed` — no false positive when renaming to the same
  title.
- `renameToUniqueTitleSucceeds` — normal renames still work.
- `clearRenameConflictResets` — the alert state is dismissible.

**Gates:** `swift build` clean; 9 new tests + 69 existing
(Navigation/EditableTitle/WikiNameRules/EditorTab) all pass.

## Verification

Historical verification remains in the progress record above.
