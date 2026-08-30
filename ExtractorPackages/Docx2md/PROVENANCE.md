# Reviewed package provenance

- Package: org.selfdrivingwiki.docx2md
- Version: 1.0.0
- Upstream libraries: mammoth 1.12.2 (BSD-2-Clause, see
  licenses/mammoth-LICENSE), turndown (MIT, see licenses/turndown-LICENSE),
  turndown-plugin-gfm (MIT, see licenses/turndown-plugin-gfm-LICENSE)
- Entry point: generated from tools/docx2md/extractor-protocol.js
- Table rules: adapted from turndown-plugin-gfm (MIT) with a
  first-row-as-header fallback and mammoth cell cleanup
- Bundle: `mise exec -- bun build --target=bun` against the pinned
  dependencies
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
