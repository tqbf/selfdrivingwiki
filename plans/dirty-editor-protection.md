# Dirty-editor protection and edit-mode persistence

**Status:** Implemented on `feature/dirty-editor-protection`.
**Depends on:** [`tab-context-menu-rebuild.md`](tab-context-menu-rebuild.md) (provides `EditorTab`, `activeTabID`, and the tab-ops API this feature extends).

## Goal

Three related gaps in the in-app editor experience:

1. **Outline button missing in edit mode.** `PageDetailView` and `SourceDetailView`
   both have an "Toggle Outline" (`sidebar.right`) button, but only in their
   read-mode toolbar. Switching to edit mode hid the button even though the
   outline panel itself was still visible.

2. **Edit mode lost on tab switch.** Clicking away to another tab while editing
   a page or source reset `isEditing = false`. Returning to the original tab
   showed the page in read mode — the user had to click Edit again even though
   their changes had been auto-saved.

3. **No warning on close-while-editing.** Clicking the × on a tab (or pressing
   ⌘W) while in edit mode silently exited editing. For source tabs the edit
   buffer might not have flushed in time.

## Changes

### Outline button in edit mode

Added the `sidebar.right` button to the `isEditing` toolbar branch in both
`PageDetailView` and `SourceDetailView`, after the Cancel button. The button
reads the shared `@AppStorage("isOutlineExpanded")` key, so the panel's
visible/hidden state persists across mode switches and tab switches.

### Per-tab edit-mode persistence (`EditorTab.isEditing`)

Added `public var isEditing: Bool = false` to `EditorTab` so the editing state
travels with the tab rather than living only in view `@State`.

**`WikiStoreModel`** gained `setTabEditing(tabID:isEditing:)` — the view calls
this whenever its local `isEditing` changes, persisting the value to the tab.

**`PageDetailView`**:
- Added `@State private var lastKnownActiveTabID: UUID? = nil`. This tracks the
  tab ID *as of the previous update cycle*, used to distinguish a **tab switch**
  (both `activeTabID` and `selection` change) from **in-tab navigation** (only
  `selection` changes, e.g. clicking a `[[wiki-link]]`).
- `onChange(of: store.selection)` now only resets `isEditing` when
  `store.activeTabID == lastKnownActiveTabID` — i.e. only for in-tab navigation.
  During a tab switch `activeTabID` has already changed, so the guard is false
  and the reset is skipped.
- `onChange(of: store.activeTabID)` updates `lastKnownActiveTabID` and restores
  `isEditing` from the new tab's `EditorTab.isEditing` flag.
- `onChange(of: isEditing)` calls `store.setTabEditing` to persist every
  enter/exit-edit-mode event back to the tab. Because SwiftUI batches state
  changes, this fires in the *next* update cycle — by then `store.activeTabID`
  already points to the *new* active tab, so a tab-switch-induced `isEditing =
  false` writes to the new tab (no-op, it was already false) rather than
  accidentally clearing the old tab's persisted `true` state.

**`SourceDetailView`** applies the same pattern plus a deferred-restore path:
when switching to a source tab that was in edit mode, `headVersion` may be `nil`
(reset by `onChange(of: file.id)`). A `shouldRestoreEditing` flag defers the
`editBuffer` repopulation and `isEditing = true` until `onChange(of: headVersion)`
fires once the async `.task(id: file.id)` load completes.

### Close-tab confirmation (`pendingCloseTabID`)

`WikiStoreModel.closeTab(id:)` now checks `tabs[index].isEditing && id ==
activeTabID`. When both are true the close is deferred: `pendingCloseTabID` is
set and the method returns early. Two new public methods apply or cancel it:

```swift
public func confirmCloseTab()   // removes the tab, calls setActiveTab(neighbor)
public func cancelCloseTab()    // clears pendingCloseTabID
```

`confirmCloseTab()` does not need to flush page drafts explicitly — the
`setActiveTab(neighbor)` call inside `applyCloseTab` already calls
`flushPendingSave()`, which saves any `isDraftDirty` content.

**Two separate alerts, one per content type:**

- **`ContentView`** — watches `store.pendingCloseTabID` and shows a "Close
  Tab? / Keep Editing" alert for non-source tabs (pages, Ask, Instructions, etc.)
  where page drafts are guaranteed saved by `flushPendingSave`.

- **`SourceDetailView`** — shows its own alert for source tabs and calls
  `flushEditIfDirty()` *before* `store.confirmCloseTab()`. This ordering is
  critical: by the time `confirmCloseTab()` changes `selection`, `file.id`
  inside `flushEditIfDirty()` is still the source being closed, not the incoming
  neighbor's file. Both alerts are driven by `@State private var showCloseTabAlert`
  updated via `onChange(of: store.pendingCloseTabID)` to avoid complex
  `Binding` closures that exceed the Swift type-checker's expression limit.

## What is NOT guarded

- **`closeOtherTabs` / `closeTabsAfter`** — these never close the active tab
  (the anchor tab remains focused), and only the active tab can hold `isEditing
  = true` at any given moment.
- **Non-active tabs with stale `isEditing = true`** — a tab's editing state is
  saved when the user leaves it, but the edits themselves were already flushed
  by `setActiveTab`'s `flushPendingSave` call at switch time. No data is at risk;
  the flag is cosmetic for restoration purposes.
