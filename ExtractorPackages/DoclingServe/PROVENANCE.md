# Reviewed package provenance

- Package: org.selfdrivingwiki.docling-serve
- Version: 1.0.0
- Implementation: first-party Python (standard library only), maintained in
  this repository at tools/docling-serve/docling_serve_extractor.py
- Entry point: generated wrapper that loads the reviewed module beside it
- Upstream service: Docling Serve (self-hosted; this package ships no
  third-party code)
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
