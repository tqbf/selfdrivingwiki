---
timestamp: 2026-07-10T015557Z
title: "2026-07-09 — #278: Reorganize welcome \"Get Started\" into Add Page / Add Source / Add Chat"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — #278: Reorganize welcome "Get Started" into Add Page / Add Source / Add Chat

## Progress


The welcome screen's "Get Started" row (`WikiDetailView.swift`, `case .none`)
was a flat `FlowLayout` of up to four ingestion-shaped buttons (Add from URL,
Add File, Add Folder, Add from Zotero-when-configured) — conflating several
actions under one heading and offering no path to the two other primary object
types the intro cards above it advertise (Pages, Chats). Reorganized it into
**three primary buttons** that map 1:1 to the Pages / Sources / Chats intro
rows:

- **Add Page** — `store.newPageInNewTab()` (untitled → editor in a new tab),
  mirroring the Pages sidebar `+` and the window toolbar's New Page.
- **Add Source** — a native SwiftUI `Menu` (`.menuStyle(.button)` +
  `.bordered`/`.large`, matching the codebase's `WikiSwitcher` convention) that
  consolidates the four existing ingestion handlers: URL (`addURLHandler?("")`),
  File (`WikiFilePanels.chooseFile` + `store.addFiles`), Folder
  (`showingImportMarkdown = true`), and Zotero (`showingAddFromZotero = true`,
  item appears only when `isZoteroConfigured`).
- **Add Chat** — `store.openTab(.edit)`, mirroring the Chats sidebar `+` New
  Chat (there is only Edit mode now; Ask was removed).

Resolved the issue's open questions: Add Source → native pull-down Menu (vs
popover/sheet); Add Page → untitled straight into edit mode (no title prompt,
matching the rest of the app); Add Chat → Edit (only mode). Per swiftui-pro,
button actions were extracted into `addPage`/`addChat`/`addFile` methods and the
`Button(_:systemImage:action:)` initializer form is used where possible (text +
icon labels for VoiceOver). Gave File vs Folder distinct menu icons
(`doc` / `folder`) — the originals both used `doc.badge.plus`.

**Files:** `Sources/WikiFS/WikiDetailView.swift` (view only — no store/schema
change). **Gate:** `swift build` clean; fast-tier `swift test` — **1963 tests in
162 suites** pass.

## Verification

Historical verification remains in the progress record above.
