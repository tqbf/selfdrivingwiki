---
timestamp: 2026-07-17T013147Z
title: "2026-07-16 — User guide documentation (branch `spiteful-starfish`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-16 — User guide documentation (branch `spiteful-starfish`)

## Progress


**Created.** A user-facing documentation wiki under `docs/user-guide/` —
focused on what the user sees, does, and experiences, **not** on architecture
or internal design decisions. Seven topic pages plus an index:

- `docs/user-guide/README.md` — landing page: core concepts (wikis, pages,
  sources, agent, links, bookmarks), the fundamental workflow diagram, TOC,
  and design philosophy.
- `docs/user-guide/getting-started.md` — first-time setup: create a wiki,
  configure agents, add sources, run first ingest, ask first question.
- `docs/user-guide/interface.md` — window layout tour: sidebar sections,
  tab bar, toolbar omnibox, wiki switcher, change log, detail pane, menu bar.
- `docs/user-guide/pages-and-links.md` — reading/editing pages, full wiki-link
  syntax reference (pages, sources, sections, quotes, version pins, embeds),
  ghost links, link context menus, zoom, find-on-page.
- `docs/user-guide/sources-and-ingestion.md` — adding sources (drag-drop, URL,
  Zotero, folder import), PDF extraction backends, source detail view,
  extraction versioning, the ingest operation, the persistent queue.
- `docs/user-guide/chat.md` — starting chats, the composer, adding context/
  attachments, permission approvals, reading the transcript (tool calls,
  thinking blocks, durations), the chat outline, managing chat history.
- `docs/user-guide/organizing-and-managing.md` — bookmarks, search (semantic
  + FTS5), navigation, multiple wikis & windows, all settings tabs, the
  activity queue, notifications, change log, system prompt.
- `docs/user-guide/keyboard-shortcuts.md` — complete shortcut quick-reference.

**Research method:** dispatched three parallel `researcher` subagents to
investigate the chat experience, the page/source experience, and the wiki
management/settings experience respectively, each reading the relevant Swift
view files and design plans. Their summaries were synthesized into the
user-guide pages.

**PLAN.md** documentation index updated with the user-guide entry.

## Verification

Historical verification remains in the progress record above.
