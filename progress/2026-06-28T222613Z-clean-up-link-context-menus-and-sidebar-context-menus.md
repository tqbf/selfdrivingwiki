---
timestamp: 2026-06-28T222613Z
title: "2026-06-28 — Clean up link context menus and sidebar context menus"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-28 — Clean up link context menus and sidebar context menus

## Progress


Removed redundant actions and reorganized the right-click link context menu
and the sidebar context menus for pages and sources.

**Link context menu (both page and source detail views):**
- Removed "Copy File Path", "Download…", "Copy Link", and "Open in Browser"
- WebKit's native "Open Link" covers browser-open; Share covers file-copy/download
- "Open in Background Tab" inserted right after "Open Link" for wiki links
- Share icon added to the custom Share item; resolves the canonical URL from
  the daemon (`getUserVisibleURL`) for wiki links, passes the raw URL for
  external links
- Menu is now identical between Page and Source detail views

**Page sidebar context menu:**
- Added "Open" and "Open in Background" at the top
- Added "Find Similar…" submenu (semantic search, excludes the current page)
- Rename moved next to Delete at the bottom; Delete has a trash icon
- Lint Page has a dedicated separator section

**Source sidebar context menu:**
- Added "Open in Background" below "Open"
- Ingest Selected shows a confirmation dialog when re-ingesting
- Share and Ingest grouped together (no divider); Rename/Delete below a separator
- Rename and Delete match the page menu layout
**Verified.** `make check` passes, `make test` passes (**320/320**), and the
user-provided appshot shows the selected page in reader mode with the manual edit
button tucked into the toolbar.

## Verification

Historical verification remains in the progress record above.
