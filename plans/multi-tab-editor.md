# Multi-Tab Editor Space

## Context

SelfDrivingWiki currently has a single-content navigation model: one `WikiSelection` at a time, with browser-like back/forward history. The user wants an Obsidian-like multi-tab editor where each opened page (or Query, Instructions, etc.) gets its own tab in a horizontal tab bar above the content area.

**Why**: Users need to work with multiple pages simultaneously — referencing one while editing another, keeping Query open alongside pages, etc. The current single-selection model forces constant back/forward navigation.

**What changes**: A custom SwiftUI tab bar inside the detail pane. Each tab tracks a `WikiSelection`. The existing draft/autosave system stays on `WikiStoreModel` (shared) — switching tabs flushes and loads via the existing `flushPendingSaves()` / `loadDrafts()` infrastructure. A future phase can move drafts into tabs for true multi-edit.

**Click behavior**: Obsidian-style — single-clicking a page in the sidebar opens/activates it in a tab. If a tab for that page already exists, focus it; otherwise create a new tab. Singleton types (Query, Instructions, Activity) have at most one tab each.

## Approach

### New Types

**`EditorTab`** (`Sources/WikiFSCore/EditorTab.swift`):
```swift
public struct EditorTab: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var selection: WikiSelection
    public var title: String
}
```
Plus `WikiStoreModel` helpers `tabTitle(for:)` and `tabIcon(for:)` that derive display strings/icons from the live summaries/ingestedFiles arrays.

### WikiStoreModel Changes

Add tab management properties:
- `tabs: [EditorTab]` — all open tabs, in display order
- `activeTabIndex: Int` — index into tabs (0 when empty)
- `recentlyClosedTabs: [EditorTab]` — max 10, for Cmd+Shift+T
- `isSwitchingTab: Bool` (private) — suppresses double-processing in `handleSelectionChange`

New methods:
- **`openTab(_:title:)`** — create or focus a tab. Singleton types reuse existing. Non-singleton always creates new.
- **`selectTab(at:)`** — switch to tab by index, flush outgoing drafts, load incoming
- **`closeTab(at:)`** — close tab, preserve in recently-closed stack, activate right-neighbor (or left if rightmost), show empty state if last tab
- **`reopenLastClosedTab()`** — pop from recently-closed stack, call `openTab`
- **`newPageInNewTab(title:)`** — create page + open in new tab

Modified methods:
- **`handleSelectionChange(to:)`** — skip during tab switches (`isSwitchingTab` guard). Update active tab's metadata on sidebar-driven change.
- **`delete(_:)`** / **`deleteIngestedFile(_:)`** — close any tab showing the deleted item
- **`rename(_:to:)`** — update tab titles for renamed page

The existing `draftTitle`/`draftBody` buffers remain on the model. The `selection` property stays and always mirrors the active tab's selection.

### New Views

**`TabBarView`** (`Sources/WikiFS/TabBarView.swift`):
- Horizontal `ScrollView` with `HStack` of `TabBarItemView` items
- `.regularMaterial` background, bottom divider
- 34pt height

**`TabBarItemView`** (`Sources/WikiFS/TabBarItemView.swift`):
- Icon + truncated title + hover-revealed close button
- Active tab: accent underline + `.controlBackgroundColor` fill
- Inactive tab: subtle background on hover
- Close button: 14pt circle with xmark, visible on hover or when active

### ContentView Changes

- Wrap detail content in `VStack` with `TabBarView` at top
- Add hidden keyboard shortcut buttons: Cmd+W (close tab), Cmd+Shift+T (reopen), Cmd+1-9 (switch to tab N)
- Add "New Tab" toolbar menu (New Page, Query, Instructions, Activity)

### SidebarView Changes

- All single-clicks call `store.openTab(first)` instead of `store.selection = first`
- Singleton types (.query, .systemPrompt, .changeLog) open inline — the sidebar highlight follows the active tab
- No explicit Cmd+click handling needed for v1 (Obsidian-style makes single-click the tab-opening action)

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Page deleted while open in tab | `delete(_:)` calls `closeTab(at:)` for affected tab |
| Wiki switched | `RootView.id(activeWikiID)` forces clean rebuild with empty tabs |
| Last tab closed | `selection = nil`, empty state shown |
| Singleton tab already open | `openTab` switches to existing instead of duplicating |
| Many tabs | ScrollView handles overflow |

### Files

**New**: `EditorTab.swift`, `TabBarView.swift`, `TabBarItemView.swift`, `EditorTabTests.swift`
**Modified**: `WikiStoreModel.swift`, `ContentView.swift`, `SidebarView.swift`
**Unchanged**: `WikiDetailView.swift`, `RootView.swift`, `PageDetailView.swift`, `QueryConversationView.swift`, all other detail views

## Implementation Order

1. Add `EditorTab` type + `WikiStoreModel` extensions (`EditorTab.swift`)
2. Add tab properties + methods to `WikiStoreModel`
3. Write and pass unit tests (`EditorTabTests.swift`)
4. Run full test suite, verify no regressions
5. Build `TabBarView` + `TabBarItemView`
6. Wire tab bar into `ContentView` detail VStack
7. Update `SidebarView.selectionDidChange` to use `openTab`
8. Add keyboard shortcut hidden buttons
9. Update `delete`/`rename`/`deleteIngestedFile` for tab awareness
10. Full manual verification (see below)
11. Skill pass: `swiftui-pro`, `macos-design`, `typography-designer`

## Verification

### Automated
```sh
swift test --filter EditorTabTests    # new tab model tests
swift test                            # full suite — must be green, no regressions
make check                            # compile gate
```

### Manual (live app)
1. Open app → empty state with no tabs
2. Click a page → one tab appears, content loads
3. Click another page → second tab opens, becomes active
4. Click first page in sidebar → focuses existing tab (no duplicate)
5. Click tab X button → tab closes, neighbor activates
6. Close last tab → empty state
7. Cmd+W → closes active tab
8. Cmd+Shift+T → reopens last closed tab
9. Cmd+1-9 → switches between tabs
10. Open Query in a tab, type → switch away → switch back → conversation preserved
11. Delete a page open in a tab → tab closes
12. Rename a page open in a tab → tab title updates
13. Switch wikis → tabs reset
14. Create new page → opens in new tab

### Gate
- `make check` clean
- `swift test` all green
- Signed `make` bundle launches and passes manual checks above
