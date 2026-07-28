# Tab System with Right-Click Context Menus — From-Scratch Rebuild

## Goal

Replace the existing multi-tab feature (merged to `main` in `b7c366f`, plus the
uncommitted broken context-menu overlay on `feature/tab-context-menu`) with a
clean from-scratch tab system: ID-based active-tab tracking, intent-clean tab
operations, native SwiftUI `.contextMenu` right-click menus (Close / Close
Others / Close Tabs After / Close All), and a polished `TabBarItemView`
following SWIFTUI-RULES. Shared-draft model retained (v1 — per-tab drafts are
an explicit non-goal).

This supersedes `plans/multi-tab-editor.md` (the original feature plan); see the
"Relationship to the prior plan" section below.

## Why rebuild (not patch)

The merged system has architectural defects, not surface bugs:

1. **`activeTabIndex: Int` as the source of truth.** Every close operation
   (single / others / after / all) must recompute an integer index with fragile
   `min(index, count - 1)` / `index < activeTabIndex ? -= 1` math. Off-by-one
   and "wrong tab activates" bugs are intrinsic to this model.
2. **`isSwitchingTab` re-entrancy guard** duplicated around every programmatic
   `selection = …` / `loadDrafts` pair, and overlapping in intent with
   `isApplyingHistorySelection`. Easy to miss one site; the guard exists because
   `selection` is overloaded (drives both sidebar highlight and tab content).
3. **Two overlapping entry paths** — `handleSelectionChange` (via
   `onChange(of: store.selection)`) and `openTab` (called directly by the
   sidebar) — both mutate `tabs[activeTabIndex]`, with muddled intent between
   "navigate within active tab" and "open new tab."
4. **`select()` / `applyHistorySelection()` reach into `tabs[activeTabIndex]`**
   to mutate selection/title, coupling in-tab navigation with tab mutation.
5. **Uncommitted context menu uses `NSViewRepresentable` overlay setting
   `NSView.menu`** — a hack that fights SwiftUI's responder/gesture system and
   produces the "severe bugs." SwiftUI's native `.contextMenu` is the correct
   tool (SWIFTUI-RULES §7.4).
6. **Close button uses insert-on-hover** (`if isHovering { Button } else {
   Color.clear }`) which reflows the tab width as the cursor crosses the
   boundary (SWIFTUI-RULES §4.5 — "opacity-fade, never insert-on-hover").

## Implementation Summary

### Design principles for the rebuild

- **ID-based active tab.** Replace `activeTabIndex: Int` with
  `activeTabID: UUID?`. All operations find the active tab by ID, never by
  index arithmetic. Indices are computed at the view layer only (for `ForEach`
  / keyboard-shortcut numbering).
- **`selection` stays the sidebar/detail driver.** The model's existing
  `selection: WikiSelection?` and `onChange(of: store.selection)` →
  `handleSelectionChange` path is preserved — it's the correct SwiftUI-native
  way the `List(selection:)` binding communicates. The tab system layers *on
  top* of it, not alongside it.
- **One intent per method.** `openTab` = always create new (or focus singleton).
  `selectTab(id:)` = switch active tab. `closeTab(id:)` / `closeOtherTabs(id:)`
  / `closeTabsAfter(id:)` / `closeAllTabs()` = close. `handleSelectionChange`
  = keep the active tab's content in sync with a sidebar-driven navigation
  (in-tab navigation, not new-tab). No method does two jobs.
- **Single `setActiveTab(_:)` helper** centralizes "flush outgoing drafts → set
  activeTabID → set selection → loadDrafts" with the re-entrancy guard in
  exactly one place. All tab switches route through it.
- **Native `.contextMenu`.** Right-click menus are declared in SwiftUI, not
  AppKit. No `NSViewRepresentable`.
- **Opacity-fade close button.** Always-present `Button`,
  `.opacity(isHovering || isActive ? 1 : 0)` + `.allowsHitTesting(...)`. No
  insert/remove.

### Touch points

- **Core (`WikiFSCore`)** — `EditorTab.swift`, `WikiStoreModel.swift`,
  `EditorTabTests.swift`
- **App (`WikiFS`)** — `TabBarView.swift`, `TabBarItemView.swift`,
  `ContentView.swift`, `SidebarView.swift`
