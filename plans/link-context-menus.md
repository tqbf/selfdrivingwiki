# Link context menus (design / future PR)

> **Status: design only.** This is a written problem statement + decision for a
> follow-on PR. No context-menu code ships in the PR that created this document
> (that PR only made unresolved wiki-links render red — see `PROGRESS.md`).
> Read this before implementing link context menus.

## Feature

Right-click **any** link (wiki **or** external) in a markdown preview for a
context menu:

- **Missing wiki link** (`wiki://missing?title=…`) → **Suggest…** → a sheet
  listing closest matches, from `WikiStore.searchSimilar(query:limit:)`
  (semantic search via sqlite-vec + Apple NLEmbedding, with a `LIKE` fallback).
- **Any wiki link** → **Find Similar…** → closest matches to the linked target,
  whether or not the link resolves (i.e. you can explore "pages like this one"
  even from a working link).
- **Copy** submenu:
  - **Copy as Wiki Link** — `[[Target]]` / `[[source:Name]]`, alias and `#fragment`
    preserved (reuse `WikiLinkMarkdown` target/fragment parsing).
  - **Copy File Path** — the File-Provider mount path: root
    `~/Library/CloudStorage/Self Driving Wiki-<name>`
    (`WikiDescriptor.displayName`, `FileProviderSpike.swift`) +
    `pages/by-title/<escaped>--<id8>.md` for pages
    (`FilenameEscaping.pageByTitleFilename`, `PageDetailView.swift:128`) or
    `sources/by-id/<id>.<ext>` for sources (`FilenameEscaping.sourceByFilename`).
    The existing "Copy Unix Path" lives in `VerificationPopover` (M4) — reuse its
    mount-root resolution.
- **External link** (`https`/`mailto`/…) → **Open in Browser** (`NSWorkspace.open`)
  and **Edit Link** (scope TBD: default = open the page editor and select the
  `[[…]]`/URL source so the user fixes it by hand; a fuller inline rewrite of
  just the link target is a possible later step using `WikiLinkRewriter`).

The logic layer already exists and is trivial to drive: `WikiStore.searchSimilar`,
`resolveTitleToID`, `resolveSourceByName`, and `WikiLinkMarkdown`'s
target/fragment helpers. **Only the interaction layer is blocked.**

## Right-click selects the whole link (requirement)

Today a right-click lands as a *word* selection, not a link selection, so the
menu acts on a fragment of the link text. Concretely, in the vendored Textual
`NSTextInteractionView` (`…/AppKit/NSTextInteractionView.swift`):

- `rightMouseDown(with:)` → `updateSelectionForContextMenu(at:)`, which sets
  `model.selectedRange = model.wordRange(for: position)` — the **word** under the
  cursor — whenever the click isn't already inside an existing selection.
- `makeContextMenu()` then offers only **Share / Copy** of that selected word;
  it has no concept of a link.

**Example.** For `[[Modern Debugging (study)|Spinellis's "Modern Debugging"]]`
the rendered link text is `Spinellis's "Modern Debugging"`. Right-clicking on
`Modern` inside it selects only the word **`Modern`** (and offers Share/Copy of
that fragment), not the whole link. The same happens for external URLs: a click
on `github` in `https://github.com/…` selects just `github`.

**Required behavior.** Right-clicking **any** link (wiki **or** external) must:

1. Select the **entire link run** — the whole visible URL for external links,
   and the whole alias/display text (`Spinellis's "Modern Debugging"`) for wiki
   links — not the word, so Copy/Share act on the full link and the visible
   selection matches the menu's target.
2. Show the **link-specific context menu** (the link-context-menu builder
   below), not the generic Share/Copy-of-a-word menu.

**Seam.** The model already hit-tests to the link via `url(for point:)`
(`TextLayoutCollection+Geometry.swift:5`), but it returns only the URL — it
discards the run's range. "Select the whole link" therefore needs a small new
helper (e.g. `linkRange(for position:)` on `TextSelectionModel`) that expands to
the contiguous run slices sharing the clicked run's URL; then
`updateSelectionForContextMenu` selects that range for link clicks and falls
back to today's `wordRange(for:)` for plain text. This is a third localized
edit on `NSTextInteractionView` inside the same vendored patch approved below.

