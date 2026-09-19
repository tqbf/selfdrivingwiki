# Reviewed package provenance

- Package: org.selfdrivingwiki.zotero
- Version: 1.0.0
- Source: tools/zotero/zotero in this repository
- Entry point: bin/zotero-extractor, generated from the same source
- Dependencies: the PEP 723 block of the entry point is copied from the
  script (requests — resolved by uv at first run; no third-party code is
  bundled, so no license files are required)
- Upstream interface: the Zotero Web API v3. The package downloads ONE
  attachment file plus item metadata per request and never converts
  formats. Markdown attachments are the result itself; PDF/HTML
  attachments are revision-4 bytes results (`resultMIMEType`) that the
  host routes to its own format extraction. `linked_file`/`linked_url`
  attachments are typed failures (no downloadable file).
- Credential: a REQUIRED `zotero-api-key` requirement. The key arrives
  only through the request-scoped credential file and never appears in a
  frame, a message, or the committed bytes.
- Capabilities: network and shared-runtime-cache. The shared cache keeps
  uv's CPython install and wheel cache warm across operations (shared
  with the other uv-launched packages).
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