- **Unchanged** — `WikiDetailView.swift`, `PageDetailView.swift`,
  `PageEditorView.swift`, `PageReaderView.swift`, `QueryConversationView.swift`,
  `RootView.swift`, all other detail views. The editor views keep binding to
  `store.draftTitle`/`store.draftBody` — the shared-draft contract is unchanged.

### Scope boundary (non-goals)

- Per-tab draft state (simultaneous multi-edit) — explicitly deferred.
- Drag-to-reorder tabs — deferred.
- Tab pinning — deferred.
- Persisting open tabs across app launches — deferred.

## Implementation Plan

### Phase 0 — Restore clean baseline

`git restore Sources/WikiFS/TabBarItemView.swift Sources/WikiFS/TabBarView.swift
Sources/WikiFSCore/WikiStoreModel.swift` to discard the uncommitted
context-menu overlay. We start from the merged `main` state (commit `933ceec`)
so the rebuild is a single coherent diff against a known-good baseline.

### Phase 1 — Core: rebuild `EditorTab` + tab management on `WikiStoreModel`

**`Sources/WikiFSCore/EditorTab.swift`** — keep the value type (it's
well-designed):

```swift
public struct EditorTab: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var selection: WikiSelection
    public var title: String
}
```

Keep `tabTitle(for:)` and `tabIcon(for:)` helpers as-is (they're correct and
tested).

**`Sources/WikiFSCore/WikiStoreModel.swift`** — replace the tab-management
section:

State (replaces `tabs`/`activeTabIndex`/`recentlyClosedTabs`/`isSwitchingTab`):

```swift
public private(set) var tabs: [EditorTab] = []
public var activeTabID: UUID?            // nil when no tabs / empty state
public private(set) var recentlyClosedTabs: [EditorTab] = []
@ObservationIgnored private var isApplyingTabSelection = false
```

Derived helpers (view-layer convenience, computed — never the source of truth):

```swift
public var activeTabIndex: Int {
    activeTabID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
}
public var activeTab: EditorTab? {
    tabs.first { $0.id == activeTabID }
}
```

**Single activation helper** — every tab switch routes through this:

```swift
private func setActiveTab(_ id: UUID?) {
    flushPendingSaves()
    isApplyingTabSelection = true
    activeTabID = id
    let sel = tabs.first { $0.id == id }?.selection
    selection = sel
    loadDrafts(for: sel)
    isApplyingTabSelection = false
}
```

**`openTab(_ selection:title:)`** — always create new, except singletons focus
existing:

```swift
public func openTab(_ selection: WikiSelection, title: String? = nil) {
    // Singletons (.query, .systemPrompt, .changeLog): focus existing if present.
    if case .query, .systemPrompt, .changeLog = selection,
       let existing = tabs.first(where: { $0.selection == selection }) {
        setActiveTab(existing.id)
        return
    }
    let tab = EditorTab(selection: selection, title: title ?? tabTitle(for: selection))
    tabs.append(tab)
    setActiveTab(tab.id)
}
```

**`selectTab(id:)`** — switch active tab by ID:

```swift
public func selectTab(id: UUID) {
    guard tabs.contains(where: { $0.id == id }), id != activeTabID else { return }
    setActiveTab(id)
}
```

**`closeTab(id:)`** — close by ID; activate neighbor by *position*, not index
math on the active tab:

```swift
public func closeTab(id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let closed = tabs.remove(at: index)
    pushRecentlyClosed(closed)
    if tabs.isEmpty {
        setActiveTab(nil)   // empty state
    } else if closed.id == activeTabID {
        // Activate the tab now at the same position (right neighbor), or the last.
        let neighborIndex = min(index, tabs.count - 1)
        setActiveTab(tabs[neighborIndex].id)
    }
    // else: active tab unchanged (it wasn't the closed one).
}
```

**`closeOtherTabs(id:)`** — keep only the tab with `id`:

```swift
public func closeOtherTabs(id: UUID) {
    guard let kept = tabs.first(where: { $0.id == id }) else { return }
    let toClose = tabs.filter { $0.id != id }
    guard !toClose.isEmpty else { return }
    toClose.reversed().forEach { pushRecentlyClosed($0) }
    tabs = [kept]
    setActiveTab(kept.id)
}
```

**`closeTabsAfter(id:)`** — close tabs to the right of `id`:

