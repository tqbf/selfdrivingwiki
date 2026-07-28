---
timestamp: 2026-07-20T154347Z
title: "2026-07-20 — Global keyboard shortcuts for the five \"Add\" actions (branch `add-keybindings`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-20 — Global keyboard shortcuts for the five "Add" actions (branch `add-keybindings`)

## Progress


**Problem.** The five "Add" actions (Page, URL, File, Folder, Chat) were only
reachable from their on-screen buttons — sidebar headers and the welcome /
empty-state screen. There was no global keyboard path, so adding things required
leaving the keyboard. Plan: [`plans/add-keybindings.md`](plans/add-keybindings.md).

**Fix.** Extended the existing `ContentView.keyboardShortcutButtons` hidden-button
group (`Sources/WikiFS/Window/ContentView.swift:348`) — the app's established
idiom for global shortcuts tied to the active wiki's model (already powers
Cmd-W, Cmd-Shift-T, Cmd-L, Cmd-1…9). Five new invisible buttons each invoke the
*same handler* as the on-screen button — no duplicated logic:

| Action | Shortcut | Handler (unchanged) |
|---|---|---|
| Add Page | ⌘⇧P | `store.newPageInNewTab()` |
| Add URL | ⌘⇧U | `pendingAddURL = PendingAddURL(url: "")` (presents `AddFromURLSheet`) |
| Add File | ⌘⇧F | `WikiFilePanels.chooseFile` → `Task { await store.addFiles([url]) }` |
| Add Folder | ⌘⇧D | `showingImportMarkdown = true` (presents `ImportMarkdownSheet`) |
| Add Chat | ⌘⇧C | `store.openTab(.newChat)` |

Every button is `.opacity(0).allowsHitTesting(false)` so it's invisible and
non-interactive — same as the existing entries. The shortcuts live on
`ContentView` (in `.background { keyboardShortcutButtons }`), which is always
mounted for the active wiki window, so they fire regardless of which descendant
view (sidebar, editor, chat composer, address bar, welcome state) has focus.
They are scoped to the wiki `ContentView`'s responder chain by construction, so
they do **not** fire when Settings (or any non-wiki window) is key.

**Why ⌘⇧?** The ⌘⇧ family is already established in-app for "new/special"
actions (⇧⌘T reopen tab, ⇧⌘[/⇧⌘] cycle tabs). Each binding is mnemonic
(first letter of the noun) and verified unclaimed against the app's full
`.keyboardShortcut` surface and macOS conventions. ⌘N was deliberately
suppressed (issue #396) and is **not** reclaimed. See `plans/add-keybindings.md`
§4 for the full collision audit.

**Why not `@FocusedValue` / menu commands?** The handlers are already reachable
from `ContentView`'s scope (it owns `store` and the sheet `@State`), so
`@FocusedValue` would add complexity for zero benefit. A `CommandGroup`
(File ▸ New ▸ …) is a reasonable future discoverability nicety but would need
the `sessionManager.frontmostSession?.store` indirection — deferred unless
explicitly wanted; the shortcuts themselves work globally without it.

**Evidence.** `make build` ✓ (signed `build/Self Driving Wiki.app`).
`make test` ✓ — all 3167 tests in 266 suites passed. The shortcut wiring is
pure UI glue that reuses existing handlers verbatim, so it inherits the model
methods' existing test coverage (no new unit tests introduced; keyboard
shortcuts are not unit-testable without UI tests). Live validation matrix
(§7 of the plan) — firing each shortcut from sidebar / page editor / chat
composer / address bar / welcome / settings — to be confirmed manually on
launch.

---

## Verification

Historical verification remains in the progress record above.
