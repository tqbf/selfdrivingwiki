# Reviewed package provenance

- Package: org.selfdrivingwiki.youtube-transcript
- Version: 1.2.0 (1.0.1: shared-runtime-cache capability for warm uv runs;
  1.1.0: manifest revision 5 declares the registration-scoped
  `wantsAgentCleanup` claim — the raw auto-captions this package produces
  are the input to the host's best-effort transcript cleanup pass;
  1.2.0: an eligible caption-retrieval failure on the primary route makes
  ONE yt-dlp attempt to fetch the same captions' WebVTT subtitle bytes)
- Source: tools/youtube-transcript/youtube-transcript in this repository
- Entry point: bin/youtube-transcript-extractor, generated from the same source
- Dependencies: the PEP 723 block of the entry point is copied from the script
  and resolved by uv at first run; no third-party code is bundled, so no
  license files are required. The licenses of the resolved dependencies:
  youtube-transcript-api (MIT); yt-dlp 2026.08.19, the caption fallback, is
  Unlicense; yt-dlp-ejs 0.8.0, its matched external-JS solver components, is
  MIT. The pins live in the entry point's inline metadata, so uv resolves
  exactly the reviewed release pair on every machine.
- Auxiliary JavaScript runtime: the pinned yt-dlp release requires a JS
  runtime at or above Bun 1.2.11 for its solver components. The host
  resolves Bun through its own login-shell locator, verifies the version
  and executable identity at preparation, and hands the absolute path to
  the package through the operation-configuration file — the package never
  searches a PATH. A missing or unsupported Bun is a typed setup failure
  for the fallback route only; the primary caption route works without it.
- Upstream interface: youtube-transcript-api uses an undocumented YouTube
  interface that can change without notice, and YouTube can block requests.
  Caption absence, disabled captions, unavailable videos, and blocked
  requests are bounded typed failures. A blocked request never reaches the
  fallback: a listed caption track is not proof of access, and a fallback
  attempt after an IP block would only repeat the block. yt-dlp can also
  advertise tracks whose byte retrieval returns 429 or requires a proof-of-
  origin token; the package reports that as a bounded failure too.
- Capabilities: network and shared-runtime-cache. The shared cache keeps
  uv's CPython install and wheel cache warm across operations (a per-
  operation cache would re-download a CPython every run). The package
  fetches captions YouTube exposes; it never downloads media and never
  runs speech-to-text.
- Regenerate: scripts/sync-extractor-packages.sh
- Drift gate: ExtractorPackages/sources.lock.json records source digests
