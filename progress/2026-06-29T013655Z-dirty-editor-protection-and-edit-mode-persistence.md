---
timestamp: 2026-06-29T013655Z
title: "2026-06-28 — Dirty-editor protection and edit-mode persistence"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-28 — Dirty-editor protection and edit-mode persistence

## Progress


Three editor-UX gaps closed. See [`plans/dirty-editor-protection.md`](plans/dirty-editor-protection.md) for the design.

**Outline button in edit mode.** Added the `sidebar.right` toggle to the
edit-mode toolbar in both `PageDetailView` and `SourceDetailView` (it existed
only in read mode before). State is shared via `@AppStorage("isOutlineExpanded")`
so the panel's visible/hidden position persists across mode switches.

**Per-tab edit-mode persistence.** `EditorTab` gained `isEditing: Bool`.
`WikiStoreModel.setTabEditing(tabID:isEditing:)` persists the flag from the
view. `PageDetailView` and `SourceDetailView` sync on every enter/exit-edit event
and restore the flag when `store.activeTabID` changes. A `lastKnownActiveTabID`
sentinel distinguishes tab switches (restore from tab flag) from in-tab
navigation (reset to false). `SourceDetailView` adds a `shouldRestoreEditing`
flag that defers the `editBuffer` repopulation until `headVersion` loads.

**Close-tab confirmation.** `WikiStoreModel.closeTab(id:)` now defers when
`tabs[index].isEditing && id == activeTabID`, setting `pendingCloseTabID`.
`confirmCloseTab()` / `cancelCloseTab()` apply or abandon the deferred close.
`ContentView` shows "Close Tab?" for page/other tabs (page drafts are saved
automatically by `flushPendingSave` inside `setActiveTab`). `SourceDetailView`
shows its own alert and calls `flushEditIfDirty()` before `confirmCloseTab()` so
the save runs while `file.id` still refers to the closing tab's source.

## Verification

Historical verification remains in the progress record above.
