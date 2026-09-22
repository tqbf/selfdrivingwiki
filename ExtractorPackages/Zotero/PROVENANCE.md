# Reviewed package provenance

- Package: org.selfdrivingwiki.zotero
- Version: 1.0.2
- Source: tools/zotero/zotero in this repository
- Entry point: bin/zotero-extractor, generated from the same source
- Dependencies: the PEP 723 block of the entry point is copied from the
  script (requests, Apache-2.0; pyzotero, BlueOak-1.0.0, which pulls
  feedparser, bibtexparser, whenever, and httpx2; httpx2 is also declared
  directly — the package catches its transport errors — resolved by uv at
  first run; no third-party code is bundled, so no license files are
  required)
- Upstream interface: the Zotero Web API v3. The package downloads ONE
  attachment file plus item metadata per request and never converts
  formats. Markdown attachments are the result itself; PDF/HTML
  attachments are revision-4 bytes results (`resultMIMEType`) that the
  host routes to its own format extraction. `linked_file`/`linked_url`
  attachments are typed failures (no downloadable file).
- Credential: a REQUIRED `zotero-api-key` requirement. The key arrives
  only through the request-scoped credential file and never appears in a
  frame, a message, or the committed bytes.
- Sync: the attachment registration declares its acquisition-sync surface
  (manifest revision 3) — the `zotero-config.json` sidecar, the
  `https://api.zotero.org/users/{libraryID}/items/{itemKey}/file` URL
  template, and the 8-character A–Z0–9 attachment-key list — so
  `wikictl extractor sync zotero` runs entirely on package data.
- Capabilities: network and shared-runtime-cache. The shared cache keeps
  uv's CPython install and wheel cache warm across operations (shared
  with the other uv-launched packages).
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
