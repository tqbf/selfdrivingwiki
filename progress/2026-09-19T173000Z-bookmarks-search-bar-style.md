---
timestamp: 2026-09-19T173000Z
title: Bookmarks search bar matches the other sidebar search bars
branch: fix/bookmarks-search-bar-style
status: complete
---

# Bookmarks search bar matches the other sidebar search bars

## Progress

The Bookmarks search bar was the only sidebar search field drawn with field
chrome: a control-background fill and a rounded-rectangle clip, plus its own
padding scheme. Pages, Sources, and the Chats list all render the same
magnifier + plain text field + clear button directly on the sidebar material
with no background box.

Removed the `.background(Color(nsColor: .controlBackgroundColor))`,
`.clipShape(RoundedRectangle(cornerRadius: 6))`, and the extra
`.padding(8)` / `.padding(.horizontal, 12)` / `.padding(.vertical, 4)`
wrapper; the row now uses the same `.padding(.horizontal, 4)` /
`.padding(.vertical, 6)` as the sibling sections. No behavior change —
search, filtering, and the clear button work exactly as before. This
predates #241; the header-icon work preserved the old style verbatim.

## Verification

- `make build` and `make test` — green.
- Visual check: the Bookmarks search row now sits directly on the sidebar
  material like Pages/Sources/Chats.
