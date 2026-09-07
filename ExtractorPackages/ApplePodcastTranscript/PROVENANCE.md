# Reviewed package provenance

- Package: org.selfdrivingwiki.apple-podcast-transcript
- Version: 1.0.0
- Source: tools/apple-podcast-transcript/apple-podcast-transcript in this repository
- Entry point: bin/apple-podcast-transcript-extractor, generated from the same source
- Dependencies: the PEP 723 block of the entry point is copied from the script
  (requests, webvtt-py, srt — resolved by uv at first run; no third-party
  code is bundled, so no license files are required)
- Capabilities: network only. The signed `podcast-token-helper` is NOT part of
  this package: code signing rewrites Mach-O bytes, so the helper cannot live
  in this digest-pinned snapshot. The host stages it into the private
  operation root for this exact revision, and the operation configuration
  carries only the staged helper's relative path. Without staged support the
  package runs its RSS transcript algorithm.
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
