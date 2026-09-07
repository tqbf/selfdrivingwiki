# Reviewed package provenance

- Package: org.selfdrivingwiki.youtube-transcript
- Version: 1.0.0
- Source: tools/youtube-transcript/youtube-transcript in this repository
- Entry point: bin/youtube-transcript-extractor, generated from the same source
- Dependencies: the PEP 723 block of the entry point is copied from the script
  (youtube-transcript-api, MIT license — resolved by uv at first run; no
  third-party code is bundled, so no license files are required)
- Upstream interface: youtube-transcript-api uses an undocumented YouTube
  interface that can change without notice, and YouTube can block requests.
  Caption absence, disabled captions, unavailable videos, and blocked
  requests are bounded typed failures.
- Capabilities: network and shared-runtime-cache. The shared cache keeps
  uv's CPython install and wheel cache warm across operations (a per-
  operation cache would re-download a CPython every run). The package
  fetches captions YouTube exposes; it never downloads media and never
  runs speech-to-text.
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
