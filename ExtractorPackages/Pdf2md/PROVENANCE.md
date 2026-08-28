# Reviewed package provenance

- Package: org.selfdrivingwiki.pdf2md
- Version: 1.0.0
- Source: tools/pdf2md/pdf2md in this repository
- Entry point: bin/pdf2md-extractor, generated from the same source
- Dependencies: the PEP 723 block of the entry point is copied from the script
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
