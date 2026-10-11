# Reviewed package provenance

- Package: org.selfdrivingwiki.audio-acquire
- Version: 1.0.0
- Upstream library: yt-dlp 2026.08.19 (Unlicense) and yt-dlp-ejs 0.8.0,
  resolved by uv at first run from the PEP 723 pins — the same pinned
  release and resolver versions the reviewed YouTube caption package
  declares
- Entry point: generated from tools/audio-acquire/audio-acquire
- Role: fetcher (protocol revision 5). One synthetic source MIME
  (`audio/x-wiki-audio-acquire`), one typed `source-bytes` result per
  acquisition declaring `audio/mp4`.
- Posture: no plugins (YTDLP_NO_PLUGINS), no remote components, no
  cookies, no netrc, no proxy inheritance, no retries, fixed discard
  logger, fixed redacted failure text. yt-dlp is used for METADATA only;
  media bytes move through the package's own bounded streaming client
  under a validating connection guard.

## Review facts

- Downloads ONE audio-only M4A/AAC stream at most 120 MiB for a video at
  most 2 hours; rejects everything else with typed fixed failures.
- The HOST consumes the published file transiently inside its own private
  analysis stage; audio is never stored as a source blob.
- The auxiliary JavaScript runtime (Bun) path is host-resolved and granted
  only to this exact package revision through the
  `reviewed-audio-acquire-bun-runtime` operation configuration; the
  package never supplies or influences the path.
