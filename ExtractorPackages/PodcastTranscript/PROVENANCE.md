# Reviewed package provenance

- Package: org.selfdrivingwiki.podcast-transcript
- Version: 1.0.0
- Source: tools/podcast-transcript/podcast-transcript in this repository
- Entry point: bin/podcast-transcript-extractor, generated from the same source
- Dependencies: the PEP 723 block of the entry point is copied from the script
  (requests, webvtt-py, srt — resolved by uv at first run; no third-party
  code is bundled, so no license files are required)
- Capabilities: network and shared-runtime-cache (the shared cache keeps
  uv's CPython install and wheel cache warm across operations, shared with
  the other uv-launched packages). The Whisper audio-transcription fallback
  is NOT part of the reviewed registration and is never invoked by the
  package entry point.
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
