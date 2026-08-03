# Dirty-editor protection and edit-mode persistence

**Status:** Implemented on `feature/dirty-editor-protection`.
**Depends on:** [`tab-context-menu-rebuild.md`](tab-context-menu-rebuild.md) (provides `EditorTab`, `activeTabID`, and the tab-ops API this feature extends).

## Goal

Four related gaps in the in-app editor experience:

1. **Outline button missing in edit mode.** `PageDetailView` and `SourceDetailView`
   both have a "Toggle Outline" (`sidebar.right`) button, but only in their
   read-mode toolbar. Switching to edit mode hid the button even though the
   outline panel itself was still visible.

2. **Edit mode lost on tab switch.** Clicking away to another tab while editing
   a page or source reset `isEditing = false`. Returning to the original tab
   showed the page in read mode.

3. **Page edits auto-saved on tab switch.** Switching away from an editing tab
   flushed the page draft to the database immediately, even before the user
   clicked "Save Changes." The user wants explicit save control.

4. **No warning on close-while-editing.** Clicking × (or pressing ⌘W) on any
   tab — focused or unfocused — while that tab was in edit mode silently
   discarded the editing session.

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
  enter/exit-edit-mode event back to the tab.

**`SourceDetailView`** applies the same pattern plus a deferred-restore path:
when switching to a source tab that was in edit mode, `headVersion` may be `nil`
(reset by `onChange(of: file.id)`). A `shouldRestoreEditing` flag defers the
`editBuffer` repopulation and `isEditing = true` until `onChange(of: headVersion)`
fires once the async `.task(id: file.id)` load completes.

### Explicit-save-only for pages (`EditorTab.pendingDraftTitle/Body`)

`WikiStoreModel` previously called `flushPendingSaves()` inside `setActiveTab`,
committing page edits to the database on every tab switch. The user's model is
"Save Changes button = save; switching tabs = don't save."

**New stash mechanism:**
- `setActiveTab` now stashes the outgoing `draftTitle`/`draftBody` into
  `EditorTab.pendingDraftTitle`/`pendingDraftBody` instead of flushing to DB.
- `loadDrafts(for:)` restores from the stash when switching back to a tab that
  has unsaved content (`pendingDraftTitle != nil`).
- `bodyChanged()` and `titleChanged()` no longer call `scheduleAutosave()` —
  the 500ms debounced autosave is removed. Only the explicit "Save Changes"
  button (⌘S) commits to the database.
- `flushPendingSave()` clears the stash after writing to DB.
- **Cancel** now calls `discardPendingDraft(tabID:)`, which clears the stash and
  reloads from DB — so Cancel actually reverts to the last saved state.

### Close-tab confirmation (`pendingCloseTabID`)

`WikiStoreModel.closeTab(id:)` checks `tabs[index].isEditing` for any tab
(focused or not). When true, the close is deferred: `pendingCloseTabID` is
set and the method returns early. Two public methods apply or cancel it:

```swift
public func confirmCloseTab()   // discards stash, removes tab, activates neighbor
public func cancelCloseTab()    // clears pendingCloseTabID
```

`confirmCloseTab()` clears `pendingDraftTitle/Body` (discard) and calls
`applyCloseTab`. No save is performed — the user chose "Close & Discard."

**Single alert in `ContentView`** covers all tab types. Source tabs no longer
have their own alert; since close = discard, there is nothing to flush.

## What is NOT guarded

- **`closeOtherTabs` / `closeTabsAfter`** — these close only non-active tabs
  silently. Only `closeTab` checks `isEditing`.
- **In-tab navigation while editing** (clicking a `[[wiki-link]]`) — the
  `handleSelectionChange` path still calls `flushPendingSaves()`, so navigating
  within a tab continues to save to DB. This is a separate, out-of-scope concern.
