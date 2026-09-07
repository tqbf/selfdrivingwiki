# apple-podcast-transcript — reviewed extractor package source

The Apple Podcasts TTML extractor package. One revision-3 `remote-url`
request per process: a validated Apple Podcasts episode URL in, transcript
Markdown out.

## Workflow

- **With staged host support** (the signed `podcast-token-helper`, staged by
  the host into the private operation root for this exact reviewed revision):
  bearer token (staged helper, cached in the host-owned revision-scoped
  token cache) → Apple AMP transcripts endpoint → one forced token refresh
  on Apple error `40012` → access-keyed TTML download → TTML-to-Markdown
  conversion with the same semantics as the former Swift parser.
- **Without staged support**: the RSS transcript algorithm (iTunes lookup →
  feed → `<podcast:transcript>` attachment; VTT, SRT, HTML, plain text).

The RSS path runs ONLY when no helper was staged. A failure after the helper
was staged never falls back to RSS.

## Security contract

- The request's operation configuration carries only the helper's RELATIVE
  path inside the operation root. Absolute paths, traversal, symlinks,
  non-regular files, and non-executable files all fail closed.
- The bearer token is cached only in the host-supplied revision-scoped
  directory (`WIKI_EXTRACTOR_PACKAGE_TOKEN_CACHE`), with owner-only
  permissions, atomic replacement, and ~30-day expiry. The token never
  appears in frames, logs, errors, or the Markdown output.
- The helper runs under a forked supervisor that owns the helper's process
  group: output caps, local timeout, TERM-to-KILL escalation, and reaping on
  every path — including abrupt package death (control-pipe EOF).

## Tests

```sh
uv run pytest tests/ -v
uv run ruff check .
uv run pyright .
```
