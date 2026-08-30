# Word document (.docx) extraction

Status: complete (v1)

## Goal

A `.docx` source gets an Extract button, a Word provenance chip, and a stored
Markdown version. The conversion runs through a fourth reviewed extractor
package, `org.selfdrivingwiki.docx2md`, so the code path reuses the reviewed
package machinery (digest-pinned bytes, managed process, redacted
provenance) instead of adding a new execution model.

## Pipeline

Two stages inside one bun-bundled entry point:

1. mammoth maps the document's Word styles to HTML.
2. turndown with GFM table handling renders Markdown.

mammoth's own Markdown writer is deprecated upstream. The two-stage HTML path
is the maintainers' recommended route.

## Decisions

- **Scope is `.docx` only.** Legacy `.doc` (`application/msword`) and macro
  `.docm` stay `.binary` with no extraction path.
- **Images become placeholders.** Each embedded image renders as
  `![Figure N](figure-N.png)`, and the result frame carries one warning that
  reports the count. Extracting image bytes is future work.
- **Package-only backend.** There is no built-in Swift docx adapter. The
  reviewed package is the default selection; if it is not active (removed, or
  Bun missing), extraction fails closed with one redacted diagnostic.
- **No auto-ingest.** `ContentKind.docx.capabilities.shouldAutoIngest` is
  false. Raw docx bytes are a binary zip and would be noise as staged agent
  context, unlike HTML text. Extraction is a manual Extract action; the
  resulting Markdown version becomes the source's ingestible content. If a
  later design adds queue-integrated docx extraction, the flag flips then.
- **Header fallback for tables.** turndown-plugin-gfm keeps a table as raw
  HTML unless its first row is entirely `<th>`. Word tables rarely declare
  header rows, so the reviewed entry point treats the first row as the header
  and collapses cell paragraphs to one line.
- **bun/mammoth/turndown over the alternatives.** pandoc cannot speak the
  extractor protocol, its binary is far over the 64 MiB package cap, and it is
  GPL. A first-party OOXML parser is a maintenance risk for marginal
  supply-chain benefit.

## Type layer

- `ExtractorKind.docx` — the manifest/protocol operation family.
- `ExtractionBackendKind.docx` and `ExtractionBackendAdapter.docx` — the
  registry namespace, with `DocxMarkdownExtractor` mirroring
  `HtmlMarkdownExtractor` in `WikiFSMarkdown`.
- `ContentKind.docx` with `ExtractionPath.docxBackend` — the classification
  and capability table entry. `hasFileExtractionBackend` is true, so the
  staging path reuses the extracted head and the Extract button is the
  affordance.
- `ExtractorRouteID.canonicalDOCX` — the persisted route identity
  (kind `docx`, MIME
  `application/vnd.openxmlformats-officedocument.wordprocessingml.document`).

## Selection

`ExtractionConfig.docxExtractor` is a typed optional reference with no legacy
layer beneath it. `setExtractorSelection(_:for:)` dual-writes the route record
and the field. Precedence:

1. The `canonicalDOCX` route record.
2. The `docxExtractor` field.
3. The reviewed docx2md lineage (execution default).

`ExtractorSelectionResolver.resolveDOCX` mirrors `resolveHTML` minus
built-ins: a `.builtIn` stray degrades to "no selection" because no built-in
DOCX backend exists, and an inactive installed selection stays selected,
blocks the route, and emits the redacted unavailable diagnostic.

## Execution

The HTML inline pattern, not the PDF-only queue: `ExtractionCoordinator
.prepareDOCX()` resolves the adapter, `SourceDetailView.runDocxExtraction`
runs it, and `WikiStoreModel.extractDocx` seeds a `text/markdown` version
with the `.installedPackage` producer. `installedPackageRows()` and the
route table include the docx kind, so Settings shows the Word row and the
package row.

## Sync and review

`scripts/sync-extractor-packages.sh` builds the bundle from
`tools/docx2md/extractor-protocol.js` against `tools/docx2md/node_modules`,
vendors the three upstream licenses (mammoth BSD-2-Clause, turndown MIT,
turndown-plugin-gfm MIT; a missing license is a hard error), and writes the
manifest. `sources.lock.json` records the source digest and the mammoth
version. Check mode uses the sources.lock digest strategy only, because bun
bundles embed input paths and are not byte-reproducible across machines. The
golden digest is never hand-computed: the validator prints it, and
`ReviewedExtractorPackageTests` pins it byte-for-byte.

## Verification

- `cd tools/docx2md && bun test` — 11 protocol and conversion tests over a
  committed fixture document.
- `swift run extractor-package-tool validate ExtractorPackages/Docx2md` and
  `protocol-smoke` over a recorded real run.
- `make build` and `make test` green, including the sync drift gate.
- Manual live check (no UI test harness in this repo): add a `.docx` source,
  confirm the Extract button, the readable Markdown, the Word chip, and the
  Settings Word route row.
