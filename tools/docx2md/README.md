# docx2md

Reviewed extractor package source that converts Word documents (`.docx`,
Office Open XML) to Markdown, offline. Part of [Self Driving Wiki](../..).
The reviewed package is `org.selfdrivingwiki.docx2md`, synced to
`ExtractorPackages/Docx2md/` by `scripts/sync-extractor-packages.sh`.

## Pipeline

Two stages inside one entry point:

1. **mammoth** maps the document's semantic styles (Heading 1, List
   Paragraph, …) to HTML.
2. **turndown** (with GFM table/strikethrough handling) converts that HTML
   to Markdown.

mammoth's own Markdown writer is deprecated upstream; the two-stage HTML
path is the maintainers' recommended route.

## Scope and policy

- **`.docx` only.** Legacy `.doc` and macro `.docm` files have no extraction
  path — they stay unextractable by design.
- **Embedded images are not extracted.** Each image becomes an
  `![Figure N](figure-N.png)` placeholder, and the result frame carries one
  `N embedded images were not extracted` warning. The bytes are skipped, not
  lost silently.
- **Header-less tables convert to GFM pipe tables.** The table rules are an
  adapted copy of `turndown-plugin-gfm` (MIT, below) with a first-row-as-
  header fallback: upstream keeps a table as raw HTML unless its first row is
  entirely `<th>`, but Word tables rarely declare header rows.
- **Empty conversion is a failure.** A document with no body content reports
  `extraction-failure` rather than writing an empty output file.
- Input that is not an OOXML zip (or lacks the Word main document part)
  reports `unsupported-input`.

## Runtime

The app launches the package with the repository's mise-managed **bun** (a
Node-compatible runtime) from PATH. The runtime is not copied into the app
bundle. The reviewed bundle is self-contained: `bun build` inlines mammoth,
turndown, and their dependencies, so no `node_modules` ships in the package.

## Extractor package entry point

`extractor-protocol.js` speaks extractor protocol revision 1: it reads one
JSON request from standard input, emits two progress frames, writes Markdown
to the requested output path, and ends with exactly one result or failure
frame. Standard output carries protocol frames only.

## Update procedure

```sh
# 1. Update the pinned dependencies.
cd tools/docx2md && bun install

# 2. Run the package test suite.
bun test

# 3. Regenerate the reviewed package (bundle + licenses + manifest).
./scripts/sync-extractor-packages.sh

# 4. Validate and print the new package digest.
swift run extractor-package-tool validate ExtractorPackages/Docx2md

# 5. Paste the printed packageDigest into
#    Sources/WikiFSCore/Extractor/ReviewedExtractorPackages.swift, then run
#    make test.
```

## Vendors

| Library | Version | License | Role |
| --- | --- | --- | --- |
| [mammoth](https://github.com/mwilliamson/mammoth.js) | 1.12.x | BSD-2-Clause | DOCX → HTML |
| [turndown](https://github.com/mixmark-io/turndown) | 7.2.x | MIT | HTML → Markdown |
| [turndown-plugin-gfm](https://github.com/mixmark-io/turndown-plugin-gfm) | 1.0.x | MIT | GFM extensions (adapted table rules) |
