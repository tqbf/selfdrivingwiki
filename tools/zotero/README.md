# zotero extractor package source

`zotero` is the reviewed source of the `org.selfdrivingwiki.zotero`
extractor package. The package serves ONE protocol revision 4 `remote-url`
request: it downloads one Zotero attachment file plus its item metadata
through the Zotero Web API and never converts formats.

- `text/markdown` / `text/plain` (or `.md`) attachments are written as the
  Markdown result itself (no `resultMIMEType`).
- `application/pdf` (or `.pdf`) and `text/html` (or `.html`) attachments are
  written as source bytes; the result frame carries `resultMIMEType` and the
  HOST runs the format route.
- Anything else is a typed `unsupported-input` failure, as are `linked_file`
  and `linked_url` attachments (they have no downloadable file).

The API key arrives through the request-scoped credential file
(`credentials["zotero-api-key"]`). No frame message ever contains the source
URL, the API key, or credential material.

## Gates

Run from this directory (`tools/zotero`):

```sh
mise exec -- uv run pytest tests/       # unit tests (mocked HTTP; no network)
mise exec -- uv run ruff check zotero tests/
mise exec -- uv run pyright zotero tests/
```

## Regeneration

`scripts/sync-extractor-packages.sh` copies this script into
`ExtractorPackages/Zotero/bin/`, generates the `uv run --script` entry
point, `PROVENANCE.md`, and `manifest.json`, and updates
`ExtractorPackages/sources.lock.json`. Edit this source, then regenerate;
never edit the generated tree.
