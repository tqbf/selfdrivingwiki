---
timestamp: 2026-08-14T000000Z
title: FTS5 desync blocked pre-v38 wiki migrations
branch: bugfix/fts5-index-desync-blocks-open
status: complete
---

# FTS5 desync blocked pre-v38 wiki migrations

## Progress

Older wikis stopped at a pre-v38 `user_version` and did not open. `wikictl` and
the app both reported this error:

```
WikiStore open failed: SQLite error 11: database disk image is malformed
  - while executing `UPDATE pages SET body_markdown = ?, updated_at = ?, version = version + 1 WHERE id = ?`
```

The page content was never damaged. `PRAGMA integrity_check` returns `ok` on the
affected files. The fault was in `pages_fts`, an external-content FTS5 index over
`pages`. Its `pages_fts_au` trigger sends an FTS `'delete'` that carries the old
row values. When the index rows do not match the content table, FTS5 raises
`SQLITE_CORRUPT`.

Issue #634 made this reachable. Before #634 an on-open `rebuildFTS()` resynced
the index and hid any drift. #634 removed the rebuild. It left the v12→v13 step
creating the triggers and the v37→v38 step dropping them. Every ladder step
between those two then ran against a live, unrepaired trigger. Any such step that
writes `pages` died. The `user_version` stamp never landed, so the wiki stayed at
its old version and failed the same way on the next open. `migrateV22ToV23`, the
`[[…]]` canonicalize sweep, is the step that fires in practice.

The store migrates on open, so this also blocked read-only commands such as page
search.

Two changes fix it:

1. The ladder drops the dead FTS5 tables and triggers in a pre-flight, before
   step 1 runs. Post-#634 Tantivy is the sole BM25 leg and nothing reads these
   tables, so the drop loses no data. The v37→v38 step would drop them a few
   steps later anyway.
2. The v12→v13 step no longer creates `pages_fts` and `sources_fts` or their six
   triggers. A new external-content FTS5 index is empty, so it is desynced from a
   populated `pages` by construction. The pre-flight drop alone cannot save a
   database that enters the ladder at v12 or below, because the re-create runs
   after the pre-flight. `createChatSearchTables` lost its `chats_fts` half for
   the same reason. This applies that change to the pages and sources half.

The `source_search` table stays. It is not derived FTS state. It is a content
sidecar that `upsertSourceSearch` and `renameSource` still write.

The v37→v38 step keeps its drop. It is now a no-op, and the catch-all fallback
above `currentSchemaVersion` also calls it.

## wikictl resolved the wrong App Group through a PATH symlink

The same investigation found a second, unrelated bug. It is what made the first
one hard to diagnose.

`WikiIdentifiers` reads `appGroupID` from an env var, the `Bundle.main`
Info.plist, a `wiki-identifiers.env` sidecar next to the executable,
`signing/local.config`, then a compiled-in default. The sidecar is the only leg
that works for the bundled `wikictl`, which is a plain CLI with no Info.plist.

`Bundle.main.executableURL` reports the path the process was exec'd through, not
the real file. A PATH shim such as `~/.local/bin/wikictl`, which Nix, Homebrew,
and `ln -s` all create, therefore put the sidecar search in `~/.local/bin`. No
sidecar exists there, and the `signing/local.config` walk-up finds no repo.
Resolution fell through to the compiled-in `group.org.sockpuppet.wiki`, a
different and empty container.

The symptom misleads. The same binary resolves every wiki when called by its
bundle path. It reports `no wiki matching <id> in the registry` when called
through the symlink.

`WikiIdentifiers` now searches two candidate directories: the invoked directory
first, then the symlink-resolved directory. A PATH shim behaves the same as the
in-bundle path, and no `WIKI_APP_GROUP_ID` override is needed.

The change is additive on purpose. The invoked directory keeps its priority, so
a sidecar placed beside a shim still wins. A resolve-only fix would search the
target directory instead of the shim directory and would silently ignore that
config.

This approach comes from the earlier branch `fix/wikictl-symlink-app-group`
(commit 1b38c343, 2026-07-18), which diagnosed the same bug. That branch predates
the `.app`-ancestor sidecar candidate that #887 added, so this work applies the
same idea to the current three-candidate lookup.

This also removes `signing/wikictl.entitlements`. No build step referenced it.
`build.sh` states that `wikictl` needs no entitlements. The file also held a
hardcoded per-developer App Group that did not match the live container, which
sent the first diagnosis toward a missing entitlement.

## Verification

- `make build` — clean.
- `make test` — 3282 tests in 296 suites pass.
- `Tests/WikiFSTests/FTS5DesyncMigrationTests.swift` — 7 new tests. They stage a
  desynced `pages_fts` on a database rewound to v22 and to v17, then check the
  ladder finishes, the page content survives, no FTS5 object remains, and a
  reopen is a no-op. One test pins the hazard itself. It shows that a new empty
  external-content index makes the next `UPDATE pages` raise `SQLITE_CORRUPT`.
- `Tests/WikiFSTests/WikiIdentifiersSymlinkTests.swift` — 7 new tests. They cover
  a single symlink, invoked-before-resolved priority, a symlink chain, a plain
  executable, a symlinked parent directory, a missing path, and the
  enclosing-`.app` walk that the bundled `wikictl` and the `wikid.xpc` daemon
  use.
- Checked against real data. A read-only `VACUUM INTO` snapshot of the OAuth2
  wiki at v22 reproduced the malformed error. Applying the pre-flight drop to
  that snapshot let the failing `UPDATE` run, and all 46 pages survived.
- A snapshot of the Agentic Identity wiki at v17 migrated to v50 through the
  fixed ladder.
- `make lint` did not run. `swiftlint` is not installed on this machine. The
  changes add no bare `try?`, which is the only rule it enforces.
- The live databases were not modified. All checks used copies.