## The blocker (why this is its own PR)

Textual owns right-click and the context menu **internally**. From the vendored
checkout at `.build/checkouts/textual/`:

- `NSTextInteractionView` (`Sources/Textual/Internal/TextInteraction/AppKit/NSTextInteractionView.swift`,
  internal, `final class`) overrides `rightMouseDown(with:)` and `menu(for:)`.
  Its `makeContextMenu()` is hardcoded to **Share / Copy** and only when there is
  a text selection — it has **no concept of links**.
- The exact seam we need — hit-testing the URL at the click point — is
  `model.url(for: location)` on the internal `TextSelectionModel`
  (`mouseDown` already uses it for left-click link activation). That model and
  the overlay (`AppKitTextInteractionOverlay`, also internal) are not public.
- There is **no public Textual API** to customize the context menu or read the
  link under the cursor. SwiftUI `.contextMenu` cannot do per-link menus: it
  gives no hit-test/location and no way to know *which* link was clicked.

So a per-link menu that keys off the right-clicked URL is impossible without
touching Textual internals. A custom transparent `NSViewRepresentable` overlay
was considered and rejected: it would have to reconstruct link geometry across
headings / lists / code blocks / wrapping without access to Textual's laid-out
text — unreliable hit-testing — and it re-introduces the exact
`NSViewRepresentable`-overlay-menu pattern that caused "severe bugs" in the tab
system (see `plans/tab-context-menu-rebuild.md`, and the `2026-06-19` entry in
`PROGRESS.md`).

## Approved decision: vendor Textual in-repo

Approved by the operator. The follow-on PR will:

1. Copy the Textual checkout into the repo as a local SPM path dependency
   (`Packages/Textual/`); point `Package.swift` at
   `.package(path: "Packages/Textual")`; pin the version currently in
   `Package.resolved`.
2. Make three small, localized edits:
   - Add a public `@Entry` environment value holding a **link-context-menu
     builder** closure `(URL) -> [LinkMenuItem]` (public `LinkMenuItem { title;
     @MainActor () -> Void }`, plus optional submenu / disabled).
   - Add `linkRange(for position:)` on `TextSelectionModel` (+ the layout
     helper) that returns the contiguous run-slice range sharing the clicked
     run's URL. `updateSelectionForContextMenu` selects it when the click is on
     a link (the **whole link**, per the requirement above) and keeps
     `wordRange(for:)` for plain text — so right-clicking
     `Spinellis's "Modern Debugging"` selects the whole link, not `Modern`.
   - In `NSTextInteractionView`: on right-click, call `model.url(for: location)`;
     if a URL is present, select the whole link run, then if a builder is set,
     build link items (then a separator, then the existing Share/Copy items when
     there is a text selection); otherwise the current menu. Pass the env value
     through `AppKitTextInteractionOverlay` (which already threads `openURL` the
     same way).

**Rationale.** Reliable hit-testing (reuses Textual's own laid-out link
geometry); clean per-link menus for both wiki and external links from one seam;
avoids the buggy overlay pattern. The red-links change (already shipped) keeps
`.link` on missing runs, so missing links are already hit-testable with **no**
styling rework needed for the context menu.

**Risks.** Carrying ~120 Textual source files and maintaining the patch on
Textual updates. Mitigate by keeping the edit tiny and isolated to
`NSTextInteractionView` + the overlay pass-through, documenting the fork here
and in `ISSUES.md`, and re-syncing deliberately.

## Open scope questions for that PR

- **"Edit Link"** behavior for wiki links (jump-to-editor-and-select vs.
  structural rewrite of the `[[…]]` target). Decide during implementation.
- Whether **Suggest…** should auto-open an editor for the chosen match, or just
  navigate to it / insert the corrected `[[…]]`.
