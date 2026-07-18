# Keyboard Shortcuts

A complete quick-reference for Self-Driving Wiki keyboard shortcuts.

---

## Navigation

| Shortcut | Action |
|---|---|
| ⌘L | Focus the address bar (omnibox) |
| ⌘[ | Go back |
| ⌘] | Go forward |
| ⌘F | Find on page |
| ⌘1–⌘9 | Switch to tab by position (first 9 tabs) |

## Tabs

| Shortcut | Action |
|---|---|
| ⌘W | Close active tab |
| ⌘⇧T | Reopen last closed tab (up to 10 remembered) |

## Reading & Editing

| Shortcut | Action |
|---|---|
| ⌘+ or ⌘= | Zoom in (×1.1 per step) |
| ⌘− | Zoom out (÷1.1 per step) |
| ⌘0 | Reset zoom to 100% |
| ⌘S | Save changes (in edit mode) |
| ⌘E | Enter edit mode (pages, sources, system prompt) |
| Escape | Cancel edit / dismiss find bar / dismiss omnibox suggestions |

## Chat

| Shortcut | Action |
|---|---|
| ⌘⏎ | Send message in chat composer |

## Windows & App

| Shortcut | Action |
|---|---|
| ⌘, | Open Settings |
| ⌘I | Open Agent Queue (activity window) |
| ⌘E | Open Extraction Queue (activity window) |
| ⌘Q | Quit (asks for confirmation if "Ask before quitting" is on) |

## Address Bar (Omnibox)

| Shortcut | Action |
|---|---|
| Type + ↑↓ | Navigate search suggestions |
| Enter | Open selected suggestion |
| Escape | Dismiss suggestions, return to idle |

## Find Bar

| Shortcut | Action |
|---|---|
| Enter | Next match |
| ⇧Enter | Previous match |
| Escape | Close find bar |

---

## Notes

- **Reader zoom** and **editor zoom** are independent — each has its own
  persistence key (`reader.zoom` / `editor.zoom`). Range: 50%–300%.
- **Tab shortcuts** (⌘1–⌘9) only cover the first nine tabs. Use the tab strip
  or overflow menu for more.
- **⌘E** is context-sensitive: in a page, it enters page edit mode; from the
  menu bar, it opens the Extraction Queue. The menu bar shortcut takes priority
  when no detail view is focused.
- **Edit mode is per-tab.** Switching tabs preserves each tab's edit state.
  Closing a tab while editing asks for confirmation.
