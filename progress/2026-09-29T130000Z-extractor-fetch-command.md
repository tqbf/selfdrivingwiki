---
timestamp: 2026-09-29T130000Z
title: wikictl extractor fetch — ad-hoc acquisition with full provenance
branch: feature/extractor-adhoc-fetch
status: complete
---

# wikictl extractor fetch — ad-hoc acquisition with full provenance

## Progress

An agent that finds a Zotero item mid-chat had no verb to import it AS a
Zotero item. It copied the file out of `~/Zotero/storage` and used the
generic `source add --body-file`, which records no external identity — the
source then shows its origin as "File" instead of "Zotero" (chat
`01M3K7KN8WRC78WPQT6D0XVAED`, source `01M3NPAZM830381G655AXMK8Z3`). The
missing provenance was backfilled on the two affected sources (attachment
keys `R6JVG38B`, `BBE3XUI2`); this change closes the workflow gap.

- New `wikictl extractor fetch <package> --item <key> [--force]`: acquire
  ONE item now through a package fetcher, without touching the package's
  configured watch list. It creates the byteless source with fetch
  provenance (agent name, fetch-URL plan, external identity = the item
  key) and enqueues its extraction, exactly like `sync`. The queue's fetch
  route then downloads through the package with its credential and writes
  the neutral external provenance (`external_item_key` /
  `external_item_title`), so the source shows its real origin.
- `fetch` shares `sync`'s machinery, not a copy: `ExtractorSyncCommand`
  gained `resolveAcquisition` (discovery, ambiguity guard, credential
  gate, byteless MIME) and a shared outcome renderer; the sidecar loader
  split into `validatedFieldValues` + `validatedItems` with a new public
  `loadFieldValues` (the ad-hoc verb needs the template fields, never the
  watch list — an empty or absent list is fine).
- The ad-hoc item key is validated by the declaration's own rules (length,
  alphabet, host caps) — the same contract as a configured key.
- The sidecar is never modified: the watch list stays UI-managed.
- Help and the agent prompt teach the full loop: `extractor list` to
  discover, `extractor fetch <name> --item <key>` for one item,
  `extractor sync <name>` for the configured list.

## Verification

- `make build` clean; full `make test` passes; the `WIKIFS_APP_TESTS=1`
  app graph passes.
- `ExtractorFetchCommandTests` (8 tests): one source with fetch provenance
  (provider `.zotero`, fetch-URL plan, external identity), the watch list
  is ignored, skip without `--force`, re-enqueue with `--force`, key
  validation by the declared reason, missing template field fails like
  sync, an empty watch list is fine, and the parser (flags, required
  `--item`, wiki selector required).
- The pre-existing sync suite still passes unchanged against the
  refactored front half.
- Live smoke: `extractor fetch --help` renders; a bad key fails closed
  with the declared reason ("must be exactly 8 characters") before any
  write.