```swift
public func closeTabsAfter(id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let toClose = Array(tabs.dropFirst(index + 1))
    guard !toClose.isEmpty else { return }
    toClose.reversed().forEach { pushRecentlyClosed($0) }
    tabs = Array(tabs.prefix(index + 1))
    // If the active tab was among the closed, activate the anchor.
    if let active = activeTabID, !tabs.contains(where: { $0.id == active }) {
        setActiveTab(tabs[index].id)
    }
}
```

**`closeAllTabs()`**:

```swift
public func closeAllTabs() {
    guard !tabs.isEmpty else { return }
    tabs.reversed().forEach { pushRecentlyClosed($0) }
    tabs = []
    setActiveTab(nil)
}
```

**`reopenLastClosedTab()`**:

```swift
public func reopenLastClosedTab() {
    guard let last = recentlyClosedTabs.popLast() else { return }
    openTab(last.selection, title: last.title)
}
```

**`pushRecentlyClosed(_:)`** helper (caps at 10):

```swift
private func pushRecentlyClosed(_ tab: EditorTab) {
    recentlyClosedTabs.append(tab)
    if recentlyClosedTabs.count > 10 { recentlyClosedTabs.removeFirst() }
}
```

**`newPageInNewTab(title:)`** — unchanged logic, just calls `openTab`.

