---
timestamp: 2026-09-28T180000Z
title: wikictl extractor list — runtime discovery surface for acquisition packages
branch: feature/wikictl-extractor-list
status: complete
---

# wikictl extractor list — runtime discovery surface for acquisition packages

## Progress

A chat agent tried to import a Zotero PDF with `wikictl source add --url`
(chat `01M3K7KN8WRC78WPQT6D0XVAED`). The URL fetcher sends no credentials, so
Zotero answered 404 for the private library. The agent had no way to learn
that the reviewed Zotero fetcher package exists, what it can fetch, or which
credential it needs. The package facts are manifest data, so the prompt
cannot carry them. The CLI must answer at run time.

- New `wikictl extractor list [--json]` prints one row per sync-bearing
  registration from the same catalog walk `sync` uses
  (`discoverSyncablePackages`), so the listing and the command it names
  cannot disagree. Each row shows the sync name, package id, version, role,
  claimed input MIME types, fetch URL template, required credential with
  presence state, and the config sidecar with its fields.
- Credential presence mirrors the sync gate: configured, not configured,
  unverified (this process cannot read the shared keychain, so the draining
  host checks it), or none. The check is describe-only. The value is never
  read.
- `list` needs no wiki. The parser intercepts it before the `--wiki`
  selector requirement, and `main.swift` dispatches it before the writable
  runner. Discovery works with no wiki selected.
- Help text now states the split. `source add --url` says it fetches a
  public web page and sends no credentials, and points to `extractor list`
  for sources behind a login or API key. The `extractor sync` summary names
  the sidecar flow in plain words. The `unknownPackage` error now ends with
  "Run `wikictl extractor list` for details."
- The agent prompt (`prompts/system-prompt-default.md`, synced by
  `make prompts`) teaches the discovery loop without naming any package:
  `--url` sends no credentials. Run `extractor list` to learn what this
  machine can acquire, then `extractor sync`.

Not in this change: an ad-hoc fetch verb (`extractor fetch <package>
--item <key>`) that acquires one item without editing the sidecar, and
host-side preemptive enqueue when the app writes a new key into the sidecar.
Both are follow-up seams.

## Verification

- `make build` clean. `ExtractorListCommandTests` (9 tests) covers rows,
  credential states, non-syncable filtering, text and JSON output, and the
  parser (list with no wiki selector, sync still requires its package name).
- Full `make test` passes.
- Manual check against the live machine catalog: the real Zotero package
  lists with its fetch template, and the credential reports "cannot be
  verified from this process" because a bare CLI Mach-O cannot read the
  shared keychain. The draining host checks it, same as sync.
