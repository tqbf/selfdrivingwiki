# Reviewed package provenance

- Package: org.selfdrivingwiki.defuddle
- Version: 0.19.1
- Upstream library: defuddle 0.19.1 (MIT, see LICENSE)
- Entry point: generated from tools/defuddle/extractor-protocol.js
- Bundle: `mise exec -- bun build` against the pinned library
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
