# 2026-09-19 — Zotero moved out of Swift into a `zotero` extractor package

Plan: [`plans/zotero-extractor-package.md`](../plans/zotero-extractor-package.md). Branch `feature/zotero-extractor-package`.

## What shipped

- **Protocol revision 4** (`ExtractorProtocol.swift`): optional `resultMIMEType`
  and `articleMetadata.identifier` on the result frame. Requests keep the
  exact revision-3 wire shape. `ExtractorProtocolSequence` takes the request's
  revision and rejects revision-4 fields against a revision ≤ 3 request — an
  old host fails closed instead of silently dropping the fields (this makes
  the migration note in the protocol doc literally true; a bare JSONDecoder
  would have ignored unknown keys).
- **The reviewed `org.selfdrivingwiki.zotero` package**: `tools/zotero/zotero`
  (PEP 723, `requests`) + generated tree in `ExtractorPackages/Zotero`
  (manifest revision 2, protocol revision 4, REQUIRED `zotero-api-key`
  requirement). 65 pytest cases pin the URL grammar, MIME → output-route
  table, link-mode rejection, HTTP error mapping, credential handling,
  output limit, frame emission, and parent-metadata degradation. The
  generation script gained the Zotero branch and the lock-file entry.
- **Host registration**: `ExtractorKind.zotero`, canonical
  `application/zotero` route with the reviewed lineage as the bundled
  default, typed `prepareZoteroAttachment()` seam, `.zotero` case in BOTH
  queue-extraction providers, `ContentKind.zoteroAttachment` (closed-enum
  pin 13 → 14 with an acquisition-path partition rule), and app-startup
  seeding of the `(packageID, zotero-api-key)` → `.zoteroAPIKey()`
  authorization binding.
- **Config + sync**: `zotero-config.json` gains `attachments`
  (validated 8-character uppercase keys); `zoteroDirOverride` is no longer
  written (decode stays tolerant). `wikictl zotero sync [--force]` creates
  byteless `.zotero` sources and enqueues durable `.extraction` jobs —
  enqueue-only, no `QueueEngine`, no CLI-side waiting.
- **Bytes-result completion**: `persistAttachmentExtraction` + a new
  `attachZoteroAttachment` store mutator (blob, hash, real MIME/ext/size,
  retained Zotero columns, display name — one `mutate()` transaction) and
  `setZoteroProvenance` for Markdown results. Bytes results enqueue the
  follow-on `.extraction` item so the user's PDF/HTML route produces the
  Markdown version.
- **Deletion**: the entire Swift acquisition path (`ZoteroClient`,
  `ZoteroLocalStorage`, `ZoteroMaterializer`, `ingestFromZotero`,
  `AddFromZoteroSheet` + picker wiring, the engine Zotero plugin + client
  provider + service key, `verifyZotero`, `.zoteroMetadata` sniff origin).
  Kept: provider display data, DB columns, `zotero://` deep link,
  `ZoteroCredentialStore`, and `ZoteroSettingsView` (API key + library ID).
- **Docs**: protocol revision 4 + migration note in
  `docs/architecture/extractor-script-protocol.md`, the Zotero worked
  example in `docs/architecture/extractor-package-manifest.md`, a user-guide
  section (config shape + `wikictl zotero sync`), the maintainer skill's
  revision-4 + `zotero` rows, this progress entry, and the design doc.

## Gates

`make build`, package pytest/ruff/pyright (65 tests), package validate +
protocol-smoke (bytes-result fixture), reviewed-package golden digest,
drift check, extractor-kind-neutrality contract, zotero sync command tests,
and provider-route tests for both hosts.

## Deliberately deferred

Picker UI, Authorize/Revoke UI, app-launch auto-sync, item-key selection
policy, conditional re-download — sequenced behind the later UI work.