**`handleSelectionChange(to:)`** — simplified. This is the sidebar/
`onChange(of: selection)` bridge. It keeps the *active tab's* content in sync
when the sidebar navigates *within* the active tab (in-tab navigation), and
creates the first tab if none exist. It does NOT create new tabs for different
pages (that's `openTab`'s job, called directly by the sidebar's single-click):

```swift
public func handleSelectionChange(to newValue: WikiSelection?) {
    guard !isApplyingTabSelection, newValue != loadedSelection else { return }
    flushPendingSaves()
    recordHistoryTransition(from: loadedSelection, to: newValue)
    loadDrafts(for: newValue)
    // Keep the active tab's metadata in sync (in-tab navigation).
    if tabs.isEmpty, let newValue {
        let tab = EditorTab(selection: newValue, title: tabTitle(for: newValue))
        tabs.append(tab)
        activeTabID = tab.id
    } else if let activeID = activeTabID,
              let i = tabs.firstIndex(where: { $0.id == activeID }), let newValue {
        tabs[i].selection = newValue
        tabs[i].title = tabTitle(for: newValue)
    }
}
```

**`select(_:)`** (used by `selectPage(byTitle:)` for `[[wiki-link]]` clicks) —
same simplification: flush, record history, set selection, loadDrafts, update
active tab metadata. Remove the `tabs[activeTabIndex]` direct mutation.

**`applyHistorySelection(_:)`** (back/forward) — same: update active tab
metadata by ID after setting selection.

**`delete(_:)` / `deleteIngestedFile(_:)`** — find tab by selection,
`closeTab(id:)` if present.

**`rename(_:to:)`** — update `tabs[i].title` for all tabs whose selection
matches the page id (unchanged logic, already correct).

### Phase 2 — App: rebuild `TabBarView` + `TabBarItemView`

**`TabBarView.swift`** — iterate by `id` (stable), compute `isActive` by
comparing `tab.id == store.activeTabID`:

```swift
ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 0) {
        ForEach(store.tabs) { tab in
            TabBarItemView(
                tab: tab,
                isActive: tab.id == store.activeTabID,
                iconName: store.tabIcon(for: tab.selection),
                onClick: { store.selectTab(id: tab.id) },
                onClose: { store.closeTab(id: tab.id) },
                onCloseOthers: { store.closeOtherTabs(id: tab.id) },
                onCloseAfter: { store.closeTabsAfter(id: tab.id) },
                onCloseAll: { store.closeAllTabs() }
            )
        }
    }
    .padding(.horizontal, 4)
}
.frame(height: TabBarMetrics.height)
.background(.regularMaterial)
.overlay(alignment: .bottom) { Divider().opacity(PageEditorMetrics.dividerOpacity) }
```

**`TabBarItemView.swift`** — native `.contextMenu`, opacity-fade close button:

```swift
struct TabBarItemView: View {
    let tab: EditorTab
    let isActive: Bool
    let iconName: String
    let onClick: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAfter: () -> Void
    let onCloseAll: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            closeButton        // always present, opacity-faded
            icon
            titleText
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxHeight: .infinity)
        .background(background)
        .overlay(alignment: .bottom) { activeUnderline }
        .contentShape(Rectangle())
        .onTapGesture { onClick() }
        .onHover { isHovering = $0 }
        .help(tab.title)
        .contextMenu { contextMenuItems }   // native SwiftUI, no NSView
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .opacity(isHovering || isActive ? 1 : 0)
        .allowsHitTesting(isHovering || isActive)
        // SWIFTUI-RULES §4.5: opacity-fade, never insert-on-hover.
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Close") { onClose() }
        Button("Close Others") { onCloseOthers() }
        Button("Close Tabs After") { onCloseAfter() }
        Divider()
        Button("Close All") { onCloseAll() }
    }
    // … icon, titleText, background, activeUnderline as before
}
```

Delete the entire `TabContextMenu` `NSViewRepresentable` + `Coordinator`
(~80 lines).

### Phase 3 — App: update `ContentView` + `SidebarView`

**`ContentView.swift`** — keyboard shortcuts use ID-based API:

```swift
// Cmd+W
Button("") { if let id = store.activeTabID { store.closeTab(id: id) } }
    .keyboardShortcut("w", modifiers: .command)
    .opacity(0).allowsHitTesting(false)
    .disabled(store.tabs.isEmpty)

// Cmd+Shift+T
Button("") { store.reopenLastClosedTab() }
    .keyboardShortcut("t", modifiers: [.command, .shift])
    .opacity(0).allowsHitTesting(false)
    .disabled(store.recentlyClosedTabs.isEmpty)

// Cmd+1–9 — switch by position
ForEach(Array(store.tabs.enumerated()), id: \.element.id) { i, tab in
    Button("") { store.selectTab(id: tab.id) }
        .keyboardShortcut(KeyEquivalent("\(i + 1)"), modifiers: .command)
        .opacity(0).allowsHitTesting(false)
}
```

The "New Tab" toolbar menu and `TabBarView(store:)` placement are unchanged.

**`SidebarView.swift`** — `selectionDidChange` already calls
`store.openTab(first)` for single clicks. No change needed (the plan's
Obsidian-style single-click → openTab behavior is correct and preserved). The
`onChange(of: store.selection)` → `handleSelectionChange` bridge in
`ContentView` is preserved.

### Phase 4 — Tests: rewrite `EditorTabTests.swift` from scratch

Rewrite all 31 existing tests against the ID-based API. The test *intent* is
preserved (same scenarios), but assertions use `activeTabID`/`activeTab`
instead of `activeTabIndex`, and call `closeTab(id:)`/`selectTab(id:)` instead
of index-based methods.

**Coverage:**

- Initial state (no tabs, `activeTabID == nil`)
- First sidebar selection creates initial tab (via `handleSelectionChange`)
- Sidebar single-click replaces active tab content (in-tab navigation, still 1
  tab)
- `openTab` adds new tab; opening same page again creates a second tab
  (Obsidian-style)
- Singleton reuse (`.query`, `.systemPrompt`, `.changeLog` focus existing, no
  duplicate)
- `selectTab(id:)` switches content + flushes outgoing draft
- `selectTab` with already-active id is a no-op
- `closeTab(id:)` activates right neighbor; rightmost activates left; last tab
  → empty state (`activeTabID == nil`)
- Closing the active leftmost tab activates the new leftmost (right neighbor)
- Closing a non-active tab doesn't change the active tab
- `reopenLastClosedTab`; stack preservation; empty-stack no-op; stack cap at 10
- **New:** `closeOtherTabs(id:)` keeps only the specified tab, activates it,
  pushes others to recently-closed (whether or not it was active)
- **New:** `closeTabsAfter(id:)` closes right-side tabs; if the active tab was
  among the closed, activates the anchor; if the active tab is the anchor
  itself (or to its left), active is unchanged
- **New:** `closeAllTabs()` clears all, pushes all to recently-closed, empty
  state
- Delete page closes affected tab; delete active page activates neighbor;
  delete page not in any tab is a no-op
- Delete ingested file closes affected tab
- Rename updates tab titles; rename only affects matching tabs
- `newPageInNewTab` creates page + opens tab
- History back/forward updates active tab metadata
- `tabTitle` / `tabIcon` helpers

### Phase 5 — Skill pass + verification

Per the working agreement (`CLAUDE.md`), run the design skills before and after
writing the view code:

- **`swiftui-pro`** — confirm the `@Bindable` view shape, `activeTabID`
  observation, context menu as native `.contextMenu`, opacity-fade close button.
- **`macos-design`** — confirm the tab bar reads as a modern macOS tab strip
  (regular material, accent underline, native context menu items).
- **`typography-designer`** — confirm semantic fonts (`.caption`, `.semibold`)
  and consistent type hierarchy.

**Verification commands:**

```sh
make check                                  # compile gate
swift test --filter EditorTabTests          # new tab model tests
swift test                                  # full suite — must be green, no regressions
make                                        # clean signed bundle
```

**Manual live gate** (per SWIFTUI-RULES §9.1 — a passing test suite is not a
passing app):

1. Open app → empty state, no tabs
2. Click a page → one tab appears, content loads
3. Click another page → second tab opens, becomes active
4. Click first page in sidebar → focuses existing tab (no duplicate)
5. Click tab X button → tab closes, neighbor activates
6. **Right-click a tab → context menu appears** (Close / Close Others / Close
   Tabs After / Close All)
7. Close Others → only the right-clicked tab remains
8. Close Tabs After → tabs to the right close, left ones (incl. anchor) remain
9. Close All → empty state
10. Cmd+W → closes active tab
11. Cmd+Shift+T → reopens last closed tab
12. Cmd+1–9 → switches between tabs
13. Delete a page open in a tab → tab closes
14. Rename a page open in a tab → tab title updates
15. Switch wikis → tabs reset (`RootView.id` rebuild)

## Acceptance Criteria

- **AC.1** `git restore` discards the 3 dirty files; working tree is clean
  against `main` (commit `933ceec`) before any new edits.
- **AC.2** `activeTabIndex: Int` no longer exists as stored state on
  `WikiStoreModel`; `activeTabID: UUID?` is the source of truth.
  `activeTabIndex` exists only as a computed convenience for the view layer.
- **AC.3** `isSwitchingTab` is replaced by a single `isApplyingTabSelection`
  guard inside `setActiveTab(_:)` — no other site sets it.
- **AC.4** `TabContextMenu` (`NSViewRepresentable`) is deleted; right-click
  menus use native SwiftUI `.contextMenu` with Close / Close Others / Close
  Tabs After / Close All.
- **AC.5** Tab close button uses opacity-fade (always-present `Button` with
  `.opacity`/`.allowsHitTesting`), not insert-on-hover (SWIFTUI-RULES §4.5).
- **AC.6** `closeOtherTabs`, `closeTabsAfter`, `closeAllTabs` are implemented
  and unit-tested (they exist in the current uncommitted diff but are being
  rebuilt cleanly).
- **AC.7** `make check` compiles clean.
- **AC.8** `swift test` is fully green with no regressions; `EditorTabTests`
  covers all scenarios in Phase 4 including the three new close-variant tests.
- **AC.9** `make` produces a clean signed bundle that launches and passes the
  manual live gate above.
- **AC.10** No editor view (`PageDetailView`, `PageEditorView`,
  `PageReaderView`, `QueryConversationView`, etc.) is modified — the
  shared-draft contract is unchanged.

## Test Strategy

- **Unit (`EditorTabTests.swift`)** — the model is `@MainActor @Observable` and
  fully testable without UI (this is why the tab logic lives in `WikiFSCore`,
  not `WikiFS`). All tab operations are exercised against a real
  `SQLiteWikiStore` + temp DB, asserting `tabs`, `activeTabID`, `activeTab`,
  `selection`, `recentlyClosedTabs`, and persisted draft content (for
  flush-on-switch tests). 31+ tests.
- **Compile gate** — `make check` proves the app layer (`WikiFS`) compiles
  against the new ID-based API.
- **Full suite** — `swift test` confirms no regressions in the other ~479
  tests (the only model API change is tab management; `select`/`selectPage`/
  `handleSelectionChange` keep their public signatures).
- **Manual live gate** — SWIFTUI-RULES §9.1: the compile + unit gates do not
  prove the app launches, the context menu appears, or the tab bar lays out
  correctly. The 15-step manual gate above is mandatory.

No snapshot tests (SWIFTUI-RULES §9.3 — brittle, low value).

## Review Strategy

**Plan-mode review (before handoff):** the `plan-reviewer` subagent is
unavailable in this session due to a provider configuration error ("Thinking
mode does not support this tool_choice") affecting all configured subagent
types (`plan-reviewer`, `general-purpose`, `general-purpose-mini`). The review
was therefore performed inline by the planning agent against the six review
questions; see "Inline self-review" below. On a future session where the
subagent provider is healthy, re-run `plan-reviewer` for an independent pass.

**Implementation review (after execute):** dispatch a `general-purpose`
subagent (when available) to review the completed diff against the plan and
SWIFTUI-RULES, focusing on: ID-based activation correctness, no remaining
`NSViewRepresentable` context menu, opacity-fade close button, no editor-view
changes, test coverage matches Phase 4. All findings fixed or rebutted;
critical findings trigger another review pass.

## Inline self-review (plan-reviewer subagent unavailable)

The `plan-reviewer` subagent and both `general-purpose` variants failed with
`http_400: "Thinking mode does not support this tool_choice"` — a provider-side
config conflict on the subagent model, not a plan defect. Since no subagent
could perform the review, the planning agent performed the review inline
against the six questions. Findings and dispositions:

### R1 — ID-based design & closeTab neighbor arithmetic
**Finding (Low).** The stated defect is fixed: `activeTabID: UUID?` removes
the stored-index and the `index < activeTabIndex ? -= 1` shift-on-close-left
bug (no stored index to shift). However `closeTab(id:)` still uses a *local*
`index` (from `firstIndex`) to pick the neighbor: `let neighborIndex = min(index,
tabs.count - 1)`. This is index arithmetic, but it is **local and
non-persistent** — the index is never stored, so the old "stale stored index"
defect class cannot recur. This is the correct tradeoff (a tab's neighbor is
naturally positional). **Disposition: no plan change**; the design is sound.
The "wrong tab activates" risk is eliminated because the neighbor is computed
once from the post-remove array, and `activeTabID` (not an index) is what
`setActiveTab` persists.

### R2 — isApplyingTabSelection re-entrancy guard placement
**Finding (verified correct).** `setActiveTab` sets `selection`, which fires
`onChange(of: store.selection)` in `ContentView` → `handleSelectionChange(to:)`.
`handleSelectionChange`'s guard `guard !isApplyingTabSelection, newValue !=
loadedSelection` correctly no-ops while `setActiveTab` is mid-flight. This
mirrors the existing proven `isApplyingHistorySelection` pattern. One subtlety
to preserve in implementation: `setActiveTab` must set `isApplyingTabSelection =
true` *before* assigning `selection` and reset it *after* `loadDrafts`, exactly
as written. **Disposition: no plan change.**

### R3 — Integration point coverage
**Finding (verified complete).** Grep confirmed every tab-API caller:
- `ContentView`: `onChange → handleSelectionChange`, Cmd+W `closeTab`,
  Cmd+Shift+T `reopenLastClosedTab`, Cmd+1–9 `selectTab`, New Tab menu
  `openTab`/`newPageInNewTab`. All converted to ID-based in Phase 3.
- `SidebarView`: `selectionDidChange → store.openTab(first)`. Unchanged
  (`openTab` keeps its `(WikiSelection, title:)` signature).
- `MarkdownPreview`: `store.selectPage(byTitle:)`. Signature unchanged; internal
  tab-sync simplified in Phase 1 (`select(_:)`).
- `WikiStoreModel` internal: `select`, `selectPage`, `applyHistorySelection`,
  `delete`, `deleteIngestedFile`, `rename`, `newPage`, `newPageInNewTab`. All
  updated in Phase 1.
- `WikiDetailView`/`PageDetailView`/`PageEditorView`: read `store.selection` /
  bind `store.draftTitle`/`store.draftBody`. Unchanged.
- `RootView`: `.id(manager.activeWikiID)` forces clean rebuild (tabs reset).
  Unchanged.

No caller is missed. **Disposition: no plan change.**

### R4 — Native .contextMenu vs .onTapGesture + Button coexistence
**Finding (verified sound).** `.contextMenu` is orthogonal to `.onTapGesture`
and `Button` — it is triggered by a separate right-click (secondary) gesture
and does not intercept the primary click that drives `onTapGesture` or the
close button's action. This is the standard macOS idiom (SWIFTUI-RULES §7.4
explicitly recommends `.contextMenu` on every actionable row). The deleted
`NSViewRepresentable` overlay was the thing that fought the responder chain;
removing it *eliminates* the gesture conflict, it doesn't introduce one.
**Disposition: no plan change.**

### R5 — Edge cases in test coverage
**Finding (Medium — addressed).** The original Phase 4 list missed three edge
cases the reviewer flagged:
1. Closing the active *leftmost* tab (neighbor selection when `index == 0`).
2. `closeTabsAfter(id:)` when the active tab is the anchor itself (active
   unchanged).
3. `closeOtherTabs(id:)` when the kept tab is *not* the active tab (must
   activate it).

The plan's Phase 4 "Coverage" list has been updated to explicitly include all
three (bullets: "Closing the active leftmost tab…", the `closeOtherTabs` bullet
now ends "(whether or not it was active)", and the `closeTabsAfter` bullet now
ends "if the active tab is the anchor itself (or to its left), active is
unchanged"). **Disposition: plan updated inline above.**

### R6 — AC.10 (no editor view changes) safety
**Finding (verified safe).** `select`, `selectPage(byTitle:)`, and
`handleSelectionChange(to:)` keep their **public signatures** unchanged; only
their *internal* tab-sync logic changes from `tabs[activeTabIndex]` to
`tabs[firstIndex { $0.id == activeTabID }]`. `PageEditorView`/`PageDetailView`
bind to `store.draftTitle`/`store.draftBody` and read `store.selection` — none
of those properties change signature or semantics. The shared-draft contract
(flush outgoing → load incoming on tab switch) is preserved by `setActiveTab`.
Therefore no editor view needs editing. **Disposition: no plan change.**

**Net result:** one Medium finding (R5) addressed inline; all other findings
are Low or "verified correct" with no plan change required.

## Risks, Blockers, and Required Decisions

- **Risk: `selection` re-entrancy.** `setActiveTab` sets `selection`, which
  fires `onChange(of: store.selection)` → `handleSelectionChange` in
  `ContentView`. The `isApplyingTabSelection` guard in `handleSelectionChange`
  prevents double-processing. This mirrors the existing
  `isApplyingHistorySelection` pattern (proven correct). The plan consolidates
  to one guard instead of two.
- **Risk: Cmd+1–9 keyboard shortcuts.** `ForEach` over
  `store.tabs.enumerated()` generates shortcuts dynamically. SwiftUI requires
  shortcuts to be declared in the view tree at build time; if tabs change, the
  shortcuts update on next body eval. This is the same approach as the current
  code (just ID-based), so no new risk.
- **Decision (resolved):** Shared drafts, not per-tab — confirmed by the
  operator. Per-tab drafts are an explicit non-goal for this pass.
- **Decision (resolved):** Broad rebuild, not narrow context-menu-only patch —
  confirmed by the operator.
- **Blocker (session-only):** The `plan-reviewer` subagent is unavailable due
  to a provider config error. Review was performed inline (see "Inline
  self-review"). Re-run `plan-reviewer` on a healthy session for an independent
  pass before merge.
- **No unresolved code/design blockers.** All integration points are mapped
  (Phase 0–3 cover every file that references tab APIs).

## Documentation Strategy

- **`progress/`** — append a dated entry documenting the rebuild: what was
  broken in the merged system, the ID-based redesign, the native context menu,
  the opacity-fade fix, test count, and the live-gate result.
- **`plans/multi-tab-editor.md`** — update the "Approach" section to reflect
  the ID-based design (replacing the `activeTabIndex` description) and add the
  context-menu + close-variants section. Mark the `NSViewRepresentable`
  approach as a rejected dead end with the reason. Point at this file as the
  current design of record.
- **`PLAN.md`** — repoint the `multi-tab-editor.md` row in the documentation
  index to note it's superseded by this plan.
- **No user-facing docs** — the tab bar is an internal UI surface with no
  documented user-facing contract beyond the app itself.

## Relationship to the prior plan

`plans/multi-tab-editor.md` is the original feature plan (merged in `b7c366f`).
This plan rebuilds the same feature surface with a corrected architecture and
adds the right-click context menu the original lacked. After implementation:

- The original plan's "Approach" section is updated to describe the ID-based
  design and this file becomes the design of record for the tab system.
- The original plan's manual-verification checklist is extended with the
  context-menu steps (6–9) from this plan's live gate.